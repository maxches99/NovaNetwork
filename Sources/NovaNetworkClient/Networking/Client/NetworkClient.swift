import NovaNetworkCore
import Foundation

/// A concurrency-safe HTTP client with coalescing, resilience, caching, transfers, and telemetry.
public final class NetworkClient: Sendable {
    private let coalescer: RequestCoalescer<NetworkResponse, NetworkError>
    let transport: any NetworkTransport
    private let fingerprintPolicy: FingerprintPolicy
    private let retryPolicy: RetryPolicy
    private let retryClock: any RetryClock
    private let retryRandomGenerator: any RetryRandomGenerator
    private let defaultCachePolicy: CachePolicy
    private let cache: any ResponseCache
    private let offlineWriteStore: (any OfflineWriteStore)?
    private let offlineConnectivityMonitor: (any OfflineConnectivityMonitor)?
    let offlineConflictResolver: (@Sendable (OfflineQueueConflictMetadata) -> OfflineConflictResolutionDecision)?
    let decoder: JSONDecoder
    let responseDecoding: (any ResponseDecoding)?
    private let networkObserver: (@Sendable (NetworkClientEvent) -> Void)?
    private let middlewares: [NetworkMiddleware]
    let telemetryHooks: NetworkTelemetryHooks?
    let httpExecutionPipeline: any NetworkClientHTTPExecutionPipeline
    let offlineReplayCoordinator: any NetworkClientOfflineReplayCoordinating
    let httpAuthRefreshProvider: HTTPAuthRefreshProvider?
    let httpAuthRefreshPolicy: HTTPAuthRefreshPolicy
    let httpAuthRefreshCoordinator: HTTPAuthRefreshCoordinator
    private let eventHub = NetworkClientEventHub()
    let offlineQueueEventHub = OfflineQueueEventHub()
    private let circuitBreakerStore = CircuitBreakerStore()
    private let rateLimiter = KeyRateLimiter()
    let configuredNetworkPathPolicy: NetworkPathPolicy?
    let configuredNetworkPathMonitor: (any NetworkPathMonitor)?
    /// `nil` unless `configuration.adaptiveConcurrency` asked for one, in which case every request
    /// that reaches the transport takes a slot from it.
    let adaptiveConcurrencyLimiter: AdaptiveConcurrencyLimiter?
    private let runtimePolicyStore = RuntimePolicyStore()
    private let lifetime = NetworkClientLifetime()

    struct RequestDeadline: Sendable {
        let deadlineNanoseconds: UInt64
    }

    /// Creates a configured network client.
    ///
    /// Authentication refresh is disabled unless `httpAuthRefreshProvider` is supplied.
    /// All other arguments preserve the raw request API's existing defaults. Equivalent to
    /// building a ``NetworkClientConfiguration`` with the same arguments and calling
    /// ``init(configuration:)``; prefer that initializer when configuring many options at once.
    public convenience init(
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
        offlineConflictResolver: (@Sendable (OfflineQueueConflictMetadata) -> OfflineConflictResolutionDecision)? = nil,
        observer: RequestCoalescer<NetworkResponse, NetworkError>.Observer? = nil,
        networkObserver: (@Sendable (NetworkClientEvent) -> Void)? = nil,
        middlewares: [NetworkMiddleware] = [],
        telemetryHooks: NetworkTelemetryHooks? = nil,
        httpAuthRefreshProvider: HTTPAuthRefreshProvider? = nil,
        httpAuthRefreshPolicy: HTTPAuthRefreshPolicy = .default,
        decoder: JSONDecoder = JSONDecoder(),
        responseDecoding: (any ResponseDecoding)? = nil
    ) {
        self.init(
            configuration: NetworkClientConfiguration(
                transport: transport,
                cancellationPolicy: cancellationPolicy,
                coalescerLimits: coalescerLimits,
                fingerprintPolicy: fingerprintPolicy,
                retryPolicy: retryPolicy,
                retryClock: retryClock,
                retryRandomGenerator: retryRandomGenerator,
                defaultCachePolicy: defaultCachePolicy,
                cacheMaxEntries: cacheMaxEntries,
                cache: cache,
                offlineWriteStore: offlineWriteStore,
                offlineConnectivityMonitor: offlineConnectivityMonitor,
                offlineConflictResolver: offlineConflictResolver,
                observer: observer,
                networkObserver: networkObserver,
                middlewares: middlewares,
                telemetryHooks: telemetryHooks,
                httpAuthRefreshProvider: httpAuthRefreshProvider,
                httpAuthRefreshPolicy: httpAuthRefreshPolicy,
                decoder: decoder,
                responseDecoding: responseDecoding
            )
        )
    }

