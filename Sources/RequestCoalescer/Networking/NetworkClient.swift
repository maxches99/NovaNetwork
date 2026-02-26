import Foundation

public final class NetworkClient: @unchecked Sendable {
    private let coalescer: RequestCoalescer<Data, NetworkError>
    private let transport: any NetworkTransport
    private let fingerprintPolicy: FingerprintPolicy
    private let retryPolicy: RetryPolicy
    private let retryClock: any RetryClock
    private let retryRandomGenerator: any RetryRandomGenerator
    private let defaultCachePolicy: CachePolicy
    private let cache: MemoryResponseCache
    private let decoder: JSONDecoder
    private let networkObserver: (@Sendable (NetworkClientEvent) -> Void)?

    public init(
        transport: any NetworkTransport = Transport(),
        cancellationPolicy: CancellationPolicy = .keepRunning,
        coalescerLimits: RequestCoalescer<Data, NetworkError>.Limits = .init(),
        fingerprintPolicy: FingerprintPolicy = .default,
        retryPolicy: RetryPolicy = .none,
        retryClock: any RetryClock = SystemRetryClock(),
        retryRandomGenerator: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        defaultCachePolicy: CachePolicy = .networkOnly,
        cacheMaxEntries: Int? = 256,
        observer: RequestCoalescer<Data, NetworkError>.Observer? = nil,
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
        self.cache = MemoryResponseCache(maxEntries: cacheMaxEntries)
        self.decoder = decoder
        self.networkObserver = networkObserver
    }

    public func load(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil
    ) async throws -> Data {
        let fingerprint = makeFingerprint(for: request, authScope: authScope)
        let key = fingerprint.key
        let resolvedPolicy = (cachePolicy ?? defaultCachePolicy).normalized

        switch resolvedPolicy {
        case .networkOnly:
            networkObserver?(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(request: request, key: key, storeInCache: false)
        case .cacheFirst(let maxAge):
            if let cached = await cache.entry(forKey: key),
               ageSeconds(since: cached.storedAtNanoseconds) <= maxAge {
                networkObserver?(.cacheHit(
                    key: key,
                    isStale: false,
                    ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                ))
                return cached.data
            }

            networkObserver?(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(request: request, key: key, storeInCache: true)
        case .staleWhileRevalidate(let maxAge, let staleAge):
            if let cached = await cache.entry(forKey: key) {
                let age = ageSeconds(since: cached.storedAtNanoseconds)
                if age <= maxAge {
                    networkObserver?(.cacheHit(
                        key: key,
                        isStale: false,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))
                    return cached.data
                }

                if age <= staleAge {
                    networkObserver?(.cacheHit(
                        key: key,
                        isStale: true,
                        ageMilliseconds: ageMilliseconds(since: cached.storedAtNanoseconds)
                    ))
                    Task {
                        _ = try? await self.fetchNetworkAndOptionallyStore(
                            request: request,
                            key: key,
                            storeInCache: true
                        )
                    }
                    return cached.data
                }
            }

            networkObserver?(.cacheMiss(key: key))
            return try await fetchNetworkAndOptionallyStore(request: request, key: key, storeInCache: true)
        }
    }

    public func load<T: Decodable & Sendable>(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        as type: T.Type = T.self,
        decoder: JSONDecoder? = nil
    ) async throws -> T {
        let data = try await load(
            request: request,
            authScope: authScope,
            cachePolicy: cachePolicy
        )
        let decoderToUse = decoder ?? self.decoder

        do {
            return try decoderToUse.decode(T.self, from: data)
        } catch {
            throw NetworkError.decoding(underlying: error)
        }
    }

    public func coalescerMetrics() async -> RequestCoalescer<Data, NetworkError>.Metrics {
        await coalescer.snapshotMetrics()
    }

    public func preload(request: APIRequest, authScope: String?) async throws {
        let key = makeFingerprint(for: request, authScope: authScope).key
        _ = try await fetchNetworkAndOptionallyStore(request: request, key: key, storeInCache: true)
    }

    public func invalidate(request: APIRequest, authScope: String?) async {
        let key = makeFingerprint(for: request, authScope: authScope).key
        await cache.remove(key: key)
        networkObserver?(.cacheInvalidated(key: key))
    }

    public func invalidate(fingerprintKey: String) async {
        await cache.remove(key: fingerprintKey)
        networkObserver?(.cacheInvalidated(key: fingerprintKey))
    }

    public func invalidateAll() async {
        await cache.removeAll()
    }

    public func invalidateAll(where shouldRemove: @escaping @Sendable (String) -> Bool) async {
        await cache.removeAll(where: shouldRemove)
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
        storeInCache: Bool
    ) async throws -> Data {
        let outcome = try await coalescer.run(key: key) {
            await Self.executeWithRetry(
                key: key,
                request: request,
                transport: self.transport,
                retryPolicy: self.retryPolicy,
                retryClock: self.retryClock,
                retryRandomGenerator: self.retryRandomGenerator,
                observer: self.networkObserver
            )
        }

        if storeInCache {
            await cache.set(outcome, forKey: key)
        }
        return outcome
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
    ) async -> Result<Data, NetworkError> {
        var attempt = 1

        while true {
            observer?(.requestAttempt(key: key, attempt: attempt))

            do {
                let data = try await transport.execute(request)
                observer?(.requestSucceeded(key: key, attempts: attempt))
                return .success(data)
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
        }
    }
}
