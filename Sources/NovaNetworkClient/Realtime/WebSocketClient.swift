import Foundation

actor WebSocketStateHub {
    private var continuations: [UUID: AsyncStream<WebSocketConnectionState>.Continuation] = [:]

    func makeStream() -> AsyncStream<WebSocketConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ event: WebSocketConnectionState) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}

actor WebSocketMessageHub {
    private var continuations: [UUID: AsyncThrowingStream<WebSocketMessage, Error>.Continuation] = [:]

    func makeStream() -> AsyncThrowingStream<WebSocketMessage, Error> {
        let id = UUID()
        return AsyncThrowingStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ message: WebSocketMessage) {
        for continuation in continuations.values {
            continuation.yield(message)
        }
    }

    func finish(throwing error: (any Error)? = nil) {
        for continuation in continuations.values {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        continuations.removeAll()
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}

public actor WebSocketClient: WebSocketClientProtocol {
    private let configuration: WebSocketConfiguration
    private let transport: any WebSocketTransport
    private let telemetryHooks: NetworkTelemetryHooks?
    private let retryClock: any RetryClock
    private let retryRandomGenerator: any RetryRandomGenerator
    private let stateHub = WebSocketStateHub()
    private let messageHub = WebSocketMessageHub()

    private var state: WebSocketConnectionState = .disconnected
    private var connectAttempt = 0
    private var connectionID = UUID().uuidString
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var disconnectRequested = false

    public init(
        configuration: WebSocketConfiguration,
        telemetryHooks: NetworkTelemetryHooks? = nil
    ) {
        self.configuration = configuration
        self.transport = URLSessionWebSocketTransport()
        self.telemetryHooks = telemetryHooks
        self.retryClock = SystemRetryClock()
        self.retryRandomGenerator = SystemRetryRandomGenerator()
    }

    init(
        configuration: WebSocketConfiguration,
        transport: any WebSocketTransport,
        retryClock: any RetryClock = SystemRetryClock(),
        retryRandomGenerator: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        telemetryHooks: NetworkTelemetryHooks? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.retryClock = retryClock
        self.retryRandomGenerator = retryRandomGenerator
        self.telemetryHooks = telemetryHooks
    }

    public func connectionStates() -> AsyncStream<WebSocketConnectionState> {
        let initialState = state
        return AsyncStream { continuation in
            continuation.yield(initialState)
            Task {
                let upstream = await stateHub.makeStream()
                for await event in upstream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    public func messages() -> AsyncThrowingStream<WebSocketMessage, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let upstream = await messageHub.makeStream()
                do {
                    for try await message in upstream {
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func connect() async throws {
        switch state {
        case .connected, .connecting, .reconnecting:
            return
        default:
            break
        }

        disconnectRequested = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelBackgroundTasks()

        connectionID = UUID().uuidString
        connectAttempt += 1
        state = .connecting(attempt: connectAttempt)
        await stateHub.emit(state)
        emitTelemetry(type: .connectStarted, attempt: connectAttempt)

        do {
            try await transport.connect(url: configuration.url, headers: configuration.headers)
            let connected = WebSocketConnectionState.connected(since: Date())
            state = connected
            await stateHub.emit(connected)
            emitTelemetry(type: .connectSuccess, attempt: connectAttempt)
            startConnectedLoops()
        } catch {
            let mapped = mapError(error)
            await failTerminal(mapped, telemetryAttempt: connectAttempt)
            throw mapped
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        guard case .connected = state else {
            throw WebSocketError.disconnected
        }

        do {
            try await transport.send(message)
            emitTelemetry(type: .messageSent, messageKind: message.telemetryKind)
        } catch {
            let mapped = mapError(error)
            throw mapped
        }
    }

    public func disconnect(reason: String? = nil) async {
        disconnectRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelBackgroundTasks()
        await transport.disconnect(reason: reason)
        state = .disconnected
        await stateHub.emit(state)
        await messageHub.finish()
        emitTelemetry(type: .disconnect, reason: reason)
    }

    private func startConnectedLoops() {
        startReceiveLoop()
        startHeartbeatLoop()
    }

    private func cancelBackgroundTasks() {
        receiveTask?.cancel()
        receiveTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    await messageHub.emit(message)
                    emitTelemetry(type: .messageReceived, messageKind: message.telemetryKind)
                } catch is CancellationError {
                    return
                } catch {
                    await handleConnectionLoss(error)
                    return
                }
            }
        }
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        let policy = configuration.heartbeatPolicy
        guard policy.intervalNanoseconds > 0, policy.timeoutNanoseconds > 0 else {
            return
        }

        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await retryClock.sleep(nanoseconds: policy.intervalNanoseconds)
                } catch {
                    return
                }

                do {
                    try await pingWithTimeout(timeoutNanoseconds: policy.timeoutNanoseconds)
                } catch is CancellationError {
                    return
                } catch {
                    await handleConnectionLoss(error)
                    return
                }
            }
        }
    }

    private func pingWithTimeout(timeoutNanoseconds: UInt64) async throws {
        let transport = self.transport
        let retryClock = self.retryClock
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await transport.ping()
            }
            group.addTask {
                try await retryClock.sleep(nanoseconds: timeoutNanoseconds)
                throw WebSocketError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw WebSocketError.timeout
            }
            _ = first
        }
    }

    private func handleConnectionLoss(_ error: any Error) async {
        guard !disconnectRequested else { return }
        guard reconnectTask == nil else { return }

        let mapped = mapError(error)
        if shouldReconnect(after: mapped) {
            startReconnectLoop(initialError: mapped)
            return
        }
        await failTerminal(mapped)
    }

    private func shouldReconnect(after error: WebSocketError) -> Bool {
        guard configuration.reconnectPolicy.maxAttempts > 0 else { return false }
        switch error {
        case .auth, .protocolViolation, .cancelled, .disconnected, .reconnectExhausted:
            return false
        case .timeout, .transport:
            return true
        }
    }

    private func startReconnectLoop(initialError: WebSocketError) {
        cancelBackgroundTasks()

        reconnectTask = Task {
            var attempt = 0
            while !Task.isCancelled,
                  !disconnectRequested,
                  attempt < configuration.reconnectPolicy.maxAttempts {
                attempt += 1
                let delayNanoseconds = reconnectDelayNanoseconds(forAttempt: attempt)
                let delayMilliseconds = Double(delayNanoseconds) / 1_000_000

                state = .reconnecting(attempt: attempt, nextDelayMilliseconds: delayMilliseconds)
                await stateHub.emit(state)
                emitTelemetry(
                    type: .reconnectAttempt,
                    attempt: attempt,
                    error: initialError
                )

                do {
                    try await retryClock.sleep(nanoseconds: delayNanoseconds)
                    try await transport.connect(url: configuration.url, headers: configuration.headers)
                    let connected = WebSocketConnectionState.connected(since: Date())
                    state = connected
                    await stateHub.emit(connected)
                    emitTelemetry(type: .reconnectSuccess, attempt: attempt)
                    reconnectTask = nil
                    startConnectedLoops()
                    return
                } catch is CancellationError {
                    reconnectTask = nil
                    return
                } catch {
                    let mapped = mapError(error)
                    if !shouldReconnect(after: mapped) {
                        reconnectTask = nil
                        await failTerminal(mapped, telemetryAttempt: attempt)
                        return
                    }
                }
            }

            reconnectTask = nil
            let terminal = WebSocketError.reconnectExhausted
            await failTerminal(terminal)
            emitTelemetry(type: .reconnectExhausted)
        }
    }

    private func reconnectDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let base = configuration.reconnectPolicy.baseDelayNanoseconds
        let maxDelay = configuration.reconnectPolicy.maxDelayNanoseconds
        let exponent = min(max(0, attempt - 1), 16)
        let (scaledValue, overflow) = base.multipliedReportingOverflow(by: UInt64(1 << exponent))
        let scaled = overflow ? UInt64.max : scaledValue
        let capped = min(scaled, maxDelay)

        guard let jitter = configuration.reconnectPolicy.jitterRange else {
            return capped
        }
        return UInt64(Double(capped) * retryRandomGenerator.nextDouble(in: jitter))
    }

    private func failTerminal(_ error: WebSocketError, telemetryAttempt: Int? = nil) async {
        cancelBackgroundTasks()
        await messageHub.finish(throwing: error)
        state = .failed(error)
        await stateHub.emit(state)
        emitTelemetry(type: .connectFailed, attempt: telemetryAttempt, error: error)
    }

    private func mapError(_ error: any Error) -> WebSocketError {
        if let websocketError = error as? WebSocketError {
            return websocketError
        }
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            if urlError.code == .userAuthenticationRequired {
                return .auth(description: urlError.localizedDescription)
            }
            if urlError.code == .timedOut {
                return .timeout
            }
        }
        return .transport(description: String(describing: error))
    }

    private func emitTelemetry(
        type: TelemetryWebSocketEventType,
        attempt: Int? = nil,
        reason: String? = nil,
        error: WebSocketError? = nil,
        messageKind: String? = nil
    ) {
        telemetryHooks?.onWebSocketEvent?(
            TelemetryWebSocketContext(
                type: type,
                connectionID: connectionID,
                attempt: attempt,
                reason: reason,
                error: error.map { String(describing: $0) },
                messageKind: messageKind
            )
        )
    }
}

private extension WebSocketMessage {
    var telemetryKind: String {
        switch self {
        case .text:
            return "text"
        case .binary:
            return "binary"
        }
    }
}
