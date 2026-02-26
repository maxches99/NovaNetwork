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

public final class NetworkClient: @unchecked Sendable {
    private let coalescer: RequestCoalescer<NetworkResponse, NetworkError>
    private let transport: any NetworkTransport
    private let fingerprintPolicy: FingerprintPolicy
    private let retryPolicy: RetryPolicy
    private let retryClock: any RetryClock
    private let retryRandomGenerator: any RetryRandomGenerator
    private let defaultCachePolicy: CachePolicy
    private let cache: any ResponseCache
    private let decoder: JSONDecoder
    private let networkObserver: (@Sendable (NetworkClientEvent) -> Void)?
    private let eventHub = NetworkClientEventHub()
    private let circuitBreakerStore = CircuitBreakerStore()

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
        observer: RequestCoalescer<NetworkResponse, NetworkError>.Observer? = nil,
        networkObserver: (@Sendable (NetworkClientEvent) -> Void)? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.transport = transport
        self.coalescer = RequestCoalescer(policy: cancellationPolicy, limits: coalescerLimits, observer: observer)
        self.fingerprintPolicy = fingerprintPolicy
        self.retryPolicy = retryPolicy
        self.retryClock = retryClock
        self.retryRandomGenerator = retryRandomGenerator
        self.defaultCachePolicy = defaultCachePolicy.normalized
        self.cache = cache ?? MemoryResponseCache(maxEntries: cacheMaxEntries)
        self.decoder = decoder
        self.networkObserver = networkObserver
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
                key: key,
                storeInCache: false,
                cachedETag: nil,
                options: options
            )
        case .cacheFirst(let maxAge):
            if let cached = await cache.entry(forKey: key) {
                let age = ageSeconds(since: cached.storedAtNanoseconds)
                if age <= maxAge {
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
                key: key,
                storeInCache: true,
                cachedETag: nil,
                options: options
            )
        case .staleWhileRevalidate(let maxAge, let staleAge):
            if let cached = await cache.entry(forKey: key) {
                let age = ageSeconds(since: cached.storedAtNanoseconds)
                if age <= maxAge {
                    emit(.cacheHit(
                        key: key,
                        isStale: false,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))
                    return cached.body
                }

                if age <= staleAge {
                    emit(.cacheHit(
                        key: key,
                        isStale: true,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))

                    Task {
                        _ = try? await self.fetchNetworkAndOptionallyStore(
                            request: request,
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

    public func loadBatch(
        requests: [APIRequest],
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> [Data] {
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let data = try await self.load(
                        request: request,
                        authScope: authScope,
                        cachePolicy: cachePolicy,
                        options: options
                    )
                    return (index, data)
                }
            }

            var orderedResults = Array(repeating: Data(), count: requests.count)
            for try await (index, data) in group {
                orderedResults[index] = data
            }
            return orderedResults
        }
    }

    public func coalescerMetrics() async -> RequestCoalescer<NetworkResponse, NetworkError>.Metrics {
        await coalescer.snapshotMetrics()
    }

    public func preload(
        request: APIRequest,
        authScope: String?,
        options: RequestExecutionOptions = .init()
    ) async throws {
        let key = makeFingerprint(for: request, authScope: authScope).key
        _ = try await fetchNetworkAndOptionallyStore(
            request: request,
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
        key: String,
        storeInCache: Bool,
        cachedETag: String?,
        options: RequestExecutionOptions
    ) async throws -> Data {
        if let breakerPolicy = options.circuitBreakerPolicy {
            let identifier = circuitBreakerIdentifier(for: request, key: key, policy: breakerPolicy)
            let canExecute = await circuitBreakerStore.canExecute(identifier: identifier)
            if !canExecute {
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

        let outcome: NetworkResponse
        do {
            outcome = try await coalescer.run(
                key: key,
                options: coalescerRunOptions(from: options)
            ) {
                await Self.executeWithRetry(
                    key: key,
                    request: conditionalRequest,
                    transport: self.transport,
                    retryPolicy: self.retryPolicy,
                    retryClock: self.retryClock,
                    retryRandomGenerator: self.retryRandomGenerator,
                    observer: self.networkObserver
                )
            }
        } catch {
            if let breakerPolicy = options.circuitBreakerPolicy,
               let networkError = error as? NetworkError,
               shouldCountFailureForCircuitBreaker(networkError) {
                let identifier = circuitBreakerIdentifier(for: request, key: key, policy: breakerPolicy)
                await circuitBreakerStore.recordFailure(identifier: identifier, policy: breakerPolicy)
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
                    storedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                )
                await cache.set(revalidated, forKey: key)
            }
            emit(.cacheRevalidated(key: key, ageMilliseconds: 0))
            return cached.body
        }

        if storeInCache {
            let cached = CachedResponse(
                body: outcome.body,
                statusCode: outcome.statusCode,
                headers: outcome.headers,
                etag: outcome.headerValue(for: "ETag"),
                storedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
            await cache.set(cached, forKey: key)
        }

        if let breakerPolicy = options.circuitBreakerPolicy {
            let identifier = circuitBreakerIdentifier(for: request, key: key, policy: breakerPolicy)
            await circuitBreakerStore.recordSuccess(identifier: identifier)
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
        transport: any NetworkTransport,
        retryPolicy: RetryPolicy,
        retryClock: any RetryClock,
        retryRandomGenerator: any RetryRandomGenerator,
        observer: (@Sendable (NetworkClientEvent) -> Void)?
    ) async -> Result<NetworkResponse, NetworkError> {
        var attempt = 1

        while true {
            observer?(.requestAttempt(key: key, attempt: attempt))

            do {
                let response = try await transport.execute(request)
                observer?(.requestSucceeded(key: key, attempts: attempt))
                return .success(response)
            } catch is CancellationError {
                observer?(.requestFailed(key: key, attempts: attempt, reason: "cancelled"))
                return .failure(.cancelled)
            } catch let error as NetworkError {
                if attempt >= retryPolicy.maxAttempts || !retryPolicy.shouldRetry(error: error) {
                    observer?(.requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: failureReason(error: error)
                    ))
                    return .failure(error)
                }

                let delay = retryPolicy.delayNanoseconds(
                    forAttempt: attempt,
                    random: retryRandomGenerator
                )
                observer?(
                    .retryScheduled(
                        key: key,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(delay) / 1_000_000,
                        reason: failureReason(error: error)
                    )
                )
                do {
                    try await retryClock.sleep(nanoseconds: delay)
                } catch {
                    observer?(.requestFailed(key: key, attempts: attempt, reason: "cancelled"))
                    return .failure(.cancelled)
                }

                attempt += 1
                continue
            } catch {
                let wrapped = NetworkError.transport(underlying: error)
                if attempt >= retryPolicy.maxAttempts || !retryPolicy.shouldRetry(error: wrapped) {
                    observer?(.requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: failureReason(error: wrapped)
                    ))
                    return .failure(wrapped)
                }

                let delay = retryPolicy.delayNanoseconds(
                    forAttempt: attempt,
                    random: retryRandomGenerator
                )
                observer?(
                    .retryScheduled(
                        key: key,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(delay) / 1_000_000,
                        reason: failureReason(error: wrapped)
                    )
                )
                do {
                    try await retryClock.sleep(nanoseconds: delay)
                } catch {
                    observer?(.requestFailed(key: key, attempts: attempt, reason: "cancelled"))
                    return .failure(.cancelled)
                }

                attempt += 1
                continue
            }
        }
    }

    private static func failureReason(error: NetworkError) -> String {
        switch error {
        case .invalidResponse:
            return "invalidResponse"
        case .httpStatus(let code, _):
            return "httpStatus:\(code)"
        case .decoding:
            return "decoding"
        case .transport(let underlying as URLError):
            return "transport:\(underlying.code.rawValue)"
        case .transport:
            return "transport"
        case .cancelled:
            return "cancelled"
        case .circuitBreakerOpen:
            return "circuitBreakerOpen"
        }
    }

    private func emit(_ event: NetworkClientEvent) {
        networkObserver?(event)
        Task { await eventHub.emit(event) }
    }
}
