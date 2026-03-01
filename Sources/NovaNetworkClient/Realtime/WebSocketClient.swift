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

private struct WebSocketOutboundEnvelope: Sendable {
    let message: WebSocketMessage
    let options: WebSocketSendOptions
    let resolvedMessageID: String?
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
    private var health: WebSocketConnectionHealth = .disconnected
    private var connectAttempt = 0
    private var connectionID = UUID().uuidString
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var disconnectRequested = false
    private var outboundQueue: [WebSocketOutboundEnvelope] = []
    private var ackWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var ackTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var pendingAckMessages: [String: WebSocketOutboundEnvelope] = [:]
    private var acknowledgedMessageIDs: Set<String> = []

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

    public func connectionHealth() -> WebSocketConnectionHealth {
        health
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
            health = .healthy
            await stateHub.emit(connected)
            emitTelemetry(type: .connectSuccess, attempt: connectAttempt)
            startConnectedLoops()
            await resendPendingAckMessages()
            await flushOutboundQueue()
        } catch {
            let mapped = mapError(error)
            await failTerminal(mapped, telemetryAttempt: connectAttempt)
            throw mapped
        }
    }

    public func forceReconnect(reason: String? = nil) async {
        disconnectRequested = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelBackgroundTasks()
        await transport.disconnect(reason: reason ?? "force_reconnect")
        startReconnectLoop(
            initialError: .transport(description: reason ?? "force_reconnect"),
            minimumAttempts: 1,
            immediateFirstAttempt: true
        )
    }

    public func send(_ message: WebSocketMessage) async throws {
        try await send(message, options: .init())
    }

    public func send(_ message: WebSocketMessage, options: WebSocketSendOptions) async throws {
        let resolvedMessageID = options.requiresAck ? (options.messageID ?? UUID().uuidString) : nil
        let envelope = WebSocketOutboundEnvelope(
            message: message,
            options: options,
            resolvedMessageID: resolvedMessageID
        )
        try await sendOrQueue(envelope)
    }

    public func disconnect(reason: String? = nil) async {
        disconnectRequested = true
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelBackgroundTasks()
        failAllAckWaiters(with: .disconnected)
        await transport.disconnect(reason: reason)
        state = .disconnected
        health = .disconnected
        await stateHub.emit(state)
        await messageHub.finish()
        emitTelemetry(type: .disconnect, reason: reason)
    }

    private func sendOrQueue(_ envelope: WebSocketOutboundEnvelope) async throws {
        if case .connected = state {
            try await sendEnvelope(envelope)
            return
        }
        try queueOutboundEnvelope(envelope)
    }

    private func sendEnvelope(_ envelope: WebSocketOutboundEnvelope) async throws {
        do {
            try await transport.send(envelope.message)
            emitTelemetry(type: .messageSent, messageKind: envelope.message.telemetryKind)
        } catch {
            let mapped = mapError(error)
            throw mapped
        }

        guard envelope.options.requiresAck, let messageID = envelope.resolvedMessageID else {
            return
        }
        if acknowledgedMessageIDs.contains(messageID) {
            return
        }
        pendingAckMessages[messageID] = envelope
        try await waitForAck(
            messageID: messageID,
            timeoutNanoseconds: envelope.options.ackTimeoutNanoseconds
        )
        pendingAckMessages.removeValue(forKey: messageID)
    }

    private func queueOutboundEnvelope(_ envelope: WebSocketOutboundEnvelope) throws {
        let policy = configuration.outboundQueuePolicy
        guard policy.maxQueuedMessages > 0 else {
            throw WebSocketError.disconnected
        }

        if outboundQueue.count >= policy.maxQueuedMessages {
            switch policy.overflowPolicy {
            case .dropOldest:
                _ = outboundQueue.removeFirst()
                emitTelemetry(
                    type: .messageDropped,
                    reason: "overflow_drop_oldest",
                    messageKind: envelope.message.telemetryKind,
                    queueSize: outboundQueue.count,
                    queuePolicy: "dropOldest"
                )
            case .dropNewest:
                emitTelemetry(
                    type: .messageDropped,
                    reason: "overflow_drop_newest",
                    messageKind: envelope.message.telemetryKind,
                    queueSize: outboundQueue.count,
                    queuePolicy: "dropNewest"
                )
                return
            case .failFast:
                throw WebSocketError.disconnected
            }
        }

        outboundQueue.append(envelope)
        emitTelemetry(
            type: .messageQueued,
            messageKind: envelope.message.telemetryKind,
            queueSize: outboundQueue.count,
            queuePolicy: String(describing: policy.overflowPolicy)
        )
    }

    private func flushOutboundQueue() async {
        while !outboundQueue.isEmpty {
            guard case .connected = state else { return }
            let next = outboundQueue.removeFirst()
            do {
                try await sendEnvelope(next)
            } catch {
                outboundQueue.insert(next, at: 0)
                return
            }
        }
    }

    private func resendPendingAckMessages() async {
        guard !pendingAckMessages.isEmpty else { return }
        let pending = Array(pendingAckMessages.values)
        for envelope in pending {
            guard case .connected = state else { return }
            do {
                try await transport.send(envelope.message)
                emitTelemetry(type: .messageSent, messageKind: envelope.message.telemetryKind)
            } catch {
                return
            }
        }
    }

    private func waitForAck(messageID: String, timeoutNanoseconds: UInt64) async throws {
        if acknowledgedMessageIDs.contains(messageID) {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            ackWaiters[messageID] = continuation
            ackTimeoutTasks[messageID] = Task {
                do {
                    try await retryClock.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                self.ackTimeoutElapsed(for: messageID)
            }
        }
    }

    private func ackTimeoutElapsed(for messageID: String) {
        guard let continuation = ackWaiters.removeValue(forKey: messageID) else {
            return
        }
        ackTimeoutTasks[messageID]?.cancel()
        ackTimeoutTasks.removeValue(forKey: messageID)
        emitTelemetry(
            type: .ackTimeout,
            reason: "ack_timeout",
            messageID: messageID
        )
        continuation.resume(throwing: WebSocketError.ackTimeout(messageID: messageID))
    }

    private func handleAck(messageID: String) {
        guard !messageID.isEmpty else { return }
        if acknowledgedMessageIDs.contains(messageID) {
            return
        }
        acknowledgedMessageIDs.insert(messageID)
        pendingAckMessages.removeValue(forKey: messageID)
        ackTimeoutTasks[messageID]?.cancel()
        ackTimeoutTasks.removeValue(forKey: messageID)
        if let continuation = ackWaiters.removeValue(forKey: messageID) {
            continuation.resume(returning: ())
        }
    }

    private func failAllAckWaiters(with error: WebSocketError) {
        for task in ackTimeoutTasks.values {
            task.cancel()
        }
        ackTimeoutTasks.removeAll()
        let continuations = ackWaiters.values
        ackWaiters.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
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
                    if let ackID = message.ackMessageID {
                        self.handleAck(messageID: ackID)
                    }
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
        state = .unhealthy(mapped)
        health = .unhealthy(reason: String(describing: mapped))
        await stateHub.emit(state)
        if shouldReconnect(after: mapped) {
            startReconnectLoop(initialError: mapped)
            return
        }
        await failTerminal(mapped)
    }

    private func shouldReconnect(after error: WebSocketError) -> Bool {
        guard configuration.reconnectPolicy.maxAttempts > 0 else { return false }
        switch error {
        case .auth, .protocolViolation, .cancelled, .disconnected, .reconnectExhausted, .ackTimeout:
            return false
        case .timeout, .transport:
            return true
        }
    }

    private func startReconnectLoop(
        initialError: WebSocketError,
        minimumAttempts: Int = 0,
        immediateFirstAttempt: Bool = false
    ) {
        cancelBackgroundTasks()

        reconnectTask = Task {
            var attempt = 0
            let maxAttempts = max(configuration.reconnectPolicy.maxAttempts, minimumAttempts)
            while !Task.isCancelled,
                  !disconnectRequested,
                  attempt < maxAttempts {
                attempt += 1
                let delayNanoseconds =
                    (immediateFirstAttempt && attempt == 1) ? 0 : reconnectDelayNanoseconds(forAttempt: attempt)
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
                    health = .healthy
                    await stateHub.emit(connected)
                    emitTelemetry(type: .reconnectSuccess, attempt: attempt)
                    reconnectTask = nil
                    startConnectedLoops()
                    await resendPendingAckMessages()
                    await flushOutboundQueue()
                    return
                } catch is CancellationError {
                    reconnectTask = nil
                    return
                } catch {
                    let mapped = mapError(error)
                    if !shouldReconnect(after: mapped) {
                        reconnectTask = nil
                        await failTerminal(mapped, telemetryAttempt: attempt)
                        emitTelemetry(type: .reconnectFailed, attempt: attempt, error: mapped)
                        return
                    }
                }
            }

            reconnectTask = nil
            let terminal = WebSocketError.reconnectExhausted
            await failTerminal(terminal)
            emitTelemetry(type: .reconnectFailed, attempt: attempt, error: terminal)
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
        failAllAckWaiters(with: error)
        await messageHub.finish(throwing: error)
        state = .failed(error)
        health = .unhealthy(reason: String(describing: error))
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
        messageKind: String? = nil,
        queueSize: Int? = nil,
        queuePolicy: String? = nil,
        messageID: String? = nil
    ) {
        telemetryHooks?.onWebSocketEvent?(
            TelemetryWebSocketContext(
                type: type,
                connectionID: connectionID,
                attempt: attempt,
                reason: reason,
                error: error.map { String(describing: $0) },
                messageKind: messageKind,
                queueSize: queueSize,
                queuePolicy: queuePolicy,
                messageID: messageID
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

    var ackMessageID: String? {
        guard case .text(let value) = self else { return nil }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String,
           type == "ack",
           let messageID = object["messageId"] as? String {
            return messageID
        }

        let prefix = "ack:"
        if value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return nil
    }
}
