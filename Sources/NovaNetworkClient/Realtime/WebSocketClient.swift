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
    private let ackMatcher: WebSocketAckMatcher
    private let authRefreshProvider: WebSocketAuthRefreshProvider?
    private let connectivityMonitor: (any OfflineConnectivityMonitor)?
    private let outboundQueueStore: (any WebSocketOutboundQueueStore)?
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
    private var pendingAckStartedAt: [String: UInt64] = [:]
    private var pendingAckAttempts: [String: Int] = [:]
    private var acknowledgedMessageIDs: [String: UInt64] = [:]
    private var registeredSubscriptions: [String: WebSocketOutboundEnvelope] = [:]
    private var subscriptionOrder: [String] = []
    private var lastError: WebSocketError?
    private var refreshedAuthHeaders: [String: String] = [:]
    private var didRestorePersistedOutboundQueue = false
    private var pendingRestoredReplayCount = 0
    private var reconnectPhase: WebSocketReconnectPhase = .disconnected
    private var lastTransitionReason: String?
    private var lastRecoverability: WebSocketRecoverability?

    public init(
        configuration: WebSocketConfiguration,
        ackMatcher: WebSocketAckMatcher = .default,
        authRefreshProvider: WebSocketAuthRefreshProvider? = nil,
        connectivityMonitor: (any OfflineConnectivityMonitor)? = nil,
        outboundQueueStore: (any WebSocketOutboundQueueStore)? = nil,
        telemetryHooks: NetworkTelemetryHooks? = nil
    ) {
        self.configuration = configuration
        self.ackMatcher = ackMatcher
        self.authRefreshProvider = authRefreshProvider
        self.connectivityMonitor = connectivityMonitor
        self.outboundQueueStore = outboundQueueStore
        self.transport = URLSessionWebSocketTransport()
        self.telemetryHooks = telemetryHooks
        self.retryClock = SystemRetryClock()
        self.retryRandomGenerator = SystemRetryRandomGenerator()
    }

    init(
        configuration: WebSocketConfiguration,
        transport: any WebSocketTransport,
        ackMatcher: WebSocketAckMatcher = .default,
        authRefreshProvider: WebSocketAuthRefreshProvider? = nil,
        connectivityMonitor: (any OfflineConnectivityMonitor)? = nil,
        outboundQueueStore: (any WebSocketOutboundQueueStore)? = nil,
        retryClock: any RetryClock = SystemRetryClock(),
        retryRandomGenerator: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        telemetryHooks: NetworkTelemetryHooks? = nil
    ) {
        self.configuration = configuration
        self.ackMatcher = ackMatcher
        self.authRefreshProvider = authRefreshProvider
        self.connectivityMonitor = connectivityMonitor
        self.outboundQueueStore = outboundQueueStore
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

    public func webSocketDiagnostics() -> WebSocketDiagnostics {
        let queueCapacity = configuration.outboundQueuePolicy.maxQueuedMessages
        return WebSocketDiagnostics(
            connectionID: connectionID,
            state: state,
            health: health,
            reconnectAttempt: connectAttempt,
            queuedOutboundMessages: outboundQueue.count,
            queueCapacity: queueCapacity,
            queuePressureLevel: queuePressureLevel(depth: outboundQueue.count, capacity: queueCapacity),
            pendingAckCount: ackWaiters.count,
            ackPendingAgeBuckets: ackPendingAgeBuckets(),
            trackedAckMessageIDs: acknowledgedMessageIDs.count,
            reconnectPhase: reconnectPhase,
            lastTransitionReason: lastTransitionReason,
            recoverability: lastRecoverability,
            lastError: lastError
        )
    }

    public func connect() async throws {
        switch state {
        case .connected, .connecting, .reconnecting, .reconnectingWaitingForConnectivity:
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
        reconnectPhase = .connecting
        lastTransitionReason = "connect_start"
        lastRecoverability = nil
        await stateHub.emit(state)
        emitTelemetry(type: .connectStarted, attempt: connectAttempt)
        await restorePersistedOutboundQueueIfNeeded()

        do {
            try await connectTransportWithAuthRecovery(
                telemetryAttempt: connectAttempt,
                reason: "connect"
            )
            let connected = WebSocketConnectionState.connected(since: Date())
            state = connected
            health = .healthy
            lastError = nil
            reconnectPhase = .connected
            lastTransitionReason = "connect_success"
            lastRecoverability = nil
            await stateHub.emit(connected)
            emitTelemetry(type: .connectSuccess, attempt: connectAttempt)
            startConnectedLoops()
            await resendPendingAckMessages()
            await flushOutboundQueue()
        } catch {
            let mapped = mapError(error)
            lastError = mapped
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
        reconnectPhase = .recovering
        lastTransitionReason = reason ?? "force_reconnect"
        lastRecoverability = .recoverable
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

    public func registerSubscription(id: String, message: WebSocketMessage, options: WebSocketSendOptions = .init()) async {
        guard !id.isEmpty else {
            return
        }
        let resolvedMessageID = options.requiresAck ? (options.messageID ?? UUID().uuidString) : nil
        let envelope = WebSocketOutboundEnvelope(
            message: message,
            options: options,
            resolvedMessageID: resolvedMessageID
        )
        if registeredSubscriptions[id] == nil {
            subscriptionOrder.append(id)
        }
        registeredSubscriptions[id] = envelope
    }

    public func unregisterSubscription(id: String) async {
        registeredSubscriptions.removeValue(forKey: id)
        subscriptionOrder.removeAll { $0 == id }
    }

    public func clearSubscriptions() async {
        registeredSubscriptions.removeAll()
        subscriptionOrder.removeAll()
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
        reconnectPhase = .disconnected
        lastTransitionReason = reason ?? "disconnect"
        lastRecoverability = .nonRecoverable
        await stateHub.emit(state)
        await messageHub.finish()
        emitTelemetry(type: .disconnect, reason: reason)
    }

    private func sendOrQueue(_ envelope: WebSocketOutboundEnvelope) async throws {
        if case .connected = state {
            try await sendEnvelope(envelope)
            return
        }
        try await queueOutboundEnvelope(envelope)
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
        if isAckRecentlyProcessed(messageID) {
            return
        }
        pendingAckMessages[messageID] = envelope
        do {
            try await awaitAckLifecycle(envelope: envelope, messageID: messageID)
        } catch {
            pendingAckMessages.removeValue(forKey: messageID)
            throw error
        }
        pendingAckMessages.removeValue(forKey: messageID)
    }

    private func queueOutboundEnvelope(_ envelope: WebSocketOutboundEnvelope) async throws {
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
                emitTelemetry(
                    type: .messageDropped,
                    reason: "overflow_fail_fast",
                    messageKind: envelope.message.telemetryKind,
                    queueSize: outboundQueue.count,
                    queuePolicy: "failFast"
                )
                throw WebSocketError.disconnected
            }
        }

        outboundQueue.append(envelope)
        let queuePolicy = String(describing: policy.overflowPolicy)
        let pressure = queuePressureLevel(
            depth: outboundQueue.count,
            capacity: policy.maxQueuedMessages
        )
        emitTelemetry(
            type: .messageDeferred,
            reason: "socket_not_connected",
            messageKind: envelope.message.telemetryKind,
            queueSize: outboundQueue.count,
            queuePolicy: queuePolicy
        )
        emitTelemetry(
            type: .messageQueued,
            messageKind: envelope.message.telemetryKind,
            queueSize: outboundQueue.count,
            queuePolicy: "\(queuePolicy):pressure=\(pressure.rawValue)"
        )
        await persistOutboundQueueSnapshot(reason: "enqueue")
    }

    private func flushOutboundQueue() async {
        while !outboundQueue.isEmpty {
            guard case .connected = state else { return }
            let next = outboundQueue.removeFirst()
            await persistOutboundQueueSnapshot(reason: "flush")
            do {
                try await sendEnvelope(next)
            } catch {
                outboundQueue.insert(next, at: 0)
                await persistOutboundQueueSnapshot(reason: "flush_failure")
                if pendingRestoredReplayCount > 0 {
                    emitTelemetry(
                        type: .persistedReplayFailed,
                        reason: "send_failed",
                        queueSize: outboundQueue.count
                    )
                    pendingRestoredReplayCount = 0
                }
                return
            }
        }
        if pendingRestoredReplayCount > 0 {
            emitTelemetry(
                type: .persistedReplaySucceeded,
                reason: "drained",
                queueSize: 0
            )
            pendingRestoredReplayCount = 0
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

    private func awaitAckLifecycle(envelope: WebSocketOutboundEnvelope, messageID: String) async throws {
        let policy = configuration.ackPolicy
        let maxAttempts = max(1, policy.maxResendAttempts + 1)
        var attempt = 1

        while true {
            pendingAckAttempts[messageID] = attempt
            do {
                try await waitForAck(
                    messageID: messageID,
                    timeoutNanoseconds: envelope.options.ackTimeoutNanoseconds
                )
                pendingAckAttempts.removeValue(forKey: messageID)
                return
            } catch let error as WebSocketError {
                guard case .ackTimeout = error else {
                    pendingAckAttempts.removeValue(forKey: messageID)
                    throw error
                }

                let timeoutClass = policy.timeoutClass(for: envelope.options.ackTimeoutNanoseconds)
                emitTelemetry(
                    type: .ackTimeout,
                    reason: "ack_timeout:\(timeoutClass.rawValue)",
                    messageID: messageID,
                    ackTimeoutClass: timeoutClass,
                    ackAttempt: attempt
                )

                guard attempt < maxAttempts else {
                    pendingAckAttempts.removeValue(forKey: messageID)
                    throw error
                }

                attempt += 1
                pendingAckStartedAt[messageID] = DispatchTime.now().uptimeNanoseconds
                emitTelemetry(
                    type: .ackResendAttempt,
                    reason: "ack_resend",
                    messageID: messageID,
                    ackTimeoutClass: timeoutClass,
                    ackAttempt: attempt
                )
                try await transport.send(envelope.message)
                emitTelemetry(type: .messageSent, messageKind: envelope.message.telemetryKind)
            } catch {
                pendingAckAttempts.removeValue(forKey: messageID)
                throw error
            }
        }
    }

    private func waitForAck(messageID: String, timeoutNanoseconds: UInt64) async throws {
        if isAckRecentlyProcessed(messageID) {
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            ackWaiters[messageID] = continuation
            pendingAckStartedAt[messageID] = DispatchTime.now().uptimeNanoseconds
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
        pendingAckStartedAt.removeValue(forKey: messageID)
        continuation.resume(throwing: WebSocketError.ackTimeout(messageID: messageID))
    }

    private func handleAck(messageID: String) {
        guard !messageID.isEmpty else { return }
        if isAckRecentlyProcessed(messageID) {
            emitTelemetry(
                type: .ackDuplicate,
                reason: "ack_duplicate",
                messageID: messageID
            )
            return
        }
        trackAcknowledgement(for: messageID)
        pendingAckMessages.removeValue(forKey: messageID)
        pendingAckStartedAt.removeValue(forKey: messageID)
        pendingAckAttempts.removeValue(forKey: messageID)
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
        pendingAckStartedAt.removeAll()
        pendingAckAttempts.removeAll()
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
                    if let ackID = ackMatcher.match(message) {
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
        let recoverability = recoverability(for: mapped)
        lastError = mapped
        lastRecoverability = recoverability
        lastTransitionReason = "connection_loss:\(mapped)"
        reconnectPhase = .recovering
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
        return recoverability(for: error) == .recoverable
    }

    private func startReconnectLoop(
        initialError: WebSocketError,
        minimumAttempts: Int = 0,
        immediateFirstAttempt: Bool = false
    ) {
        cancelBackgroundTasks()
        lastRecoverability = recoverability(for: initialError)
        reconnectPhase = .recovering
        lastTransitionReason = "reconnect_start"

        reconnectTask = Task {
            var attempt = 0
            let maxAttempts = max(configuration.reconnectPolicy.maxAttempts, minimumAttempts)
            while !Task.isCancelled,
                  !disconnectRequested,
                  attempt < maxAttempts {
                attempt += 1
                let waitOutcome = await waitForConnectivityIfNeeded(attempt: attempt)
                guard waitOutcome.shouldContinue else {
                    reconnectTask = nil
                    return
                }
                let delayNanoseconds: UInt64
                if immediateFirstAttempt && attempt == 1 {
                    delayNanoseconds = 0
                } else if waitOutcome.waitedForConnectivity {
                    delayNanoseconds = burstGuardDelayNanoseconds()
                } else {
                    delayNanoseconds = reconnectDelayNanoseconds(forAttempt: attempt)
                }
                let delayMilliseconds = Double(delayNanoseconds) / 1_000_000

                state = .reconnecting(attempt: attempt, nextDelayMilliseconds: delayMilliseconds)
                reconnectPhase = .backoff
                lastTransitionReason = "reconnect_backoff"
                await stateHub.emit(state)
                emitTelemetry(
                    type: .reconnectAttempt,
                    attempt: attempt,
                    error: initialError
                )

                do {
                    try await retryClock.sleep(nanoseconds: delayNanoseconds)
                    try await connectTransportWithAuthRecovery(
                        telemetryAttempt: attempt,
                        reason: "reconnect"
                    )
                    let connected = WebSocketConnectionState.connected(since: Date())
                    state = connected
                    health = .healthy
                    lastError = nil
                    reconnectPhase = .connected
                    lastTransitionReason = "reconnect_success"
                    lastRecoverability = nil
                    await stateHub.emit(connected)
                    emitTelemetry(type: .reconnectSuccess, attempt: attempt)
                    reconnectTask = nil
                    startConnectedLoops()
                    await resendPendingAckMessages()
                    await flushOutboundQueue()
                    await restoreSubscriptions(attempt: attempt)
                    return
                } catch is CancellationError {
                    reconnectTask = nil
                    return
                } catch {
                    let mapped = mapError(error)
                    lastError = mapped
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
        lastError = error
        lastRecoverability = recoverability(for: error)
        lastTransitionReason = "terminal_failure:\(error)"
        reconnectPhase = .failed
        state = .failed(error)
        health = .unhealthy(reason: String(describing: error))
        await stateHub.emit(state)
        emitTelemetry(type: .connectFailed, attempt: telemetryAttempt, error: error)
    }

    private func connectTransportWithAuthRecovery(
        telemetryAttempt: Int?,
        reason: String
    ) async throws {
        var refreshAttempt = 0

        while true {
            do {
                try await transport.connect(url: configuration.url, headers: resolvedHeaders())
                return
            } catch {
                let mapped = mapError(error)
                guard case .auth = mapped, canAttemptAuthRefresh(refreshAttempt) else {
                    throw mapped
                }

                refreshAttempt += 1
                emitTelemetry(
                    type: .authRefreshStarted,
                    attempt: telemetryAttempt ?? refreshAttempt,
                    reason: reason
                )

                do {
                    let refreshed = try await authRefreshProvider?.refreshHeaders() ?? [:]
                    for (header, value) in refreshed {
                        refreshedAuthHeaders[header] = value
                    }
                    emitTelemetry(
                        type: .authRefreshSucceeded,
                        attempt: telemetryAttempt ?? refreshAttempt,
                        reason: reason
                    )
                } catch {
                    let refreshError = mapError(error)
                    emitTelemetry(
                        type: .authRefreshFailed,
                        attempt: telemetryAttempt ?? refreshAttempt,
                        reason: reason,
                        error: refreshError
                    )
                    throw WebSocketError.auth(
                        description: "auth_refresh_failed: \(String(describing: refreshError))"
                    )
                }
            }
        }
    }

    private func resolvedHeaders() -> [String: String] {
        var merged = configuration.headers
        for (header, value) in refreshedAuthHeaders {
            merged[header] = value
        }
        return merged
    }

    private func canAttemptAuthRefresh(_ refreshAttempt: Int) -> Bool {
        guard authRefreshProvider != nil else {
            return false
        }
        return refreshAttempt < configuration.authRefreshPolicy.maxAttempts
    }

    private func waitForConnectivityIfNeeded(attempt: Int) async -> (shouldContinue: Bool, waitedForConnectivity: Bool) {
        guard let connectivityMonitor else {
            return (true, false)
        }
        var iterator = connectivityMonitor.statusStream().makeAsyncIterator()
        guard let firstStatus = await iterator.next(), firstStatus == false else {
            return (true, false)
        }

        state = .reconnectingWaitingForConnectivity(attempt: attempt)
        reconnectPhase = .waitingForConnectivity
        lastTransitionReason = "offline"
        await stateHub.emit(state)
        emitTelemetry(
            type: .reconnectSuppressedOffline,
            attempt: attempt,
            reason: "offline"
        )

        while !Task.isCancelled, !disconnectRequested, let status = await iterator.next() {
            guard status else {
                continue
            }
            emitTelemetry(
                type: .reconnectResumedOnline,
                attempt: attempt,
                reason: "online"
            )
            reconnectPhase = .backoff
            lastTransitionReason = "online_resume"
            return (true, true)
        }

        return (false, true)
    }

    private func restorePersistedOutboundQueueIfNeeded() async {
        guard !didRestorePersistedOutboundQueue else {
            return
        }
        didRestorePersistedOutboundQueue = true
        guard let outboundQueueStore else {
            return
        }
        let persisted: [WebSocketQueuedMessage]
        do {
            persisted = try await outboundQueueStore.loadQueuedMessages()
        } catch let storeError as WebSocketOutboundQueueStoreError {
            if case .partiallyCorrupted(let recovered, let droppedCount) = storeError {
                emitTelemetry(
                    type: .persistedQueueLoadFailed,
                    reason: "partially_corrupted:dropped=\(droppedCount):recovered=\(recovered.count)"
                )
                persisted = recovered
            } else {
                emitTelemetry(
                    type: .persistedQueueLoadFailed,
                    reason: String(describing: storeError)
                )
                return
            }
        } catch {
            emitTelemetry(
                type: .persistedQueueLoadFailed,
                reason: String(describing: error)
            )
            return
        }
        guard !persisted.isEmpty else {
            return
        }
        let policy = configuration.outboundQueuePolicy
        guard policy.maxQueuedMessages > 0 else {
            try? await outboundQueueStore.persistQueuedMessages([])
            return
        }

        var restored = persisted.map { queued in
            WebSocketOutboundEnvelope(
                message: queued.message,
                options: queued.options,
                resolvedMessageID: queued.resolvedMessageID
            )
        }

        if restored.count > policy.maxQueuedMessages {
            switch policy.overflowPolicy {
            case .dropOldest:
                restored = Array(restored.suffix(policy.maxQueuedMessages))
            case .dropNewest:
                restored = Array(restored.prefix(policy.maxQueuedMessages))
            case .failFast:
                restored = []
            }
        }
        outboundQueue = restored
        pendingRestoredReplayCount = restored.count
        emitTelemetry(
            type: .persistedQueueRestored,
            reason: "startup_restore",
            queueSize: restored.count
        )
        await persistOutboundQueueSnapshot(reason: "restore")
    }

    private func restoreSubscriptions(attempt: Int) async {
        guard !subscriptionOrder.isEmpty else {
            return
        }

        let orderedSubscriptions = subscriptionOrder.compactMap { id -> (String, WebSocketOutboundEnvelope)? in
            guard let envelope = registeredSubscriptions[id] else {
                return nil
            }
            return (id, envelope)
        }
        guard !orderedSubscriptions.isEmpty else {
            return
        }

        let replayPolicy = configuration.subscriptionReplayPolicy
        let replayCorrelationID = UUID().uuidString

        emitTelemetry(
            type: .subscriptionRestoreStarted,
            attempt: attempt,
            subscriptionRestoreTotalCount: orderedSubscriptions.count,
            subscriptionRestoreFailedCount: 0,
            correlationID: replayCorrelationID
        )

        var failedIDs: [String] = []
        for (id, envelope) in orderedSubscriptions {
            guard case .connected = state else {
                failedIDs.append(id)
                continue
            }

            var restored = false
            for subscriptionAttempt in 1...replayPolicy.maxAttemptsPerSubscription {
                do {
                    try await sendEnvelope(envelope)
                    restored = true
                    break
                } catch {
                    if subscriptionAttempt < replayPolicy.maxAttemptsPerSubscription {
                        emitTelemetry(
                            type: .subscriptionRestoreRetry,
                            attempt: attempt,
                            reason: "subscription_replay_retry:\(id)",
                            correlationID: replayCorrelationID,
                            ackAttempt: subscriptionAttempt + 1
                        )
                        if replayPolicy.retryDelayNanoseconds > 0 {
                            try? await retryClock.sleep(nanoseconds: replayPolicy.retryDelayNanoseconds)
                        }
                        continue
                    }
                }
            }

            if !restored {
                failedIDs.append(id)
            }
        }

        if failedIDs.isEmpty {
            emitTelemetry(
                type: .subscriptionRestoreSucceeded,
                attempt: attempt,
                subscriptionRestoreTotalCount: orderedSubscriptions.count,
                subscriptionRestoreFailedCount: 0,
                correlationID: replayCorrelationID
            )
            emitTelemetry(
                type: .subscriptionRestoreCompleted,
                attempt: attempt,
                reason: "succeeded",
                subscriptionRestoreTotalCount: orderedSubscriptions.count,
                subscriptionRestoreFailedCount: 0,
                correlationID: replayCorrelationID
            )
            return
        }

        emitTelemetry(
            type: .subscriptionRestoreFailed,
            attempt: attempt,
            reason: failedIDs.joined(separator: ","),
            subscriptionRestoreTotalCount: orderedSubscriptions.count,
            subscriptionRestoreFailedCount: failedIDs.count,
            correlationID: replayCorrelationID
        )
        emitTelemetry(
            type: .subscriptionRestoreCompleted,
            attempt: attempt,
            reason: failedIDs.count == orderedSubscriptions.count ? "failed" : "partial_failure",
            subscriptionRestoreTotalCount: orderedSubscriptions.count,
            subscriptionRestoreFailedCount: failedIDs.count,
            correlationID: replayCorrelationID
        )
    }

    private func persistOutboundQueueSnapshot(reason: String) async {
        guard let outboundQueueStore else {
            return
        }
        let snapshot = outboundQueue.map { envelope in
            WebSocketQueuedMessage(
                message: envelope.message,
                options: envelope.options,
                resolvedMessageID: envelope.resolvedMessageID,
                enqueuedAt: Date()
            )
        }
        do {
            try await outboundQueueStore.persistQueuedMessages(snapshot)
            emitTelemetry(
                type: .persistedQueueSaved,
                reason: reason,
                queueSize: snapshot.count
            )
        } catch {
            emitTelemetry(
                type: .persistedQueuePersistFailed,
                reason: "\(reason):\(String(describing: error))",
                queueSize: snapshot.count
            )
        }
    }

    private func isAckRecentlyProcessed(_ messageID: String) -> Bool {
        pruneAcknowledgedMessageIDs()
        return acknowledgedMessageIDs[messageID] != nil
    }

    private func trackAcknowledgement(for messageID: String) {
        pruneAcknowledgedMessageIDs()
        let now = DispatchTime.now().uptimeNanoseconds
        acknowledgedMessageIDs[messageID] = now
        let maxTracked = configuration.ackPolicy.maxTrackedMessageIDs
        guard acknowledgedMessageIDs.count > maxTracked,
              let evictID = acknowledgedMessageIDs.min(by: { $0.value < $1.value })?.key else {
            return
        }
        acknowledgedMessageIDs.removeValue(forKey: evictID)
    }

    private func pruneAcknowledgedMessageIDs() {
        guard !acknowledgedMessageIDs.isEmpty else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let window = configuration.ackPolicy.dedupeWindowNanoseconds
        let retained = acknowledgedMessageIDs.filter { now &- $0.value < window }
        acknowledgedMessageIDs = retained
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

    private func recoverability(for error: WebSocketError) -> WebSocketRecoverability {
        switch error {
        case .timeout, .transport:
            return .recoverable
        case .auth, .protocolViolation:
            return .manualInterventionRequired
        case .cancelled, .disconnected, .reconnectExhausted, .ackTimeout:
            return .nonRecoverable
        }
    }

    private func burstGuardDelayNanoseconds() -> UInt64 {
        let jitter = configuration.reconnectPolicy.burstGuardMaxJitterNanoseconds
        guard jitter > 0 else { return 0 }
        let factor = retryRandomGenerator.nextDouble(in: 0...1)
        return UInt64(Double(jitter) * factor)
    }

    private func queuePressureLevel(depth: Int, capacity: Int) -> WebSocketQueuePressureLevel {
        guard capacity > 0 else { return .nominal }
        let ratio = Double(depth) / Double(capacity)
        if ratio >= 1.0 {
            return .critical
        }
        if ratio >= 0.8 {
            return .high
        }
        if ratio >= 0.5 {
            return .elevated
        }
        return .nominal
    }

    private func ackPendingAgeBuckets() -> WebSocketAckPendingAgeBuckets {
        guard !pendingAckStartedAt.isEmpty else {
            return .init()
        }
        let now = DispatchTime.now().uptimeNanoseconds
        var underOneSecond = 0
        var oneToFiveSeconds = 0
        var overFiveSeconds = 0

        for startedAt in pendingAckStartedAt.values {
            let age = now &- startedAt
            if age < 1_000_000_000 {
                underOneSecond += 1
            } else if age < 5_000_000_000 {
                oneToFiveSeconds += 1
            } else {
                overFiveSeconds += 1
            }
        }

        return .init(
            underOneSecond: underOneSecond,
            oneToFiveSeconds: oneToFiveSeconds,
            overFiveSeconds: overFiveSeconds
        )
    }

    private func emitTelemetry(
        type: TelemetryWebSocketEventType,
        attempt: Int? = nil,
        reason: String? = nil,
        error: WebSocketError? = nil,
        messageKind: String? = nil,
        queueSize: Int? = nil,
        queuePolicy: String? = nil,
        messageID: String? = nil,
        subscriptionRestoreTotalCount: Int? = nil,
        subscriptionRestoreFailedCount: Int? = nil,
        correlationID: String? = nil,
        ackTimeoutClass: WebSocketAckTimeoutClass? = nil,
        ackAttempt: Int? = nil
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
                messageID: messageID,
                subscriptionRestoreTotalCount: subscriptionRestoreTotalCount,
                subscriptionRestoreFailedCount: subscriptionRestoreFailedCount,
                correlationID: correlationID,
                ackTimeoutClass: ackTimeoutClass?.rawValue,
                ackAttempt: ackAttempt,
                recoverability: lastRecoverability?.rawValue,
                reconnectPhase: reconnectPhase.rawValue,
                lastTransitionReason: lastTransitionReason
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
