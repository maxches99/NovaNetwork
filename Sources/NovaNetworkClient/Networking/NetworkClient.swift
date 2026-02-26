import Foundation

actor NetworkClientEventHub {
    private var continuations: [UUID: AsyncStream<NetworkClientEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<NetworkClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ event: NetworkClientEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}

actor OfflineQueueEventHub {
    private var continuations: [UUID: AsyncStream<OfflineQueueEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<OfflineQueueEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ event: OfflineQueueEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}

actor OfflineReplayGate {
    private var isRunning = false

    func begin() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    func end() {
        isRunning = false
    }
}

public final class NetworkClient: @unchecked Sendable {
    private let coalescer: RequestCoalescer<NetworkResponse, NetworkError>
    private let transport: any NetworkTransport
    private let fingerprintPolicy: FingerprintPolicy
    private let retryPolicy: RetryPolicy
    private let retryClock: any RetryClock
    private let retryRandomGenerator: any RetryRandomGenerator
    private let defaultCachePolicy: CachePolicy
    private let cache: any ResponseCache
    private let offlineWriteStore: (any OfflineWriteStore)?
    private let offlineConnectivityMonitor: (any OfflineConnectivityMonitor)?
    private let decoder: JSONDecoder
    private let networkObserver: (@Sendable (NetworkClientEvent) -> Void)?
    private let middlewares: [NetworkMiddleware]
    private let telemetryHooks: NetworkTelemetryHooks?
    private let eventHub = NetworkClientEventHub()
    private let offlineQueueEventHub = OfflineQueueEventHub()
    private let offlineReplayGate = OfflineReplayGate()
    private let circuitBreakerStore = CircuitBreakerStore()
    private let rateLimiter = KeyRateLimiter()
    private let runtimePolicyStore = RuntimePolicyStore()
    private var offlineReplayListenerTask: Task<Void, Never>?

    private struct RequestDeadline: Sendable {
        let deadlineNanoseconds: UInt64
    }

    public init(
        transport: any NetworkTransport = Transport(),
        cancellationPolicy: CancellationPolicy = .keepRunning,
        coalescerLimits: RequestCoalescer<NetworkResponse, NetworkError>.Limits = .init(),
        fingerprintPolicy: FingerprintPolicy = .default,
        retryPolicy: RetryPolicy = .none,
        retryClock: any RetryClock = SystemRetryClock(),
        retryRandomGenerator: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        defaultCachePolicy: CachePolicy = .networkOnly,
        cacheMaxEntries: Int? = 256,
        cache: (any ResponseCache)? = nil,
        offlineWriteStore: (any OfflineWriteStore)? = nil,
        offlineConnectivityMonitor: (any OfflineConnectivityMonitor)? = nil,
        observer: RequestCoalescer<NetworkResponse, NetworkError>.Observer? = nil,
        networkObserver: (@Sendable (NetworkClientEvent) -> Void)? = nil,
        middlewares: [NetworkMiddleware] = [],
        telemetryHooks: NetworkTelemetryHooks? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.transport = transport
        let combinedObserver: RequestCoalescer<NetworkResponse, NetworkError>.Observer? = { event in
            observer?(event)
            if let context = Self.telemetryCoalescerContext(from: event) {
                telemetryHooks?.onCoalescerEvent?(context)
            }
        }
        let queueMetricsObserver: RequestCoalescer<NetworkResponse, NetworkError>.QueueMetricsObserver? = { metrics in
            telemetryHooks?.onQueueMetrics?(
                TelemetryQueueContext(
                    key: metrics.key,
                    queueDepth: metrics.queueDepth,
                    waitMilliseconds: metrics.waitMilliseconds
                )
            )
        }
        self.coalescer = RequestCoalescer(
            policy: cancellationPolicy,
            limits: coalescerLimits,
            observer: combinedObserver,
            queueMetricsObserver: queueMetricsObserver,
            overflowFailureFactory: { NetworkError.coalescerLimitExceeded }
        )
        self.fingerprintPolicy = fingerprintPolicy
        self.retryPolicy = retryPolicy
        self.retryClock = retryClock
        self.retryRandomGenerator = retryRandomGenerator
        self.defaultCachePolicy = defaultCachePolicy.normalized
        self.cache = cache ?? MemoryResponseCache(maxEntries: cacheMaxEntries)
        self.offlineWriteStore = offlineWriteStore
        self.offlineConnectivityMonitor = offlineConnectivityMonitor
        self.decoder = decoder
        self.networkObserver = networkObserver
        self.middlewares = middlewares
        self.telemetryHooks = telemetryHooks

        if let offlineConnectivityMonitor {
            offlineReplayListenerTask = Task {
                let stream = offlineConnectivityMonitor.statusStream()
                for await isOnline in stream where isOnline {
                    _ = await self.flushOfflineQueue()
                }
            }
        }
    }

    deinit {
        offlineReplayListenerTask?.cancel()
    }

    public func events() -> AsyncStream<NetworkClientEvent> {
        AsyncStream { continuation in
            Task {
                let upstream = await eventHub.makeStream()
                for await event in upstream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    public func offlineQueueEvents() -> AsyncStream<OfflineQueueEvent> {
        AsyncStream { continuation in
            Task {
                let upstream = await offlineQueueEventHub.makeStream()
                for await event in upstream {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    public func updateRuntimePolicy(
        _ policy: NetworkClientRuntimePolicy,
        scope: RuntimePolicyScope = .global
    ) async {
        let changedFields = await runtimePolicyStore.update(policy: policy, scope: scope)
        let scopeName = runtimePolicyScopeName(scope)
        emit(.requestPolicyUpdated(scope: scopeName, changedFields: changedFields))
        telemetryHooks?.onPolicyUpdated?(
            TelemetryPolicyUpdateContext(scope: scopeName, changedFields: changedFields)
        )
    }

    public func load(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> Data {
        let fingerprint = makeFingerprint(for: request, authScope: authScope)
        let key = fingerprint.key
        let resolvedPolicy = (cachePolicy ?? defaultCachePolicy).normalized

        switch resolvedPolicy {
        case .networkOnly:
            emit(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(
                request: request,
                authScope: authScope,
                key: key,
                storeInCache: false,
                cachedETag: nil,
                options: options
            )
        case .cacheFirst(let maxAge):
            if let cached = await cache.entry(forKey: key) {
                guard varyMatches(cached: cached, request: request) else {
                    emit(.cacheMiss(key: key))
                    return try await fetchNetworkAndOptionallyStore(
                        request: request,
                        authScope: authScope,
                        key: key,
                        storeInCache: true,
                        cachedETag: nil,
                        options: options
                    )
                }

                let age = ageSeconds(since: cached.storedAtNanoseconds)
                let effectiveMaxAge = effectiveMaxAge(clientMaxAge: maxAge, cached: cached)
                if age <= effectiveMaxAge || isFreshByExpiresHeader(cached: cached) {
                    emit(.cacheHit(
                        key: key,
                        isStale: false,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))
                    return cached.body
                }

                // Attempt conditional revalidation before returning an expired entry.
                do {
                    return try await fetchNetworkAndOptionallyStore(
                        request: request,
                        authScope: authScope,
                        key: key,
                        storeInCache: true,
                        cachedETag: cached.etag,
                        options: options
                    )
                } catch {
                    emit(.cacheMiss(key: key))
                    throw error
                }
            }

            emit(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(
                request: request,
                authScope: authScope,
                key: key,
                storeInCache: true,
                cachedETag: nil,
                options: options
            )
        case .staleWhileRevalidate(let maxAge, let staleAge):
            if let cached = await cache.entry(forKey: key) {
                guard varyMatches(cached: cached, request: request) else {
                    emit(.cacheMiss(key: key))
                    return try await fetchNetworkAndOptionallyStore(
                        request: request,
                        authScope: authScope,
                        key: key,
                        storeInCache: true,
                        cachedETag: nil,
                        options: options
                    )
                }

                let age = ageSeconds(since: cached.storedAtNanoseconds)
                let freshness = effectiveStaleAges(clientMaxAge: maxAge, clientStaleAge: staleAge, cached: cached)
                if age <= freshness.maxAge || isFreshByExpiresHeader(cached: cached) {
                    emit(.cacheHit(
                        key: key,
                        isStale: false,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))
                    return cached.body
                }

                if age <= freshness.staleAge {
                    emit(.cacheHit(
                        key: key,
                        isStale: true,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))

                    Task {
                        _ = try? await self.fetchNetworkAndOptionallyStore(
                            request: request,
                            authScope: authScope,
                            key: key,
                            storeInCache: true,
                            cachedETag: cached.etag,
                            options: options
                        )
                    }
                    return cached.body
                }
            }

            emit(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(
                request: request,
                authScope: authScope,
                key: key,
                storeInCache: true,
                cachedETag: nil,
                options: options
            )
        }
    }

    public func load<T: Decodable & Sendable>(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        as type: T.Type = T.self,
        decoder: JSONDecoder? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> T {
        let data = try await load(
            request: request,
            authScope: authScope,
            cachePolicy: cachePolicy,
            options: options
        )
        let decoderToUse = decoder ?? self.decoder

        do {
            return try decoderToUse.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(underlying: error)
        }
    }

    public func enqueueWrite(
        request: APIRequest,
        authScope: String?,
        options: RequestExecutionOptions = .init()
    ) async throws -> QueuedWriteResult {
        let key = makeFingerprint(for: request, authScope: authScope).key
        let queuePolicy = options.offlineQueuePolicy
        let isQueueEligibleMethod = Self.isQueueEligibleWriteMethod(request.method)
        let queueIdempotencyPolicy = options.idempotencyPolicy ?? .default
        let queuePreparedRequest = applyIdempotencyPolicy(
            request: request,
            key: key,
            idempotencyPolicy: queueIdempotencyPolicy
        )

        if queuePolicy.mode == .alwaysEnqueue, isQueueEligibleMethod {
            return try await enqueuePreparedWrite(request: queuePreparedRequest, requestKey: key)
        }

        do {
            let data = try await fetchNetworkAndOptionallyStore(
                request: queuePreparedRequest,
                authScope: authScope,
                key: key,
                storeInCache: false,
                cachedETag: nil,
                options: options
            )
            return .completed(data)
        } catch let error as NetworkError {
            guard queuePolicy.mode == .enqueueWhenOffline, isQueueEligibleMethod, Self.isOfflineError(error) else {
                throw error
            }
            return try await enqueuePreparedWrite(request: queuePreparedRequest, requestKey: key)
        }
    }

    @discardableResult
    public func flushOfflineQueue(limit: Int = 64) async -> Int {
        guard let offlineWriteStore else { return 0 }
        guard limit > 0 else { return 0 }
        guard await offlineReplayGate.begin() else { return 0 }
        defer {
            Task { await offlineReplayGate.end() }
        }

        var replayedCount = 0
        while replayedCount < limit {
            let remaining = max(1, limit - replayedCount)
            let batch = await offlineWriteStore.nextBatch(limit: remaining, now: Date())
            guard !batch.isEmpty else { break }

            for entry in batch {
                if replayedCount >= limit {
                    break
                }
                await replayOfflineEntry(entry, store: offlineWriteStore)
                replayedCount += 1
            }
        }
        return replayedCount
    }

    public func offlineQueueDepth() async -> Int {
        guard let offlineWriteStore else { return 0 }
        return await offlineWriteStore.depth(now: Date())
    }

    public func offlineQueueSnapshot() async -> [OfflineQueueSnapshotItem] {
        guard let offlineWriteStore else { return [] }
        let entries = await offlineWriteStore.snapshot(now: Date())
        return entries
            .map { entry in
                OfflineQueueSnapshotItem(
                    receipt: entry.receipt,
                    method: entry.request.method,
                    url: entry.request.url,
                    attempt: entry.attempt,
                    state: entry.state
                )
            }
            .sorted { lhs, rhs in
                lhs.receipt.position < rhs.receipt.position
            }
    }

    @discardableResult
    public func dropQueuedWrite(queueID: String) async -> Bool {
        guard let offlineWriteStore else { return false }
        let snapshot = await offlineWriteStore.snapshot(now: Date())
        let entry = snapshot.first { $0.receipt.queueID == queueID }
        let dropped = await offlineWriteStore.drop(queueID: queueID)
        if dropped, let entry {
            await emitOfflineQueueEvent(
                .dropped(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    reason: "manual_drop"
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .dropped,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: entry.attempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: "manual_drop",
                    willRetry: false
                )
            )
        }
        return dropped
    }

    @discardableResult
    public func dropAllQueuedWrites() async -> Int {
        guard let offlineWriteStore else { return 0 }
        let snapshot = await offlineWriteStore.snapshot(now: Date())
        let removed = await offlineWriteStore.dropAll()
        for entry in snapshot {
            await emitOfflineQueueEvent(
                .dropped(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    reason: "manual_drop_all"
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .dropped,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: entry.attempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: "manual_drop_all",
                    willRetry: false
                )
            )
        }
        return removed
    }

    public func load<T: Decodable & Sendable, E: Error>(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        as type: T.Type = T.self,
        decoder: JSONDecoder? = nil,
        options: RequestExecutionOptions = .init(),
        errorMapper: @Sendable (NetworkError) -> E
    ) async throws -> T {
        do {
            return try await load(
                request: request,
                authScope: authScope,
                cachePolicy: cachePolicy,
                as: type,
                decoder: decoder,
                options: options
            )
        } catch let error as NetworkError {
            throw errorMapper(error)
        } catch {
            throw errorMapper(.transport(underlying: error))
        }
    }

    public func load<E: Error>(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init(),
        errorMapper: @Sendable (NetworkError) -> E
    ) async throws -> Data {
        do {
            return try await load(
                request: request,
                authScope: authScope,
                cachePolicy: cachePolicy,
                options: options
            )
        } catch let error as NetworkError {
            throw errorMapper(error)
        } catch {
            throw errorMapper(.transport(underlying: error))
        }
    }

    public func loadBatch(
        requests: [APIRequest],
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> [Data] {
        var orderedResults: [Data] = []
        orderedResults.reserveCapacity(requests.count)
        for request in requests {
            let data = try await load(
                request: request,
                authScope: authScope,
                cachePolicy: cachePolicy,
                options: options
            )
            orderedResults.append(data)
        }
        return orderedResults
    }

    public func loadStream(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init()
    ) -> AsyncThrowingStream<Data, Error> {
        if let streamingTransport = transport as? any StreamingNetworkTransport {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let prepared = try await prepareRequestForExecution(
                            request: request,
                            key: makeFingerprint(for: request, authScope: authScope).key,
                            options: options
                        )
                        let stream = streamingTransport.stream(prepared, authScope: authScope)
                        for try await chunk in stream {
                            continuation.yield(chunk)
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let data = try await self.load(
                        request: request,
                        authScope: authScope,
                        cachePolicy: cachePolicy,
                        options: options
                    )
                    continuation.yield(data)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func coalescerMetrics() async -> RequestCoalescer<NetworkResponse, NetworkError>.Metrics {
        await coalescer.snapshotMetrics()
    }

    public func inFlightRequests() async -> [RequestCoalescer<NetworkResponse, NetworkError>.InFlightEntry] {
        await coalescer.inFlightEntries()
    }

    public func preload(
        request: APIRequest,
        authScope: String?,
        options: RequestExecutionOptions = .init()
    ) async throws {
        let key = makeFingerprint(for: request, authScope: authScope).key
        _ = try await fetchNetworkAndOptionallyStore(
            request: request,
            authScope: authScope,
            key: key,
            storeInCache: true,
            cachedETag: nil,
            options: options
        )
    }

    public func invalidate(request: APIRequest, authScope: String?) async {
        let key = makeFingerprint(for: request, authScope: authScope).key
        await cache.remove(key: key)
        emit(.cacheInvalidated(key: key))
    }

    public func invalidate(fingerprintKey: String) async {
        await cache.remove(key: fingerprintKey)
        emit(.cacheInvalidated(key: fingerprintKey))
    }

    public func invalidateAll() async {
        await cache.removeAll()
    }

    public func invalidateAll(where shouldRemove: @escaping @Sendable (String) -> Bool) async {
        await cache.removeAll(where: shouldRemove)
    }

    public func handleMemoryPressure(
        clearCache: Bool = true,
        cancelInFlight: Bool = true
    ) async {
        if clearCache {
            await cache.removeAll()
        }
        if cancelInFlight {
            await coalescer.handleMemoryPressure(cancelInFlight: true)
        }
        emit(.memoryPressureHandled(cacheCleared: clearCache, inFlightCancelled: cancelInFlight))
    }

    private func makeFingerprint(for request: APIRequest, authScope: String?) -> RequestFingerprint {
        RequestFingerprint.make(
            method: request.method.rawValue,
            url: request.url,
            queryItems: request.queryItems,
            headers: request.headers,
            body: request.body,
            authScope: authScope,
            policy: fingerprintPolicy
        )
    }

    private func fetchNetworkAndOptionallyStore(
        request: APIRequest,
        authScope: String?,
        key: String,
        storeInCache: Bool,
        cachedETag: String?,
        options: RequestExecutionOptions
    ) async throws -> Data {
        let resolvedRuntimePolicy = await runtimePolicyStore.resolve(url: request.url)
        let hasRequestOverrides = options.deadlineBudgetSeconds != nil || options.circuitBreakerPolicy != nil
        let resolvedRetryPolicy = resolvedRuntimePolicy.policy.retryPolicy ?? retryPolicy
        let resolvedDeadlineBudget = options.deadlineBudgetSeconds ?? resolvedRuntimePolicy.policy.deadlineBudgetSeconds
        let resolvedBreakerPolicy = options.circuitBreakerPolicy ?? resolvedRuntimePolicy.policy.circuitBreakerPolicy
        let policyScope = hasRequestOverrides ? RuntimePolicySource.requestOverride : resolvedRuntimePolicy.source
        let requestDeadline = makeDeadline(from: resolvedDeadlineBudget)
        let telemetryCoalescingMode = telemetryCoalescingMode(for: options.coalescingMode)
        let coalescingKey = resolvedCoalescingKey(baseKey: key, mode: options.coalescingMode)

        if let rateLimitPolicy = options.rateLimitPolicy,
           let retryAfter = await rateLimiter.acquire(key: key, policy: rateLimitPolicy) {
            emit(.requestRateLimited(key: key, retryAfterSeconds: retryAfter))
            throw NetworkError.clientRateLimited(retryAfterSeconds: retryAfter)
        }

        if let breakerPolicy = resolvedBreakerPolicy {
            let identifier = circuitBreakerIdentifier(for: request, key: key, policy: breakerPolicy)
            let decision = await circuitBreakerStore.canExecute(identifier: identifier, policy: breakerPolicy)
            if let transition = decision.transition {
                emitCircuitBreakerTransition(transition)
            }
            if !decision.canExecute {
                emit(.circuitBreakerOpen(identifier: identifier))
                throw NetworkError.circuitBreakerOpen
            }
        }

        let conditionalRequest: APIRequest
        if let etag = cachedETag {
            conditionalRequest = request.withMergedHeaders(["If-None-Match": etag])
        } else {
            conditionalRequest = request
        }
        let preparedRequest = try await prepareRequestForExecution(
            request: conditionalRequest,
            key: key,
            options: options
        )

        let outcome: NetworkResponse
        do {
            outcome = try await coalescer.run(
                key: coalescingKey,
                options: coalescerRunOptions(from: options)
            ) {
                await Self.executeWithRetry(
                    key: key,
                    request: preparedRequest,
                    authScope: authScope,
                    transport: self.transport,
                    retryPolicy: resolvedRetryPolicy,
                    retryClock: self.retryClock,
                    retryRandomGenerator: self.retryRandomGenerator,
                    middlewares: self.middlewares,
                    telemetryHooks: self.telemetryHooks,
                    observer: self.networkObserver,
                    deadline: requestDeadline,
                    coalescingMode: telemetryCoalescingMode,
                    policyScope: policyScope.rawValue
                )
            }
        } catch {
            if let breakerPolicy = resolvedBreakerPolicy,
               let networkError = error as? NetworkError,
               shouldCountFailureForCircuitBreaker(networkError) {
                let identifier = circuitBreakerIdentifier(for: request, key: key, policy: breakerPolicy)
                if let transition = await circuitBreakerStore.recordFailure(identifier: identifier, policy: breakerPolicy) {
                    emitCircuitBreakerTransition(transition)
                }
            }
            throw error
        }

        if outcome.statusCode == 304, let cached = await cache.entry(forKey: key) {
            if storeInCache {
                let revalidated = CachedResponse(
                    body: cached.body,
                    statusCode: cached.statusCode,
                    headers: cached.headers,
                    etag: cached.etag,
                    storedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    varyRequestHeaders: cached.varyRequestHeaders
                )
                await cache.set(revalidated, forKey: key)
            }
            emit(.cacheRevalidated(key: key, ageMilliseconds: 0))
            return cached.body
        }

        if storeInCache && shouldStoreInCache(outcome.headers) {
            let cached = CachedResponse(
                body: outcome.body,
                statusCode: outcome.statusCode,
                headers: outcome.headers,
                etag: outcome.headerValue(for: "ETag"),
                storedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                varyRequestHeaders: varyHeaders(from: outcome.headers, requestHeaders: preparedRequest.headers)
            )
            await cache.set(cached, forKey: key)
        }

        if let breakerPolicy = resolvedBreakerPolicy {
            let identifier = circuitBreakerIdentifier(for: request, key: key, policy: breakerPolicy)
            if let transition = await circuitBreakerStore.recordSuccess(identifier: identifier, policy: breakerPolicy) {
                emitCircuitBreakerTransition(transition)
            }
        }

        return outcome.body
    }

    private func shouldCountFailureForCircuitBreaker(_ error: NetworkError) -> Bool {
        switch error.failureReason {
        case .rateLimited, .timedOut, .transport:
            return true
        case .httpStatus(let code):
            return code >= 500
        default:
            return false
        }
    }

    private func coalescerRunOptions(from options: RequestExecutionOptions) -> RequestCoalescer<NetworkResponse, NetworkError>.RunOptions {
        let priority: RequestCoalescer<NetworkResponse, NetworkError>.RequestPriority
        switch options.priority {
        case .low:
            priority = .low
        case .medium:
            priority = .medium
        case .high:
            priority = .high
        }

        let scheduling: RequestCoalescer<NetworkResponse, NetworkError>.CapacityScheduling
        switch options.capacityScheduling {
        case .bypassWhenAtCapacity:
            scheduling = .bypassWhenAtCapacity
        case .queueByPriority:
            scheduling = .queueByPriority
        }

        return .init(
            limitsOverride: options.coalescerLimitsOverride,
            priority: priority,
            capacityScheduling: scheduling
        )
    }

    private func circuitBreakerIdentifier(
        for request: APIRequest,
        key: String,
        policy: CircuitBreakerPolicy
    ) -> String {
        switch policy.scope {
        case .key:
            return key
        case .host:
            return request.url.host ?? key
        }
    }

    private func resolvedCoalescingKey(baseKey: String, mode: CoalescingMode) -> String {
        switch mode {
        case .default:
            return baseKey
        case .custom(let customKey):
            return customKey
        case .disabled:
            return "\(baseKey)#\(UUID().uuidString)"
        }
    }

    private func telemetryCoalescingMode(for mode: CoalescingMode) -> TelemetryCoalescingMode {
        switch mode {
        case .default:
            return .default
        case .custom:
            return .custom
        case .disabled:
            return .disabled
        }
    }

    private func runtimePolicyScopeName(_ scope: RuntimePolicyScope) -> String {
        switch scope {
        case .global:
            return RuntimePolicySource.global.rawValue
        case .host:
            return RuntimePolicySource.host.rawValue
        case .endpoint:
            return RuntimePolicySource.endpoint.rawValue
        }
    }

    private func makeDeadline(from budgetSeconds: TimeInterval?) -> RequestDeadline? {
        guard let budgetSeconds else { return nil }
        let budgetNanoseconds = UInt64(budgetSeconds * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        return RequestDeadline(deadlineNanoseconds: now.saturatingAdd(budgetNanoseconds))
    }

    private func emitCircuitBreakerTransition(_ transition: CircuitBreakerTransition) {
        emit(
            .circuitBreakerTransition(
                identifier: transition.identifier,
                fromState: transition.fromState.rawValue,
                toState: transition.toState.rawValue,
                failureCount: transition.failureCount,
                openDurationMilliseconds: transition.openDurationMilliseconds
            )
        )
        telemetryHooks?.onCircuitBreakerTransition?(
            TelemetryCircuitBreakerTransitionContext(
                identifier: transition.identifier,
                fromState: transition.fromState.rawValue,
                toState: transition.toState.rawValue,
                failureCount: transition.failureCount,
                openDurationMilliseconds: transition.openDurationMilliseconds
            )
        )
    }

    private func ageSeconds(since startNanoseconds: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startNanoseconds ? (now - startNanoseconds) : 0
        return TimeInterval(elapsed) / 1_000_000_000
    }

    private func ageMilliseconds(since startNanoseconds: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startNanoseconds ? (now - startNanoseconds) : 0
        return Double(elapsed) / 1_000_000
    }

    private static func executeWithRetry(
        key: String,
        request: APIRequest,
        authScope: String?,
        transport: any NetworkTransport,
        retryPolicy: RetryPolicy,
        retryClock: any RetryClock,
        retryRandomGenerator: any RetryRandomGenerator,
        middlewares: [NetworkMiddleware],
        telemetryHooks: NetworkTelemetryHooks?,
        observer: (@Sendable (NetworkClientEvent) -> Void)?,
        deadline: RequestDeadline?,
        coalescingMode: TelemetryCoalescingMode,
        policyScope: String
    ) async -> Result<NetworkResponse, NetworkError> {
        var attempt = 1
        var retriesUsed = 0

        while true {
            if deadlineHasExpired(deadline) {
                observer?(
                    .requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: "timeout_budget_exhausted",
                        remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                    )
                )
                return .failure(.timeoutBudgetExceeded)
            }
            if Task.isCancelled {
                observer?(
                    .requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: "cancelled",
                        remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                    )
                )
                telemetryHooks?.onRequestCancelled?(
                    TelemetryCancellationContext(
                        key: key,
                        attempt: attempt,
                        reason: "taskCancelled",
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                return .failure(.cancelled)
            }
            observer?(.requestAttempt(key: key, attempt: attempt))

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let telemetryRequest = TelemetryRequestContext(
                key: key,
                attempt: attempt,
                coalescingMode: coalescingMode,
                request: request
            )
            telemetryHooks?.onRequestStart?(telemetryRequest)

            do {
                let preparedRequest = try await applyBeforeSendMiddlewares(
                    middlewares: middlewares,
                    request: request,
                    authScope: authScope
                )
                let response = try await transport.execute(preparedRequest)
                let postProcessed = try await applyAfterResponseMiddlewares(
                    middlewares: middlewares,
                    request: preparedRequest,
                    authScope: authScope,
                    response: response
                )

                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: postProcessed,
                        error: nil,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )
                observer?(.requestSucceeded(key: key, attempts: attempt))
                return .success(postProcessed)
            } catch is CancellationError {
                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: nil,
                        error: .cancelled,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )
                observer?(
                    .requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: "cancelled",
                        remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                    )
                )
                telemetryHooks?.onRequestCancelled?(
                    TelemetryCancellationContext(
                        key: key,
                        attempt: attempt,
                        reason: "cancellationError",
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                return .failure(.cancelled)
            } catch let error as NetworkError {
                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: nil,
                        error: error,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )

                let reason = failureReason(error: error)
                let shouldRetry = retryPolicy.shouldRetry(error: error, request: request)
                if !shouldRetry {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(error)
                }
                if !retryPolicy.canRetry(attempt: attempt, retriesUsed: retriesUsed, error: error) {
                    observer?(.retryExhausted(key: key, attempts: attempt, reason: reason))
                    telemetryHooks?.onRetryExhausted?(
                        TelemetryRetryExhaustedContext(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(error)
                }

                let retryDecision = retryPolicy.delayDecision(
                    forAttempt: attempt,
                    error: error,
                    random: retryRandomGenerator
                )
                if !canScheduleRetry(withDelayNanoseconds: retryDecision.delayNanoseconds, deadline: deadline) {
                    observer?(
                        .retrySkipped(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient"
                        )
                    )
                    telemetryHooks?.onRetrySkipped?(
                        TelemetryRetrySkippedContext(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "timeout_budget_exhausted",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(.timeoutBudgetExceeded)
                }
                observer?(
                    .retryScheduled(
                        key: key,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason
                    )
                )
                telemetryHooks?.onRetryScheduled?(
                    TelemetryRetryContext(
                        key: key,
                        attempt: attempt,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason,
                        scheduleSource: retryDecision.source.rawValue,
                        retryProfile: retryDecision.category.rawValue,
                        policyScope: policyScope,
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                do {
                    try await retryClock.sleep(nanoseconds: retryDecision.delayNanoseconds)
                } catch {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "retrySleepCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }
                if Task.isCancelled {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "taskCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }

                retriesUsed += 1
                attempt += 1
                continue
            } catch {
                let wrapped = NetworkError.transport(underlying: error)
                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: nil,
                        error: wrapped,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )

                let reason = failureReason(error: wrapped)
                let shouldRetry = retryPolicy.shouldRetry(error: wrapped, request: request)
                if !shouldRetry {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(wrapped)
                }
                if !retryPolicy.canRetry(attempt: attempt, retriesUsed: retriesUsed, error: wrapped) {
                    observer?(.retryExhausted(key: key, attempts: attempt, reason: reason))
                    telemetryHooks?.onRetryExhausted?(
                        TelemetryRetryExhaustedContext(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(wrapped)
                }

                let retryDecision = retryPolicy.delayDecision(
                    forAttempt: attempt,
                    error: wrapped,
                    random: retryRandomGenerator
                )
                if !canScheduleRetry(withDelayNanoseconds: retryDecision.delayNanoseconds, deadline: deadline) {
                    observer?(
                        .retrySkipped(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient"
                        )
                    )
                    telemetryHooks?.onRetrySkipped?(
                        TelemetryRetrySkippedContext(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "timeout_budget_exhausted",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(.timeoutBudgetExceeded)
                }
                observer?(
                    .retryScheduled(
                        key: key,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason
                    )
                )
                telemetryHooks?.onRetryScheduled?(
                    TelemetryRetryContext(
                        key: key,
                        attempt: attempt,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason,
                        scheduleSource: retryDecision.source.rawValue,
                        retryProfile: retryDecision.category.rawValue,
                        policyScope: policyScope,
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                do {
                    try await retryClock.sleep(nanoseconds: retryDecision.delayNanoseconds)
                } catch {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "retrySleepCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }
                if Task.isCancelled {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "taskCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }

                retriesUsed += 1
                attempt += 1
                continue
            }
        }
    }

    private static func deadlineHasExpired(_ deadline: RequestDeadline?) -> Bool {
        guard let deadline else { return false }
        return DispatchTime.now().uptimeNanoseconds >= deadline.deadlineNanoseconds
    }

    private static func remainingBudgetMilliseconds(_ deadline: RequestDeadline?) -> Double? {
        guard let deadline else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline.deadlineNanoseconds {
            return 0
        }
        return Double(deadline.deadlineNanoseconds - now) / 1_000_000
    }

    private static func canScheduleRetry(
        withDelayNanoseconds delayNanoseconds: UInt64,
        deadline: RequestDeadline?
    ) -> Bool {
        guard let deadline else { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.deadlineNanoseconds else { return false }
        let remaining = deadline.deadlineNanoseconds - now
        return delayNanoseconds < remaining
    }

    private static func failureReason(error: NetworkError) -> String {
        switch error {
        case .invalidResponse:
            return "invalid_response"
        case .httpStatus(let code, _, _):
            return "http_status_\(code)"
        case .decoding:
            return "decoding"
        case .transport(let underlying as URLError):
            return "transport_\(underlying.code.rawValue)"
        case .transport:
            return "transport"
        case .cancelled:
            return "cancelled"
        case .timeoutBudgetExceeded:
            return "timeout_budget_exhausted"
        case .circuitBreakerOpen:
            return "circuit_open"
        case .coalescerLimitExceeded:
            return "coalescer_limit_exceeded"
        case .clientRateLimited:
            return "client_rate_limited"
        case .queueCapacityExceeded:
            return "offline_queue_capacity_exceeded"
        case .offlineQueueUnavailable:
            return "offline_queue_unavailable"
        }
    }

    private static func telemetryCoalescerContext(
        from event: RequestCoalescer<NetworkResponse, NetworkError>.Event
    ) -> TelemetryCoalescerContext? {
        switch event {
        case .started(let key):
            return TelemetryCoalescerContext(type: .started, key: key)
        case .coalesced(let key, let waiterCount):
            return TelemetryCoalescerContext(type: .coalesced, key: key, waiterCount: waiterCount)
        case .bypassed(let key, let reason):
            return TelemetryCoalescerContext(type: .bypassed, key: key, reason: reason.rawValue)
        case .waiterCancelled(let key, let remainingWaiters):
            return TelemetryCoalescerContext(type: .waiterCancelled, key: key, waiterCount: remainingWaiters)
        case .timedOut(let key, let durationMilliseconds, let waiterCount):
            return TelemetryCoalescerContext(
                type: .timedOut,
                key: key,
                waiterCount: waiterCount,
                durationMilliseconds: durationMilliseconds,
                wasCancelled: true
            )
        case .finished(let key, let durationMilliseconds, let waiterCount, let wasCancelled):
            return TelemetryCoalescerContext(
                type: .finished,
                key: key,
                waiterCount: waiterCount,
                durationMilliseconds: durationMilliseconds,
                wasCancelled: wasCancelled
            )
        }
    }

    private func prepareRequestForExecution(
        request: APIRequest,
        key: String,
        options: RequestExecutionOptions
    ) async throws -> APIRequest {
        applyIdempotencyPolicy(
            request: request,
            key: key,
            idempotencyPolicy: options.idempotencyPolicy
        )
    }

    private func enqueuePreparedWrite(request: APIRequest, requestKey: String) async throws -> QueuedWriteResult {
        guard let offlineWriteStore else {
            throw NetworkError.offlineQueueUnavailable
        }
        do {
            let receipt = try await offlineWriteStore.enqueue(
                request: request,
                requestKey: requestKey,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .enqueued(receipt: receipt),
                telemetry: telemetryOfflineQueueContext(
                    type: .enqueued,
                    queueID: receipt.queueID,
                    requestKey: receipt.requestKey,
                    attempt: 0,
                    enqueuedAt: receipt.enqueuedAt
                )
            )
            return .queued(receipt)
        } catch let error as OfflineWriteStoreError {
            switch error {
            case .queueCapacityExceeded(let limit):
                throw NetworkError.queueCapacityExceeded(limit: limit)
            }
        } catch {
            throw NetworkError.offlineQueueUnavailable
        }
    }

    private func applyIdempotencyPolicy(
        request: APIRequest,
        key: String,
        idempotencyPolicy: IdempotencyPolicy?
    ) -> APIRequest {
        guard let idempotencyPolicy else {
            return request
        }
        guard idempotencyPolicy.guardedMethods.contains(request.method) else {
            return request
        }
        if request.headers.keys.contains(where: { $0.caseInsensitiveCompare(idempotencyPolicy.headerName) == .orderedSame }) {
            return request
        }

        let idempotencyKey: String
        switch idempotencyPolicy.keyStrategy {
        case .uuid:
            idempotencyKey = UUID().uuidString
        case .fingerprintDigest:
            idempotencyKey = SHA256Util.hex(Data(key.utf8))
        }
        return request.withMergedHeaders([idempotencyPolicy.headerName: idempotencyKey])
    }

    private func replayOfflineEntry(_ entry: OfflineWriteStoreEntry, store: any OfflineWriteStore) async {
        let nextAttempt = max(1, entry.attempt + 1)
        await store.markReplaying(queueID: entry.receipt.queueID, attempt: nextAttempt, now: Date())
        await emitOfflineQueueEvent(
            .replayStarted(queueID: entry.receipt.queueID, requestKey: entry.receipt.requestKey, attempt: nextAttempt),
            telemetry: telemetryOfflineQueueContext(
                type: .replayStarted,
                queueID: entry.receipt.queueID,
                requestKey: entry.receipt.requestKey,
                attempt: nextAttempt,
                enqueuedAt: entry.receipt.enqueuedAt
            )
        )

        do {
            _ = try await fetchNetworkAndOptionallyStore(
                request: entry.request,
                authScope: nil,
                key: entry.receipt.requestKey,
                storeInCache: false,
                cachedETag: nil,
                options: .init()
            )
            await store.markSucceeded(queueID: entry.receipt.queueID)
            await emitOfflineQueueEvent(
                .replaySucceeded(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    statusCode: 200
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replaySucceeded,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    enqueuedAt: entry.receipt.enqueuedAt
                )
            )
        } catch let error as NetworkError {
            if shouldDeadLetterReplay(error: error, attempt: nextAttempt) {
                let reason = Self.failureReason(error: error)
                await store.markDeadLetter(
                    queueID: entry.receipt.queueID,
                    reason: reason,
                    now: Date()
                )
                await emitOfflineQueueEvent(
                    .deadLettered(
                        queueID: entry.receipt.queueID,
                        requestKey: entry.receipt.requestKey,
                        reason: reason
                    ),
                    telemetry: telemetryOfflineQueueContext(
                        type: .deadLettered,
                        queueID: entry.receipt.queueID,
                        requestKey: entry.receipt.requestKey,
                        attempt: nextAttempt,
                        enqueuedAt: entry.receipt.enqueuedAt,
                        reason: reason,
                        willRetry: false
                    )
                )
                return
            }

            let delaySeconds = min(pow(2, Double(nextAttempt)), 60)
            let nextRetryAt = Date().addingTimeInterval(delaySeconds)
            let reason = Self.failureReason(error: error)
            await store.markRetryWaiting(
                queueID: entry.receipt.queueID,
                attempt: nextAttempt,
                reason: reason,
                nextRetryAt: nextRetryAt,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .replayFailed(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    reason: reason,
                    willRetry: true
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replayFailed,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: reason,
                    willRetry: true
                )
            )
        } catch {
            let fallback = NetworkError.transport(underlying: error)
            let delaySeconds = min(pow(2, Double(nextAttempt)), 60)
            let nextRetryAt = Date().addingTimeInterval(delaySeconds)
            let reason = Self.failureReason(error: fallback)
            await store.markRetryWaiting(
                queueID: entry.receipt.queueID,
                attempt: nextAttempt,
                reason: reason,
                nextRetryAt: nextRetryAt,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .replayFailed(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    reason: reason,
                    willRetry: true
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replayFailed,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: reason,
                    willRetry: true
                )
            )
        }
    }

    private func shouldDeadLetterReplay(error: NetworkError, attempt: Int) -> Bool {
        if attempt >= 5 {
            return true
        }
        guard case .httpStatus(let code, _, _) = error else {
            return false
        }
        if code == 408 || code == 409 || code == 429 {
            return false
        }
        return (400...499).contains(code)
    }

    private func emitOfflineQueueEvent(_ event: OfflineQueueEvent, telemetry: TelemetryOfflineQueueContext? = nil) async {
        await offlineQueueEventHub.emit(event)
        if let telemetry {
            telemetryHooks?.onOfflineQueueEvent?(telemetry)
        }
    }

    private func telemetryOfflineQueueContext(
        type: TelemetryOfflineQueueEventType,
        queueID: String,
        requestKey: String,
        attempt: Int? = nil,
        enqueuedAt: Date? = nil,
        reason: String? = nil,
        willRetry: Bool? = nil
    ) -> TelemetryOfflineQueueContext {
        let ageMilliseconds: Double?
        if let enqueuedAt {
            ageMilliseconds = max(0, Date().timeIntervalSince(enqueuedAt)) * 1_000
        } else {
            ageMilliseconds = nil
        }
        return TelemetryOfflineQueueContext(
            type: type,
            queueID: queueID,
            requestKey: requestKey,
            attempt: attempt,
            ageMilliseconds: ageMilliseconds,
            reason: reason,
            willRetry: willRetry
        )
    }

    private static func isQueueEligibleWriteMethod(_ method: URLMethod) -> Bool {
        switch method {
        case .post, .put, .patch:
            return true
        default:
            return false
        }
    }

    private static func isOfflineError(_ error: NetworkError) -> Bool {
        guard case .transport(let underlying as URLError) = error else {
            return false
        }
        switch underlying.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    private func shouldStoreInCache(_ headers: [String: String]) -> Bool {
        let directives = cacheDirectives(from: headers)
        return !directives.contains("no-store")
    }

    private func varyHeaders(from responseHeaders: [String: String], requestHeaders: [String: String]) -> [String: String] {
        guard let rawVary = headerValue("Vary", in: responseHeaders) else { return [:] }
        let names = rawVary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "*" }
        guard !names.isEmpty else { return [:] }

        var captured: [String: String] = [:]
        for name in names {
            let value = requestHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
            captured[name.lowercased()] = value
        }
        return captured
    }

    private func varyMatches(cached: CachedResponse, request: APIRequest) -> Bool {
        guard !cached.varyRequestHeaders.isEmpty else { return true }
        for (name, expectedValue) in cached.varyRequestHeaders {
            let actual = request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
            if actual != expectedValue {
                return false
            }
        }
        return true
    }

    private func effectiveMaxAge(clientMaxAge: TimeInterval, cached: CachedResponse) -> TimeInterval {
        var value = max(0, clientMaxAge)
        if let serverMax = cacheControlMaxAge(headers: cached.headers) {
            value = min(value, serverMax)
        }
        return value
    }

    private func effectiveStaleAges(
        clientMaxAge: TimeInterval,
        clientStaleAge: TimeInterval,
        cached: CachedResponse
    ) -> (maxAge: TimeInterval, staleAge: TimeInterval) {
        let maxAge = effectiveMaxAge(clientMaxAge: clientMaxAge, cached: cached)
        var staleAge = max(maxAge, clientStaleAge)
        if let swr = cacheControlStaleWhileRevalidate(headers: cached.headers) {
            staleAge = min(staleAge, maxAge + swr)
        }
        return (maxAge, staleAge)
    }

    private func isFreshByExpiresHeader(cached: CachedResponse) -> Bool {
        guard let expires = cacheControlExpires(headers: cached.headers) else { return false }
        return Date() <= expires
    }

    private func cacheControlMaxAge(headers: [String: String]) -> TimeInterval? {
        for directive in cacheDirectives(from: headers) {
            if directive.hasPrefix("max-age=") {
                let raw = directive.replacingOccurrences(of: "max-age=", with: "")
                if let value = TimeInterval(raw) {
                    return max(0, value)
                }
            }
        }
        return nil
    }

    private func cacheControlStaleWhileRevalidate(headers: [String: String]) -> TimeInterval? {
        for directive in cacheDirectives(from: headers) {
            if directive.hasPrefix("stale-while-revalidate=") {
                let raw = directive.replacingOccurrences(of: "stale-while-revalidate=", with: "")
                if let value = TimeInterval(raw) {
                    return max(0, value)
                }
            }
        }
        return nil
    }

    private func cacheControlExpires(headers: [String: String]) -> Date? {
        guard let expires = headerValue("Expires", in: headers) else { return nil }
        return DateFormatter.rfc1123.date(from: expires)
    }

    private func cacheDirectives(from headers: [String: String]) -> Set<String> {
        guard let cacheControl = headerValue("Cache-Control", in: headers) else { return [] }
        return Set(
            cacheControl
                .lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func emit(_ event: NetworkClientEvent) {
        networkObserver?(event)
        Task { await eventHub.emit(event) }
    }
}

private extension NetworkClient {
    static func applyBeforeSendMiddlewares(
        middlewares: [NetworkMiddleware],
        request: APIRequest,
        authScope: String?
    ) async throws -> APIRequest {
        var current = request
        for middleware in middlewares {
            if let beforeSend = middleware.beforeSend {
                current = try await beforeSend(current, authScope)
            }
        }
        return current
    }

    static func applyAfterResponseMiddlewares(
        middlewares: [NetworkMiddleware],
        request: APIRequest,
        authScope: String?,
        response: NetworkResponse
    ) async throws -> NetworkResponse {
        var current = response
        for middleware in middlewares {
            if let afterResponse = middleware.afterResponse {
                current = try await afterResponse(request, authScope, current)
            }
        }
        return current
    }
}

private extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

private extension UInt64 {
    func saturatingAdd(_ rhs: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}