    /// Creates a configured network client from a ``NetworkClientConfiguration``.
    ///
    /// Authentication refresh is disabled unless `configuration.httpAuthRefreshProvider` is
    /// supplied. All other fields preserve the raw request API's existing defaults.
    public init(configuration: NetworkClientConfiguration) {
        let transport = configuration.transport
        let telemetryHooks = configuration.telemetryHooks
        let networkObserver = configuration.networkObserver
        let observer = configuration.observer
        let retryPolicy = configuration.retryPolicy
        let retryClock = configuration.retryClock
        let retryRandomGenerator = configuration.retryRandomGenerator
        let middlewares = configuration.middlewares
        let offlineConnectivityMonitor = configuration.offlineConnectivityMonitor

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
            policy: configuration.cancellationPolicy,
            limits: configuration.coalescerLimits,
            observer: combinedObserver,
            queueMetricsObserver: queueMetricsObserver,
            overflowFailureFactory: { NetworkError.coalescerLimitExceeded }
        )
        self.fingerprintPolicy = configuration.fingerprintPolicy
        self.retryPolicy = retryPolicy
        self.retryClock = retryClock
        self.retryRandomGenerator = retryRandomGenerator
        self.defaultCachePolicy = configuration.defaultCachePolicy.normalized
        self.cache = configuration.cache ?? MemoryResponseCache(maxEntries: configuration.cacheMaxEntries)
        self.offlineWriteStore = configuration.offlineWriteStore
        self.offlineConnectivityMonitor = offlineConnectivityMonitor
        self.offlineConflictResolver = configuration.offlineConflictResolver
        self.decoder = configuration.decoder
        self.responseDecoding = configuration.responseDecoding
        self.networkObserver = networkObserver
        self.middlewares = middlewares
        self.telemetryHooks = telemetryHooks
        self.httpAuthRefreshProvider = configuration.httpAuthRefreshProvider
        self.httpAuthRefreshPolicy = configuration.httpAuthRefreshPolicy
        self.httpAuthRefreshCoordinator = HTTPAuthRefreshCoordinator(
            telemetry: telemetryHooks?.onHTTPAuthRefresh
        )
        self.configuredNetworkPathPolicy = configuration.networkPathPolicy
        self.configuredNetworkPathMonitor = configuration.networkPathMonitor
        self.adaptiveConcurrencyLimiter = configuration.adaptiveConcurrency.map { policy in
            AdaptiveConcurrencyLimiter(policy: policy) { change in
                telemetryHooks?.onConcurrencyLimitChanged?(
                    TelemetryConcurrencyLimitContext(
                        previousLimit: change.from,
                        limit: change.to,
                        reason: change.reason.rawValue
                    )
                )
            }
        }
        self.httpExecutionPipeline = DefaultNetworkClientHTTPExecutionPipeline(
            transport: transport,
            retryPolicy: retryPolicy,
            retryClock: retryClock,
            retryRandomGenerator: retryRandomGenerator,
            middlewares: middlewares,
            telemetryHooks: telemetryHooks,
            observer: networkObserver,
            executor: Self.executeWithRetry
        )
        self.offlineReplayCoordinator = DefaultNetworkClientOfflineReplayCoordinator()

