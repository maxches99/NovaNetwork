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
    private var acknowledgedMessageIDs: [String: UInt64] = [:]
    private var registeredSubscriptions: [String: WebSocketOutboundEnvelope] = [:]
    private var subscriptionOrder: [String] = []
    private var lastError: WebSocketError?
    private var refreshedAuthHeaders: [String: String] = [:]
    private var didRestorePersistedOutboundQueue = false
    private var pendingRestoredReplayCount = 0

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
        WebSocketDiagnostics(
            connectionID: connectionID,
            state: state,
            health: health,
            reconnectAttempt: connectAttempt,
            queuedOutboundMessages: outboundQueue.count,
            pendingAckCount: ackWaiters.count,
            trackedAckMessageIDs: acknowledgedMessageIDs.count,
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
        try await waitForAck(
            messageID: messageID,
            timeoutNanoseconds: envelope.options.ackTimeoutNanoseconds
        )
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

    private func waitForAck(messageID: String, timeoutNanoseconds: UInt64) async throws {
        if isAckRecentlyProcessed(messageID) {
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
        if isAckRecentlyProcessed(messageID) {
            return
        }
        trackAcknowledgement(for: messageID)
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
        lastError = mapped
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
                let waitOutcome = await waitForConnectivityIfNeeded(attempt: attempt)
                guard waitOutcome.shouldContinue else {
                    reconnectTask = nil
                    return
                }
                let delayNanoseconds =
                    (immediateFirstAttempt && attempt == 1) || waitOutcome.waitedForConnectivity
                    ? 0
                    : reconnectDelayNanoseconds(forAttempt: attempt)
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
                    try await connectTransportWithAuthRecovery(
                        telemetryAttempt: attempt,
                        reason: "reconnect"
                    )
                    let connected = WebSocketConnectionState.connected(since: Date())
                    state = connected
                    health = .healthy
                    lastError = nil
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

        emitTelemetry(
            type: .subscriptionRestoreStarted,
            attempt: attempt,
            subscriptionRestoreTotalCount: orderedSubscriptions.count,
            subscriptionRestoreFailedCount: 0
        )

        var failedIDs: [String] = []
        for (id, envelope) in orderedSubscriptions {
            guard case .connected = state else {
                failedIDs.append(id)
                continue
            }

            do {
                try await sendEnvelope(envelope)
            } catch {
                failedIDs.append(id)
            }
        }

        if failedIDs.isEmpty {
            emitTelemetry(
                type: .subscriptionRestoreSucceeded,
                attempt: attempt,
                subscriptionRestoreTotalCount: orderedSubscriptions.count,
                subscriptionRestoreFailedCount: 0
            )
            return
        }

        emitTelemetry(
            type: .subscriptionRestoreFailed,
            attempt: attempt,
            reason: failedIDs.joined(separator: ","),
            subscriptionRestoreTotalCount: orderedSubscriptions.count,
            subscriptionRestoreFailedCount: failedIDs.count
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
        subscriptionRestoreFailedCount: Int? = nil
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
                subscriptionRestoreFailedCount: subscriptionRestoreFailedCount
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
