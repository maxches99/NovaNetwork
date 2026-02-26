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
    private let middlewares: [NetworkMiddleware]
    private let telemetryHooks: NetworkTelemetryHooks?
    private let eventHub = NetworkClientEventHub()
    private let circuitBreakerStore = CircuitBreakerStore()
    private let rateLimiter = KeyRateLimiter()

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
        middlewares: [NetworkMiddleware] = [],
        telemetryHooks: NetworkTelemetryHooks? = nil,
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
        self.middlewares = middlewares
        self.telemetryHooks = telemetryHooks
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
        if let rateLimitPolicy = options.rateLimitPolicy,
           let retryAfter = await rateLimiter.acquire(key: key, policy: rateLimitPolicy) {
            emit(.requestRateLimited(key: key, retryAfterSeconds: retryAfter))
            throw NetworkError.clientRateLimited(retryAfterSeconds: retryAfter)
        }

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
        let preparedRequest = try await prepareRequestForExecution(
            request: conditionalRequest,
            key: key,
            options: options
        )

        let outcome: NetworkResponse
        do {
            outcome = try await coalescer.run(
                key: key,
                options: coalescerRunOptions(from: options)
            ) {
                await Self.executeWithRetry(
                    key: key,
                    request: preparedRequest,
                    authScope: authScope,
                    transport: self.transport,
                    retryPolicy: self.retryPolicy,
                    retryClock: self.retryClock,
                    retryRandomGenerator: self.retryRandomGenerator,
                    middlewares: self.middlewares,
                    telemetryHooks: self.telemetryHooks,
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
        authScope: String?,
        transport: any NetworkTransport,
        retryPolicy: RetryPolicy,
        retryClock: any RetryClock,
        retryRandomGenerator: any RetryRandomGenerator,
        middlewares: [NetworkMiddleware],
        telemetryHooks: NetworkTelemetryHooks?,
        observer: (@Sendable (NetworkClientEvent) -> Void)?
    ) async -> Result<NetworkResponse, NetworkError> {
        var attempt = 1
        var retriesUsed = 0

        while true {
            observer?(.requestAttempt(key: key, attempt: attempt))

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let telemetryRequest = TelemetryRequestContext(key: key, attempt: attempt, request: request)
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
                observer?(.requestFailed(key: key, attempts: attempt, reason: "cancelled"))
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

                if !retryPolicy.canRetry(attempt: attempt, retriesUsed: retriesUsed) || !retryPolicy.shouldRetry(error: error) {
                    observer?(.requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: failureReason(error: error)
                    ))
                    return .failure(error)
                }

                let delay = retryPolicy.adaptiveDelayNanoseconds(
                    forAttempt: attempt,
                    error: error,
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

                if !retryPolicy.canRetry(attempt: attempt, retriesUsed: retriesUsed) || !retryPolicy.shouldRetry(error: wrapped) {
                    observer?(.requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: failureReason(error: wrapped)
                    ))
                    return .failure(wrapped)
                }

                let delay = retryPolicy.adaptiveDelayNanoseconds(
                    forAttempt: attempt,
                    error: wrapped,
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

                retriesUsed += 1
                attempt += 1
                continue
            }
        }
    }

    private static func failureReason(error: NetworkError) -> String {
        switch error {
        case .invalidResponse:
            return "invalidResponse"
        case .httpStatus(let code, _, _):
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
        case .clientRateLimited:
            return "clientRateLimited"
        }
    }

    private func prepareRequestForExecution(
        request: APIRequest,
        key: String,
        options: RequestExecutionOptions
    ) async throws -> APIRequest {
        guard let idempotencyPolicy = options.idempotencyPolicy else {
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