        if let offlineConnectivityMonitor {
            Task { [lifetime, weak self] in
                await lifetime.startConnectivityListener(monitor: offlineConnectivityMonitor) { [weak self] in
                    guard let self else { return }
                    _ = await self.flushOfflineQueue()
                }
            }
        }
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
        let changedFields = (await runtimePolicyStore.update(policy: policy, scope: scope)).sorted()
        let scopeName = runtimePolicyScopeName(scope)
        emit(.requestPolicyUpdated(scope: scopeName, changedFields: changedFields))
        telemetryHooks?.onPolicyUpdated?(
            TelemetryPolicyUpdateContext(
                source: RuntimePolicySource.runtimeUpdate.rawValue,
                scope: scopeName,
                changedFields: changedFields,
                effectiveValues: runtimePolicyEffectiveValues(policy: policy)
            )
        )
    }

    public func updateCircuitBreakerRuntimePolicy(
        _ policy: CircuitBreakerPolicy?,
        scope: RuntimePolicyScope = .global
    ) async {
        await updateRuntimePolicy(.init(circuitBreakerPolicy: policy), scope: scope)
    }

    public func updateCoalescerSchedulerPolicy(
        _ policy: RequestCoalescer<NetworkResponse, NetworkError>.FairnessPolicy
    ) async {
        await coalescer.updateFairnessPolicy(policy)
        let changedFields = ["high_weight", "medium_weight", "low_weight"]
        emit(.requestPolicyUpdated(scope: "coalescer_scheduler", changedFields: changedFields))
        telemetryHooks?.onPolicyUpdated?(
            TelemetryPolicyUpdateContext(
                source: RuntimePolicySource.runtimeUpdate.rawValue,
                scope: "coalescer_scheduler",
                changedFields: changedFields,
                effectiveValues: [
                    "high_weight=\(policy.highWeight)",
                    "medium_weight=\(policy.mediumWeight)",
                    "low_weight=\(policy.lowWeight)"
                ]
            )
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
        let cachesUnsafeMethods = resolvedPolicy.includesUnsafeMethods
        let forceRevalidation = requestRequiresRevalidation(request)

        if !requestAllowsCacheLookup(request, includingUnsafeMethods: cachesUnsafeMethods) {
            emit(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(
                request: request,
                authScope: authScope,
                key: key,
                storeInCache: false,
                cachedETag: nil,
                options: options
            ).body
        }

        switch resolvedPolicy.freshness {
        case .networkOnly:
            emit(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(
                request: request,
                authScope: authScope,
                key: key,
                storeInCache: false,
                cachedETag: nil,
                options: options
            ).body
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
                        cachesUnsafeMethods: cachesUnsafeMethods,
                        options: options
                    ).body
                }

                let age = correctedAgeSeconds(cached: cached)
                let effectiveMaxAge = effectiveMaxAge(clientMaxAge: maxAge, cached: cached)
                if !forceRevalidation && (age <= effectiveMaxAge || isFreshByExpiresHeader(cached: cached)) {
                    emit(.cacheHit(
                        key: key,
                        isStale: false,
                        ageMilliseconds: age * 1_000
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
                        cachedLastModified: cached.lastModified,
                        cachesUnsafeMethods: cachesUnsafeMethods,
                        options: options
                    ).body
                } catch let error as NetworkError where canServeStaleIfError(
                    cached: cached,
                    clientMaxAge: maxAge,
                    error: error
                ) {
                    emit(
                        .cacheStaleIfError(
                            key: key,
                            ageMilliseconds: age * 1_000,
                            reason: Self.failureReason(error: error)
                        )
                    )
                    return cached.body
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
                cachesUnsafeMethods: cachesUnsafeMethods,
                options: options
            ).body
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
                        cachesUnsafeMethods: cachesUnsafeMethods,
                        options: options
                    ).body
                }

                let age = correctedAgeSeconds(cached: cached)
                let freshness = effectiveStaleAges(clientMaxAge: maxAge, clientStaleAge: staleAge, cached: cached)
                if !forceRevalidation && (age <= freshness.maxAge || isFreshByExpiresHeader(cached: cached)) {
                    emit(.cacheHit(
                        key: key,
                        isStale: false,
                        ageMilliseconds: age * 1_000
                    ))
                    return cached.body
                }

                if !forceRevalidation && age <= freshness.staleAge {
                    emit(.cacheHit(
                        key: key,
                        isStale: true,
                        ageMilliseconds: age * 1_000
                    ))

                    Task {
                        _ = try? await self.fetchNetworkAndOptionallyStore(
                            request: request,
                            authScope: authScope,
                            key: key,
                            storeInCache: true,
                            cachedETag: cached.etag,
                            cachedLastModified: cached.lastModified,
                            cachesUnsafeMethods: cachesUnsafeMethods,
                            options: options
                        )
                    }
                    return cached.body
                }

                do {
                    return try await fetchNetworkAndOptionallyStore(
                        request: request,
                        authScope: authScope,
                        key: key,
                        storeInCache: true,
                        cachedETag: cached.etag,
                        cachedLastModified: cached.lastModified,
                        cachesUnsafeMethods: cachesUnsafeMethods,
                        options: options
                    ).body
                } catch let error as NetworkError where canServeStaleIfError(
                    cached: cached,
                    clientMaxAge: maxAge,
                    error: error
                ) {
                    emit(
                        .cacheStaleIfError(
                            key: key,
                            ageMilliseconds: age * 1_000,
                            reason: Self.failureReason(error: error)
                        )
                    )
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
                cachesUnsafeMethods: cachesUnsafeMethods,
                options: options
            ).body
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
            return try await enqueuePreparedWrite(
                request: queuePreparedRequest,
                requestKey: key,
                authScope: authScope,
                queuePolicy: queuePolicy
            )
        }

        do {
            let data = try await fetchNetworkAndOptionallyStore(
                request: queuePreparedRequest,
                authScope: authScope,
                key: key,
                storeInCache: false,
                cachedETag: nil,
                options: options
            ).body
            return .completed(data)
        } catch let error as NetworkError {
            guard queuePolicy.mode == .enqueueWhenOffline, isQueueEligibleMethod, Self.isOfflineError(error) else {
                throw error
            }
            return try await enqueuePreparedWrite(
                request: queuePreparedRequest,
                requestKey: key,
                authScope: authScope,
                queuePolicy: queuePolicy
            )
        }
    }

    @discardableResult
    public func flushOfflineQueue(limit: Int = 64) async -> Int {
        guard let offlineWriteStore else { return 0 }
        guard limit > 0 else { return 0 }
        guard await offlineReplayCoordinator.beginFlush() else { return 0 }
        defer {
            Task { await offlineReplayCoordinator.endFlush() }
        }

        var replayedCount = 0
        _ = await offlineWriteStore.snapshot(now: Date())
        let flushStartedAt = Date()
        if let report = await offlineWriteStore.consumeRecoveryReport(), report.skippedTotal > 0 {
            await emitOfflineQueueEvent(
                .recoveryLossDetected(
                    scannedRecords: report.scannedRecords,
                    skippedRecords: report.skippedTotal,
                    reason: "partial_store_corruption_or_incompatible_versions"
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .recoveryLossDetected,
                    queueID: "offline-store",
                    requestKey: "offline-store",
                    reason: "scanned=\(report.scannedRecords)",
                    resultType: "recovery_loss_detected",
                    skippedRecords: report.skippedTotal
                )
            )
        }

        while replayedCount < limit && Date().timeIntervalSince(flushStartedAt) < 300 {
            let remaining = max(1, limit - replayedCount)
            let allEntries = await offlineWriteStore.snapshot(now: Date())
            let candidates = await offlineReplayCoordinator.readyForReplay(entries: allEntries, now: Date())
            guard !candidates.isEmpty else { break }
            let policy = effectiveSchedulerPolicy(from: candidates)
            let scheduled = await offlineReplayCoordinator.scheduleReplayBatch(
                entries: candidates,
                limit: remaining,
                policy: policy,
                now: Date()
            )

            guard !scheduled.isEmpty else { break }
            for entry in scheduled {
                if replayedCount >= limit {
                    break
                }
                await replayOfflineEntry(entry, store: offlineWriteStore)
                replayedCount += 1
            }

            let elapsed = Date().timeIntervalSince(flushStartedAt)
            let minimumWindow = max(1, TimeInterval(replayedCount) / policy.replayWindow.maxReplaysPerSecond)
            if elapsed < minimumWindow {
                let sleepNs = UInt64((minimumWindow - elapsed) * 1_000_000_000)
                if sleepNs > 0 {
                    try? await Task.sleep(nanoseconds: sleepNs)
                }
            }
            if Date().timeIntervalSince(flushStartedAt) >= policy.replayWindow.maxContinuousReplaySeconds {
                let coolDownNs = UInt64(policy.replayWindow.coolDownSeconds * 1_000_000_000)
                if coolDownNs > 0 {
                    try? await Task.sleep(nanoseconds: coolDownNs)
                }
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
                    state: entry.state,
                    priority: entry.replayMetadata.priority
                )
            }
            .sorted { lhs, rhs in
                lhs.receipt.position < rhs.receipt.position
            }
    }

    public func offlineQueuePipelineMetrics() async -> OfflineQueuePipelineMetrics {
        guard let offlineWriteStore else {
            return OfflineQueuePipelineMetrics(
                queueDepth: 0,
                ageDistribution: .init(p50Seconds: 0, p90Seconds: 0, p95Seconds: 0, maxSeconds: 0),
                replayThroughput: .init(replayedCount: 0, windowSeconds: 0, replaysPerSecond: 0),
                terminalOutcomes: [:]
            )
        }

        let now = Date()
        let snapshot = await offlineWriteStore.snapshot(now: now)
        let ages = snapshot
            .map { max(0, now.timeIntervalSince($0.receipt.enqueuedAt)) }
            .sorted()
        let ageDistribution = OfflineQueueAgeDistribution(
            p50Seconds: percentile(ages: ages, p: 0.5),
            p90Seconds: percentile(ages: ages, p: 0.9),
            p95Seconds: percentile(ages: ages, p: 0.95),
            maxSeconds: ages.last ?? 0
        )
        let replayState = await offlineReplayCoordinator.snapshotMetrics(now: now)
        let windowSeconds: TimeInterval
        if let startedAt = replayState.startedAt {
            windowSeconds = max(0.001, now.timeIntervalSince(startedAt))
        } else {
            windowSeconds = 0
        }
        let throughput = OfflineQueueReplayThroughput(
            replayedCount: replayState.replayedCount,
            windowSeconds: windowSeconds,
            replaysPerSecond: windowSeconds > 0 ? Double(replayState.replayedCount) / windowSeconds : 0
        )
        return OfflineQueuePipelineMetrics(
            queueDepth: snapshot.count,
            ageDistribution: ageDistribution,
            replayThroughput: throughput,
            terminalOutcomes: replayState.terminalOutcomes
        )
    }

    @discardableResult
    public func replayManualReviewItem(queueID: String, resolutionReason: String? = nil) async -> Bool {
        guard let offlineWriteStore else { return false }
        let snapshot = await offlineWriteStore.snapshot(now: Date())
        guard let item = snapshot.first(where: { $0.receipt.queueID == queueID }) else {
            return false
        }
        let requeued = await offlineWriteStore.requeueManualReview(
            queueID: queueID,
            reason: resolutionReason,
            now: Date()
        )
        if requeued {
            await emitOfflineQueueEvent(
                .manualReviewRequeued(
                    queueID: item.receipt.queueID,
                    requestKey: item.receipt.requestKey,
                    reason: resolutionReason
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replayStarted,
                    queueID: item.receipt.queueID,
                    requestKey: item.receipt.requestKey,
                    attempt: item.attempt,
                    enqueuedAt: item.receipt.enqueuedAt,
                    reason: resolutionReason,
                    resultType: "manual_review_requeued",
                    priority: item.replayMetadata.priority
                )
            )
        }
        return requeued
    }

    public func rotateOfflineQueueEncryption() async -> Int {
        guard let offlineWriteStore else { return 0 }
        return await offlineWriteStore.rotateEncryption(now: Date())
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

    /// Loads response bytes incrementally when the transport supports streaming.
    ///
    /// The default ``Transport`` emits bounded 64 KiB chunks on supported operating systems.
    /// A non-streaming transport falls back to one complete response chunk. Cancelling or
    /// terminating iteration cancels the consumer task and underlying stream.
    public func loadStream(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init()
    ) -> AsyncThrowingStream<Data, Error> {
        let key = makeFingerprint(for: request, authScope: authScope).key
        if let streamingTransport = transport as? any StreamingNetworkTransport {
            return AsyncThrowingStream { continuation in
                telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .started, key: key))
                let consumer = Task {
                    do {
                        let prepared = try await prepareRequestForExecution(
                            request: request,
                            key: key,
                            options: options
                        )
                        let stream = streamingTransport.stream(prepared, authScope: authScope)
                        for try await chunk in stream {
                            telemetryHooks?.onTransferEvent?(
                                .init(
                                    kind: .stream,
                                    phase: .progress,
                                    key: key,
                                    completedBytes: Int64(chunk.count)
                                )
                            )
                            continuation.yield(chunk)
                        }
                        telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .completed, key: key))
                        continuation.finish()
                    } catch {
                        let cancelled = error is CancellationError || Task.isCancelled
                        telemetryHooks?.onTransferEvent?(
                            .init(
                                kind: .stream,
                                phase: cancelled ? .cancelled : .failed,
                                key: key,
                                reason: String(describing: type(of: error))
                            )
                        )
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in consumer.cancel() }
            }
        }

        return AsyncThrowingStream { continuation in
            telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .started, key: key))
            let consumer = Task {
                do {
                    let data = try await self.load(
                        request: request,
                        authScope: authScope,
                        cachePolicy: cachePolicy,
                        options: options
                    )
                    telemetryHooks?.onTransferEvent?(
                        .init(
                            kind: .stream,
                            phase: .progress,
                            key: key,
                            completedBytes: Int64(data.count),
                            totalBytes: Int64(data.count)
                        )
                    )
                    continuation.yield(data)
                    telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .completed, key: key))
                    continuation.finish()
                } catch {
                    let cancelled = error is CancellationError || Task.isCancelled
                    telemetryHooks?.onTransferEvent?(
                        .init(
                            kind: .stream,
                            phase: cancelled ? .cancelled : .failed,
                            key: key,
                            reason: String(describing: type(of: error))
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in consumer.cancel() }
        }
    }

    /// Connects to a `text/event-stream` endpoint and yields parsed Server-Sent Events.
    ///
    /// Requires a transport that implements `ServerSentEventTransport` (the default
    /// ``Transport`` does); other transports fail immediately with
    /// ``ServerSentEventError/transportUnsupported``. By default the stream reconnects
    /// automatically after the connection ends or fails, replaying a `Last-Event-ID` header
    /// once the server has sent one and honoring any `retry:` field the server sends. Pass
    /// ``SSEReconnectPolicy/disabled`` for a single-attempt stream instead. Cancelling or
    /// terminating iteration cancels the underlying connection.
    public func loadServerSentEvents(
        request: APIRequest,
        authScope: String?,
        options: RequestExecutionOptions = .init(),
        reconnectPolicy: SSEReconnectPolicy = .init()
    ) -> AsyncThrowingStream<ServerSentEvent, Error> {
        let key = makeFingerprint(for: request, authScope: authScope).key
        guard let sseTransport = transport as? any ServerSentEventTransport else {
            return AsyncThrowingStream { continuation in
                continuation.finish(
                    throwing: NetworkError.transport(underlying: ServerSentEventError.transportUnsupported)
                )
            }
        }

        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let consumer = Task {
                var lastEventID: String?
                var reconnectDelayNanoseconds = reconnectPolicy.defaultDelayNanoseconds
                var attempt = 0
                telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .started, key: key))

                while true {
                    do {
                        try Task.checkCancellation()
                        var effectiveRequest = request
                        if let lastEventID {
                            effectiveRequest = effectiveRequest.withMergedHeaders(["Last-Event-ID": lastEventID])
                        }
                        let prepared = try await prepareRequestForExecution(
                            request: effectiveRequest,
                            key: key,
                            options: options
                        )
                        for try await element in sseTransport.serverSentEventElements(prepared, authScope: authScope) {
                            try Task.checkCancellation()
                            switch element {
                            case .event(let event):
                                if let id = event.id {
                                    lastEventID = id
                                }
                                attempt = 0
                                telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .progress, key: key))
                                continuation.yield(event)
                            case .retryIntervalUpdate(let milliseconds):
                                let requested = UInt64(clamping: milliseconds) * 1_000_000
                                reconnectDelayNanoseconds = min(requested, reconnectPolicy.maxDelayNanoseconds)
                            }
                        }
                        guard reconnectPolicy.isEnabled else {
                            telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .completed, key: key))
                            continuation.finish()
                            return
                        }
                    } catch is CancellationError {
                        telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .cancelled, key: key))
                        continuation.finish(throwing: NetworkError.cancelled)
                        return
                    } catch {
                        guard reconnectPolicy.isEnabled else {
                            telemetryHooks?.onTransferEvent?(
                                .init(kind: .stream, phase: .failed, key: key, reason: String(describing: type(of: error)))
                            )
                            continuation.finish(throwing: error)
                            return
                        }
                    }

                    attempt += 1
                    if let maxAttempts = reconnectPolicy.maxAttempts, attempt > maxAttempts {
                        telemetryHooks?.onTransferEvent?(
                            .init(kind: .stream, phase: .failed, key: key, reason: "sse_reconnect_attempts_exhausted")
                        )
                        continuation.finish(
                            throwing: NetworkError.transport(underlying: ServerSentEventError.reconnectAttemptsExhausted)
                        )
                        return
                    }
                    do {
                        try await retryClock.sleep(nanoseconds: reconnectDelayNanoseconds)
                    } catch {
                        telemetryHooks?.onTransferEvent?(.init(kind: .stream, phase: .cancelled, key: key))
                        continuation.finish(throwing: NetworkError.cancelled)
                        return
                    }
                }
            }
            continuation.onTermination = { _ in consumer.cancel() }
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

    func makeFingerprint(for request: APIRequest, authScope: String?) -> RequestFingerprint {
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

    func fetchNetworkAndOptionallyStore(
        request: APIRequest,
        authScope: String?,
        key: String,
        storeInCache: Bool,
        cachedETag: String?,
        cachedLastModified: String? = nil,
        cachesUnsafeMethods: Bool = false,
        options: RequestExecutionOptions
    ) async throws -> NetworkResponse {
        let resolvedRuntimePolicy = await runtimePolicyStore.resolve(url: request.url)
        let hasRequestOverrides = options.deadlineBudgetSeconds != nil || options.circuitBreakerPolicy != nil
        let resolvedRetryPolicy = resolvedRuntimePolicy.policy.retryPolicy ?? retryPolicy
        let resolvedDeadlineBudget = options.deadlineBudgetSeconds ?? resolvedRuntimePolicy.policy.deadlineBudgetSeconds
        let resolvedBreakerPolicy = options.circuitBreakerPolicy ?? resolvedRuntimePolicy.policy.circuitBreakerPolicy
        let policyScope = hasRequestOverrides ? RuntimePolicySource.requestOverride : resolvedRuntimePolicy.source
        let requestDeadline = makeDeadline(from: resolvedDeadlineBudget)
        let telemetryCoalescingMode = telemetryCoalescingMode(for: options.coalescingMode)
        let coalescingTTL = resolvedRuntimePolicy.policy.coalescingPolicy?.dedupeTTLSeconds
        let coalescingKey = resolvedCoalescingKey(
            baseKey: key,
            mode: options.coalescingMode,
            dedupeTTLSeconds: coalescingTTL
        )

        // Before the rate limiter, because the cheapest request is the one that never starts, and
        // because a path the policy has ruled out should not consume a rate-limit token either.
        try await enforceNetworkPathPolicy(isEssential: options.isEssential)

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

        var conditionalHeaders: [String: String] = [:]
        if let etag = cachedETag {
            conditionalHeaders["If-None-Match"] = etag
        }
        if let lastModified = cachedLastModified {
            conditionalHeaders["If-Modified-Since"] = lastModified
        }
        let conditionalRequest = request.withMergedHeaders(conditionalHeaders)
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
                // Inside the coalescer, not around it: the limit bounds requests that reach the
                // transport, and callers that were merged into an existing one never do.
                await self.holdingConcurrencyPermit {
                    await self.executeWithHTTPAuthRefresh(
                        .init(
                            key: key,
                            request: preparedRequest,
                            authScope: authScope,
                            retryPolicy: resolvedRetryPolicy,
                            deadline: requestDeadline,
                            coalescingMode: telemetryCoalescingMode,
                            policyScope: policyScope.rawValue
                        )
                    )
                }
            }
        } catch is CancellationError {
            throw NetworkError.cancelled
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

        let storageAllowed = storeInCache
            && requestAllowsCacheStorage(preparedRequest, includingUnsafeMethods: cachesUnsafeMethods)

        if outcome.statusCode == 304, let cached = await cache.entry(forKey: key) {
            var mergedHeaders = cached.headers
            for (name, value) in outcome.headers {
                mergedHeaders[name] = value
            }
            if storageAllowed {
                let revalidated = CachedResponse(
                    body: cached.body,
                    statusCode: cached.statusCode,
                    headers: mergedHeaders,
                    etag: outcome.headerValue(for: "ETag") ?? cached.etag,
                    lastModified: outcome.headerValue(for: "Last-Modified") ?? cached.lastModified,
                    storedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                    varyRequestHeaders: cached.varyRequestHeaders
                )
                await cache.set(revalidated, forKey: key)
            }
            emit(.cacheRevalidated(key: key, ageMilliseconds: 0))
            return NetworkResponse(statusCode: cached.statusCode, headers: mergedHeaders, body: cached.body)
        }

        if storageAllowed && shouldStoreInCache(outcome.headers) {
            let cached = CachedResponse(
                body: outcome.body,
                statusCode: outcome.statusCode,
                headers: outcome.headers,
                etag: outcome.headerValue(for: "ETag"),
                lastModified: outcome.headerValue(for: "Last-Modified"),
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

        return outcome
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

    private func resolvedCoalescingKey(
        baseKey: String,
        mode: CoalescingMode,
        dedupeTTLSeconds: TimeInterval?
    ) -> String {
        switch mode {
        case .default:
            return applyCoalescingTTL(baseKey: baseKey, dedupeTTLSeconds: dedupeTTLSeconds)
        case .custom(let customKey):
            return applyCoalescingTTL(baseKey: customKey, dedupeTTLSeconds: dedupeTTLSeconds)
        case .disabled:
            return "\(baseKey)#\(UUID().uuidString)"
        }
    }

    private func applyCoalescingTTL(baseKey: String, dedupeTTLSeconds: TimeInterval?) -> String {
        guard let dedupeTTLSeconds else { return baseKey }
        guard dedupeTTLSeconds > 0 else { return "\(baseKey)#\(UUID().uuidString)" }
        let ttlNanoseconds = UInt64(dedupeTTLSeconds * 1_000_000_000)
        guard ttlNanoseconds > 0 else { return "\(baseKey)#\(UUID().uuidString)" }
        let bucket = DispatchTime.now().uptimeNanoseconds / ttlNanoseconds
        return "\(baseKey)#ttl:\(bucket)"
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

    private func runtimePolicyEffectiveValues(policy: NetworkClientRuntimePolicy) -> [String] {
        var values: [String] = []
        if let retryPolicy = policy.retryPolicy {
            values.append("retry_max_attempts=\(retryPolicy.maxAttempts)")
        }
        if let deadlineBudgetSeconds = policy.deadlineBudgetSeconds {
            values.append("deadline_budget_seconds=\(deadlineBudgetSeconds)")
        }
        if let circuitBreakerPolicy = policy.circuitBreakerPolicy {
            values.append("circuit_breaker_failure_threshold=\(circuitBreakerPolicy.failureThreshold)")
            values.append("circuit_breaker_cooldown_seconds=\(circuitBreakerPolicy.cooldownSeconds)")
            values.append("circuit_breaker_probe_policy=\(circuitBreakerPolicy.probePolicy.telemetryName)")
        }
        if let coalescingTTLSeconds = policy.coalescingPolicy?.dedupeTTLSeconds {
            values.append("coalescing_ttl_seconds=\(coalescingTTLSeconds)")
        }
        return values.sorted()
    }

    private func makeDeadline(from budgetSeconds: TimeInterval?) -> RequestDeadline? {
        guard let budgetSeconds else { return nil }
        let budgetNanoseconds = UInt64(budgetSeconds * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadlineNanoseconds, overflow) = now.addingReportingOverflow(budgetNanoseconds)
        return RequestDeadline(deadlineNanoseconds: overflow ? UInt64.max : deadlineNanoseconds)
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

    func prepareRequestForExecution(
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

    private func enqueuePreparedWrite(
        request: APIRequest,
        requestKey: String,
        authScope: String?,
        queuePolicy: OfflineQueuePolicy
    ) async throws -> QueuedWriteResult {
        guard let offlineWriteStore else {
            throw NetworkError.offlineQueueUnavailable
        }
        let replayMetadata = OfflineReplayMetadata(
            replayIdentity: replayIdentity(for: request, requestKey: requestKey, authScope: authScope),
            maxReplayAttempts: queuePolicy.maxReplayAttempts,
            dedupeWindowSeconds: queuePolicy.replayDedupeWindowSeconds,
            conflictPolicy: queuePolicy.replayConflictPolicy,
            priority: queuePolicy.replayPriority,
            schedulerPolicy: queuePolicy.replaySchedulerPolicy
        )
        do {
            let receipt = try await offlineWriteStore.enqueue(
                request: request,
                requestKey: requestKey,
                replayMetadata: replayMetadata,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .enqueued(receipt: receipt),
                telemetry: telemetryOfflineQueueContext(
                    type: .enqueued,
                    queueID: receipt.queueID,
                    requestKey: receipt.requestKey,
                    attempt: 0,
                    enqueuedAt: receipt.enqueuedAt,
                    resultType: nil,
                    priority: replayMetadata.priority
                )
            )
            return .queued(receipt)
        } catch let error as OfflineWriteStoreError {
            switch error {
            case .queueCapacityExceeded(let limit):
                throw NetworkError.queueCapacityExceeded(limit: limit)
            case .encryptionKeyUnavailable, .unsupportedEncryptionVersion, .encryptionFailure:
                throw NetworkError.offlineQueueUnavailable
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

    private func replayIdentity(for request: APIRequest, requestKey: String, authScope: String?) -> String {
        let endpoint = "\(request.url.host ?? "")\(request.url.path)"
        let idempotencyValue = request.headers.first(where: {
            $0.key.caseInsensitiveCompare("idempotency-key") == .orderedSame
        })?.value ?? "none"
        let authHash = SHA256Util.hex(Data((authScope ?? "").utf8))
        let raw = "\(idempotencyValue)|\(endpoint)|\(authHash)|\(requestKey)"
        return SHA256Util.hex(Data(raw.utf8))
    }

    private func emit(_ event: NetworkClientEvent) {
        networkObserver?(event)
        Task { await eventHub.emit(event) }
    }
}
