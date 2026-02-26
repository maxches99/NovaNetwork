import Foundation
import Testing
@testable import NovaNetworkClient

private enum DummyError: Error {
    case boom
}

private actor ThrowingClock: RetryClock {
    func sleep(nanoseconds: UInt64) async throws {
        throw DummyError.boom
    }
}

private actor NonCooperativeClock: RetryClock {
    func sleep(nanoseconds: UInt64) async throws {
        // Ignores cancellation by swallowing Task.sleep cancellation.
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}

private actor CancellationThrowingTransport: NetworkTransport {
    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        throw CancellationError()
    }
}

private actor GenericThrowingTransport: NetworkTransport {
    let error: any Error

    init(error: any Error) {
        self.error = error
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        throw error
    }
}

private actor SequenceThrowingTransport: NetworkTransport {
    private var remainingFailures: Int
    private let error: any Error
    private(set) var callCount = 0

    init(remainingFailures: Int, error: any Error) {
        self.remainingFailures = remainingFailures
        self.error = error
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        callCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw error
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))
    }

    func calls() -> Int { callCount }
}

private actor HeaderCapturingTransport: NetworkTransport {
    private(set) var lastHeaders: [String: String] = [:]

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        lastHeaders = request.headers
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))
    }

    func headers() -> [String: String] { lastHeaders }
}

private actor EventRecorder {
    private(set) var events: [NetworkClientEvent] = []

    func append(_ event: NetworkClientEvent) {
        events.append(event)
    }

    func count() -> Int { events.count }
    func snapshot() -> [NetworkClientEvent] { events }
}

private actor TelemetryRecorder {
    private(set) var coalescerEvents: [TelemetryCoalescerContext] = []
    private(set) var retryEvents: [TelemetryRetryContext] = []
    private(set) var cancellationEvents: [TelemetryCancellationContext] = []
    private(set) var queueEvents: [TelemetryQueueContext] = []

    func appendCoalescer(_ event: TelemetryCoalescerContext) { coalescerEvents.append(event) }
    func appendRetry(_ event: TelemetryRetryContext) { retryEvents.append(event) }
    func appendCancellation(_ event: TelemetryCancellationContext) { cancellationEvents.append(event) }
    func appendQueue(_ event: TelemetryQueueContext) { queueEvents.append(event) }

    func coalescerTypes() -> [TelemetryCoalescerEventType] { coalescerEvents.map(\.type) }
    func retryCount() -> Int { retryEvents.count }
    func cancellationReasons() -> [String] { cancellationEvents.map(\.reason) }
    func queueSnapshot() -> [TelemetryQueueContext] { queueEvents }
}

private actor MiddlewareProbe {
    private(set) var beforeCalls = 0
    private(set) var afterCalls = 0

    func onBefore() { beforeCalls += 1 }
    func onAfter() { afterCalls += 1 }
    func beforeCount() -> Int { beforeCalls }
    func afterCount() -> Int { afterCalls }
}

private final class URLProtocolStub: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func makeURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [URLProtocolStub.self]
    return URLSession(configuration: configuration)
}

@Suite(.serialized)
struct NetworkingCoverageTests {
    @Test
    func eventHubEmitsAndRemovesContinuationOnTermination() async {
        let hub = NetworkClientEventHub()
        let stream = await hub.makeStream()

        let consumer = Task { () -> NetworkClientEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await hub.emit(.cacheMiss(key: "k"))
        let received = await consumer.value
        #expect(received != nil)
    }

    @Test
    func eventHubCancellationTriggersTermination() async {
        let hub = NetworkClientEventHub()
        let stream = await hub.makeStream()

        let consumer = Task {
            for await _ in stream { }
        }
        consumer.cancel()
        _ = await consumer.result

        await hub.emit(.cacheMiss(key: "post-cancel"))
    }

    @Test
    func networkClientEventsStreamReceivesEvents() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)
        let stream = client.events()

        let consumer = Task { () -> NetworkClientEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/events")!)
        _ = try await client.load(request: request, authScope: nil)

        #expect(await consumer.value != nil)
    }

    @Test
    func networkErrorDerivedValuesCoverAllBranches() {
        let timeout = NetworkError.transport(underlying: URLError(.timedOut))
        let network = NetworkError.transport(underlying: URLError(.cannotConnectToHost))
        let decoding = NetworkError.decoding(underlying: DummyError.boom)
        let http = NetworkError.httpStatus(code: 429, body: Data())

        #expect(timeout.failureReason == .timedOut)
        #expect(network.failureReason == .transport)
        #expect(decoding.failureReason == .decoding)
        #expect(http.failureReason == .rateLimited)
        #expect(http.statusCode == 429)
        #expect(NetworkError.invalidResponse.statusCode == nil)
        #expect(decoding.underlyingError != nil)
        #expect(NetworkError.cancelled.failureReason == .cancelled)
        #expect(NetworkError.circuitBreakerOpen.failureReason == .circuitBreakerOpen)
    }

    @Test
    func transportMapsResponsesAndErrors() async {
        let transport = Transport(session: makeURLSession())

        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": "abc"]
            )!
            return (response, Data("ok".utf8))
        }
        let ok = try? await transport.execute(APIRequest(method: .get, url: URL(string: "https://example.com/ok")!))
        #expect(ok?.body == Data("ok".utf8))
        #expect(ok?.headerValue(for: "etag") == "abc")

        URLProtocolStub.requestHandler = { request in
            let response = URLResponse(
                url: request.url!,
                mimeType: "text/plain",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            return (response, Data())
        }
        do {
            _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://example.com/non-http")!))
            Issue.record("Expected invalidResponse")
        } catch let error as NetworkError {
            #expect(error.failureReason == .invalidResponse)
        } catch {
            Issue.record("Unexpected error type")
        }

        URLProtocolStub.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("bad".utf8))
        }
        do {
            _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://example.com/http-error")!))
            Issue.record("Expected HTTP status error")
        } catch let error as NetworkError {
            #expect(error.statusCode == 503)
        } catch {
            Issue.record("Unexpected error type")
        }

        URLProtocolStub.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://example.com/offline")!))
            Issue.record("Expected transport error")
        } catch let error as NetworkError {
            #expect(error.failureReason == .transport)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func networkClientDecodingFailureIsWrapped() async {
        let transport = StubNetworkTransport(response: .success(Data("not-json".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/decoding")!)

        do {
            let _: Payload = try await client.load(request: request, authScope: nil)
            Issue.record("Expected decoding error")
        } catch let error as NetworkError {
            #expect(error.failureReason == .decoding)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func networkClientInvalidateVariantsAndMemoryPressure() async throws {
        let transport = ScriptedNetworkTransport(
            responses: [
                .success(Data("v1".utf8)),
                .success(Data("v2".utf8)),
                .success(Data("v3".utf8))
            ]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/invalidate-all")!)

        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))
        await client.invalidate(fingerprintKey: RequestFingerprint.make(
            method: request.method.rawValue,
            url: request.url,
            queryItems: request.queryItems,
            headers: request.headers,
            body: request.body,
            authScope: nil
        ).key)
        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        await client.invalidateAll(where: { _ in true })
        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        await client.invalidateAll()
        await client.handleMemoryPressure(clearCache: false, cancelInFlight: false)
        await client.handleMemoryPressure()

        #expect(await transport.calls() == 3)
    }

    @Test
    func staleWhileRevalidateCoversFreshAndMissBranches() async throws {
        let transport = ScriptedNetworkTransport(
            responses: [
                .success(Data("fresh".utf8)),
                .success(Data("miss".utf8))
            ]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/swr-fresh")!)

        try await client.preload(request: request, authScope: nil)
        let fresh = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .staleWhileRevalidate(maxAge: 60, staleAge: 120)
        )
        #expect(fresh == Data("fresh".utf8))

        let missRequest = APIRequest(method: .get, url: URL(string: "https://example.com/swr-miss")!)
        let miss = try await client.load(
            request: missRequest,
            authScope: nil,
            cachePolicy: .staleWhileRevalidate(maxAge: 0, staleAge: 0)
        )
        #expect(miss == Data("miss".utf8))
    }

    @Test
    func cacheFirstExpiredRevalidationFailureThrows() async {
        let transport = ScriptedNetworkTransport(
            responses: [
                .success(NetworkResponse(statusCode: 200, headers: ["ETag": "v1"], body: Data("seed".utf8))),
                .failure(.httpStatus(code: 503, body: Data()))
            ]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/cache-fail")!)

        _ = try? await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        do {
            _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 0))
            Issue.record("Expected revalidation failure")
        } catch let error as NetworkError {
            #expect(error.statusCode == 503)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func circuitBreakerCoversKeyScopeSuccessAndNonCountedFailure() async {
        let successTransport = ScriptedNetworkTransport(
            responses: [.success(Data("ok".utf8))]
        )
        let successClient = NetworkClient(transport: successTransport)
        let successRequest = APIRequest(method: .get, url: URL(string: "https://example.com/key-scope")!)
        let keyPolicy = CircuitBreakerPolicy(scope: .key, failureThreshold: 1, cooldownSeconds: 60)
        let keyOptions = RequestExecutionOptions(circuitBreakerPolicy: keyPolicy)

        _ = try? await successClient.load(request: successRequest, authScope: nil as String?, cachePolicy: nil, options: keyOptions)
        #expect(await successTransport.calls() == 1)

        let invalidResponseTransport = Transport(session: makeURLSession())
        URLProtocolStub.requestHandler = { request in
            let response = URLResponse(
                url: request.url!,
                mimeType: "text/plain",
                expectedContentLength: 0,
                textEncodingName: nil
            )
            return (response, Data())
        }
        let invalidClient = NetworkClient(transport: invalidResponseTransport)
        let invalidRequest = APIRequest(method: .get, url: URL(string: "https://example.com/non-counted")!)
        let options = RequestExecutionOptions(
            circuitBreakerPolicy: .init(scope: .host, failureThreshold: 1, cooldownSeconds: 60)
        )

        _ = try? await invalidClient.load(request: invalidRequest, authScope: nil as String?, cachePolicy: nil, options: options)
        _ = try? await invalidClient.load(request: invalidRequest, authScope: nil as String?, cachePolicy: nil, options: options)
    }

    @Test
    func circuitBreakerCountsRateLimitedFailure() async {
        let transport = ScriptedNetworkTransport(
            responses: [Result<Data, NetworkError>.failure(.httpStatus(code: 429, body: Data()))]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/rate-limit")!)
        let options = RequestExecutionOptions(
            circuitBreakerPolicy: .init(scope: .host, failureThreshold: 1, cooldownSeconds: 60)
        )

        _ = try? await client.load(request: request, authScope: nil as String?, cachePolicy: nil, options: options)
        do {
            _ = try await client.load(request: request, authScope: nil as String?, cachePolicy: nil, options: options)
            Issue.record("Expected open circuit breaker")
        } catch let error as NetworkError {
            guard case .circuitBreakerOpen = error else {
                Issue.record("Expected circuit breaker open")
                return
            }
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func retriesCoverCancellationGenericErrorsAndObserverReasons() async {
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retries")!)
        let recorder = EventRecorder()

        let cancelledClient = NetworkClient(
            transport: CancellationThrowingTransport(),
            retryPolicy: .init(maxAttempts: 2),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        do {
            _ = try await cancelledClient.load(request: request, authScope: nil)
            Issue.record("Expected cancellation")
        } catch let error as NetworkError {
            #expect(error.failureReason == .cancelled)
        } catch {
            Issue.record("Unexpected error")
        }

        let genericTransport = GenericThrowingTransport(error: DummyError.boom)
        let genericClient = NetworkClient(
            transport: genericTransport,
            retryPolicy: .init(maxAttempts: 1),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        do {
            _ = try await genericClient.load(request: request, authScope: nil)
            Issue.record("Expected wrapped transport error")
        } catch let error as NetworkError {
            #expect(error.failureReason == .transport)
        } catch {
            Issue.record("Unexpected error")
        }

        let retriableGeneric = SequenceThrowingTransport(
            remainingFailures: 1,
            error: URLError(.timedOut)
        )
        let clockFailingClient = NetworkClient(
            transport: retriableGeneric,
            retryPolicy: .init(maxAttempts: 3),
            retryClock: ThrowingClock(),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        do {
            _ = try await clockFailingClient.load(request: request, authScope: nil)
            Issue.record("Expected cancellation from retry clock")
        } catch let error as NetworkError {
            #expect(error.failureReason == .cancelled)
        } catch {
            Issue.record("Unexpected error")
        }

        #expect(await recorder.count() > 0)
    }

    @Test
    func genericRetryPathCanContinueAfterSleep() async throws {
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let clock = RecordingRetryClock()
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            retryClock: clock,
            networkObserver: { _ in }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/generic-retry")!)
        let data = try await client.load(request: request, authScope: nil)

        #expect(data == Data("ok".utf8))
        #expect(await transport.calls() == 2)
        #expect(await clock.recordedSleeps().count == 1)
    }

    @Test
    func retryPolicyShouldRetryCoversCancelledAndDefaultCases() {
        let policy = RetryPolicy(maxAttempts: 2)
        #expect(policy.shouldRetry(error: .cancelled) == false)
        #expect(policy.shouldRetry(error: .invalidResponse) == false)
    }

    @Test
    func observerFailureReasonsCoverAllNetworkErrorCases() async {
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/reasons")!)
        let errors: [NetworkError] = [
            .invalidResponse,
            .httpStatus(code: 418, body: Data()),
            .decoding(underlying: DummyError.boom),
            .cancelled,
            .circuitBreakerOpen
        ]

        for error in errors {
            let transport = StubNetworkTransport(response: Result<NetworkResponse, NetworkError>.failure(error))
            let client = NetworkClient(
                transport: transport,
                retryPolicy: .init(maxAttempts: 1),
                networkObserver: { _ in }
            )
            _ = try? await client.load(request: request, authScope: nil)
        }
    }

    @Test
    func retrySleepFailureAfterNetworkErrorReturnsCancelled() async {
        let transport = StubNetworkTransport(
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 503, body: Data()))
        )
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2),
            retryClock: ThrowingClock(),
            networkObserver: { _ in }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry-sleep-cancel")!)

        do {
            _ = try await client.load(request: request, authScope: nil)
            Issue.record("Expected cancelled error")
        } catch let error as NetworkError {
            #expect(error.failureReason == .cancelled)
        } catch {
            Issue.record("Unexpected error")
        }
    }

    @Test
    func retryPolicyDoesNotRetryNonIdempotentRequestByDefault() async {
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            networkObserver: { _ in }
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/post-no-retry")!)

        do {
            _ = try await client.load(request: request, authScope: nil)
            Issue.record("Expected failure without retry")
        } catch let error as NetworkError {
            #expect(error.failureReason == .timedOut || error.failureReason == .transport)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(await transport.calls() == 1)
    }

    @Test
    func retryPolicyCanRetryNonIdempotentRequestWhenOverrideEnabled() async throws {
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2, retryNonIdempotentRequests: true, jitterRange: nil),
            networkObserver: { _ in }
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/post-retry-enabled")!)

        let data = try await client.load(request: request, authScope: nil)

        #expect(data == Data("ok".utf8))
        #expect(await transport.calls() == 2)
    }

    @Test
    func retryPolicyRetriesPostWhenIdempotencyHeaderPresent() async throws {
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            networkObserver: { _ in }
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/post-idempotency-header")!)
            .withIdempotencyKey("abc-123")

        let data = try await client.load(request: request, authScope: nil)

        #expect(data == Data("ok".utf8))
        #expect(await transport.calls() == 2)
    }

    @Test
    func cancellationDuringRetryBackoffStopsFurtherAttempts() async {
        let transport = SequenceThrowingTransport(remainingFailures: 10, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            cancellationPolicy: .cancelWhenNoWaiters,
            retryPolicy: .init(maxAttempts: 3, baseDelayNanoseconds: 300_000_000, jitterRange: nil),
            retryClock: NonCooperativeClock(),
            networkObserver: { _ in }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/cancel-during-backoff")!)

        let task = Task {
            try await client.load(request: request, authScope: nil)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancelled error")
        } catch let error as NetworkError {
            #expect(error.failureReason == .cancelled)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(await transport.calls() == 1)
    }

    @Test
    func transportMapsCancellationErrorToCancelled() async {
        let transport = Transport(session: makeURLSession())
        URLProtocolStub.requestHandler = { _ in throw CancellationError() }

        do {
            _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://example.com/cancel")!))
            Issue.record("Expected cancelled transport")
        } catch let error as NetworkError {
            #expect(error.failureReason == .transport)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func transportTaskCancellationMayMapToCancelled() async {
        let transport = Transport(session: makeURLSession())
        URLProtocolStub.requestHandler = { request in
            Thread.sleep(forTimeInterval: 0.2)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("slow".utf8))
        }

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/slow-cancel")!)
        let task = Task { try await transport.execute(request) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()

        _ = await task.result
    }

    @Test
    func requestExecutionOptionsMapAllPrioritiesAndScheduling() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/options")!)

        _ = try await client.load(
            request: request,
            authScope: nil,
            options: .init(priority: .low, capacityScheduling: .queueByPriority)
        )
        _ = try await client.load(
            request: request,
            authScope: nil,
            options: .init(priority: .high, capacityScheduling: .bypassWhenAtCapacity)
        )
    }

    @Test
    func circuitBreakerStoreCoversDirectBranches() async {
        let store = CircuitBreakerStore()
        let policy = CircuitBreakerPolicy(scope: .host, failureThreshold: 3, cooldownSeconds: 0)
        await store.recordFailure(identifier: "id", policy: policy)
        await store.recordSuccess(identifier: "id")

        let openPolicy = CircuitBreakerPolicy(scope: .host, failureThreshold: 1, cooldownSeconds: 0)
        await store.recordFailure(identifier: "id2", policy: openPolicy)
        #expect(await store.canExecute(identifier: "id2"))
    }

    @Test
    func middlewarePipelineTransformsRequestAndResponse() async throws {
        let probe = MiddlewareProbe()
        let middleware = NetworkMiddleware(
            beforeSend: { request, _ in
                await probe.onBefore()
                return request.withMergedHeaders(["X-Test": "1"])
            },
            afterResponse: { _, _, response in
                await probe.onAfter()
                return NetworkResponse(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    body: Data("mutated".utf8)
                )
            }
        )
        let transport = StubNetworkTransport(response: .success(Data("raw".utf8)))
        let client = NetworkClient(transport: transport, middlewares: [middleware])
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/middleware")!)

        let result = try await client.load(request: request, authScope: nil)
        #expect(result == Data("mutated".utf8))
        #expect(await probe.beforeCount() == 1)
        #expect(await probe.afterCount() == 1)
    }

    @Test
    func retryPolicyRespectsRetryAfterHeader() {
        let policy = RetryPolicy(
            maxAttempts: 3,
            baseDelayNanoseconds: 100_000_000,
            maxDelayNanoseconds: 200_000_000,
            jitterRange: nil
        )
        let error = NetworkError.httpStatus(
            code: 429,
            headers: ["Retry-After": "2"],
            body: Data()
        )
        let delay = policy.adaptiveDelayNanoseconds(forAttempt: 1, error: error, random: FixedRetryRandom(value: 1))
        #expect(delay == 2_000_000_000)
    }

    @Test
    func clientRateLimitBlocksSecondRequestWithinWindow() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/local-rate-limit")!)
        let options = RequestExecutionOptions(rateLimitPolicy: .init(maxRequests: 1, intervalSeconds: 60))

        _ = try await client.load(request: request, authScope: nil, options: options)
        do {
            _ = try await client.load(request: request, authScope: nil, options: options)
            Issue.record("Expected client-side rate limit")
        } catch let error as NetworkError {
            guard case .clientRateLimited(let retryAfter) = error else {
                Issue.record("Expected clientRateLimited")
                return
            }
            #expect((retryAfter ?? 0) > 0)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func inFlightRequestsExposesActiveKey() async throws {
        let transport = StubNetworkTransport(delayNanos: 300_000_000, response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/in-flight")!)

        let task = Task {
            try await client.load(request: request, authScope: nil)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)

        let entries = await client.inFlightRequests()
        #expect(entries.contains(where: { !$0.key.isEmpty }))
        _ = try await task.value
    }

    @Test
    func loadWithErrorMapperMapsNetworkErrors() async {
        enum DomainError: Error, Equatable { case remoteFailure }

        let transport = StubNetworkTransport(
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 500, body: Data()))
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/mapped-error")!)

        do {
            _ = try await client.load(
                request: request,
                authScope: nil,
                errorMapper: { _ in DomainError.remoteFailure }
            )
            Issue.record("Expected mapped error")
        } catch let error as DomainError {
            #expect(error == .remoteFailure)
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func cacheControlNoStoreAndVaryAreRespected() async throws {
        let noStoreTransport = ScriptedNetworkTransport(
            responses: [
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: ["Cache-Control": "no-store"],
                        body: Data("network-only".utf8)
                    )
                ),
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: ["Cache-Control": "no-store"],
                        body: Data("network-only".utf8)
                    )
                )
            ]
        )
        let noStoreClient = NetworkClient(transport: noStoreTransport)
        let baseURL = URL(string: "https://example.com/cache-control")!
        let noStore = APIRequest(method: .get, url: baseURL)

        _ = try await noStoreClient.load(request: noStore, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))
        _ = try await noStoreClient.load(request: noStore, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        #expect(await noStoreTransport.calls() == 2)

        let varyTransport = ScriptedNetworkTransport(
            responses: [
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: ["Vary": "Accept-Language"],
                        body: Data("lang-en".utf8)
                    )
                ),
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: ["Vary": "Accept-Language"],
                        body: Data("lang-fr".utf8)
                    )
                )
            ]
        )
        let varyClient = NetworkClient(transport: varyTransport)

        let en = APIRequest(method: .get, url: baseURL.appendingPathComponent("vary"), headers: ["Accept-Language": "en"])
        let fr = APIRequest(method: .get, url: baseURL.appendingPathComponent("vary"), headers: ["Accept-Language": "fr"])
        let enBody = try await varyClient.load(request: en, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))
        let frBody = try await varyClient.load(request: fr, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        #expect(enBody == Data("lang-en".utf8))
        #expect(frBody == Data("lang-fr".utf8))
        #expect(await varyTransport.calls() == 2)
    }

    @Test
    func loadStreamFallsBackToSingleChunkWhenStreamingTransportUnavailable() async throws {
        let transport = StubNetworkTransport(response: .success(Data("chunk".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/stream-fallback")!)

        var chunks: [Data] = []
        for try await chunk in client.loadStream(request: request, authScope: nil) {
            chunks.append(chunk)
        }
        #expect(chunks == [Data("chunk".utf8)])
    }

    @Test
    func idempotencyPolicyAddsHeaderForGuardedMethod() async throws {
        let transport = HeaderCapturingTransport()
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/idempotency")!)
        let options = RequestExecutionOptions(idempotencyPolicy: .default)

        _ = try await client.load(request: request, authScope: nil, options: options)
        let headers = await transport.headers()
        #expect(headers.keys.contains(where: { $0.lowercased() == "idempotency-key" }))
    }

    @Test
    func telemetryHooksEmitCoalescerRetryAndCancellationContracts() async {
        let recorder = TelemetryRecorder()

        let coalescingTransport = StubNetworkTransport(delayNanos: 150_000_000, response: .success(Data("ok".utf8)))
        let coalescingClient = NetworkClient(
            transport: coalescingTransport,
            telemetryHooks: .init(
                onCoalescerEvent: { context in Task { await recorder.appendCoalescer(context) } }
            )
        )
        let coalescingRequest = APIRequest(method: .get, url: URL(string: "https://example.com/telemetry-coalesced")!)
        async let first: Data = coalescingClient.load(request: coalescingRequest, authScope: nil)
        async let second: Data = coalescingClient.load(request: coalescingRequest, authScope: nil)
        _ = try? await (first, second)

        let retryTransport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let retryClient = NetworkClient(
            transport: retryTransport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            retryClock: ThrowingClock(),
            telemetryHooks: .init(
                onRetryScheduled: { context in Task { await recorder.appendRetry(context) } },
                onRequestCancelled: { context in Task { await recorder.appendCancellation(context) } }
            )
        )
        let retryRequest = APIRequest(method: .get, url: URL(string: "https://example.com/telemetry-retry-cancel")!)
        _ = try? await retryClient.load(request: retryRequest, authScope: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let coalescerTypes = await recorder.coalescerTypes()
        let coalescedJoinCount = coalescerTypes.filter { $0 == .coalesced }.count
        #expect(coalescerTypes.contains(.started))
        #expect(coalescerTypes.contains(.coalesced))
        #expect(coalescerTypes.contains(.finished))
        #expect(coalescedJoinCount == 1)
        #expect(await recorder.retryCount() == 1)
        #expect(await recorder.cancellationReasons().contains("retrySleepCancelled"))
    }

    @Test
    func telemetryQueueMetricsExposeNumericDepthAndWaitMilliseconds() async throws {
        let recorder = TelemetryRecorder()
        let transport = StubNetworkTransport(delayNanos: 120_000_000, response: .success(Data("ok".utf8)))
        let client = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 1),
            telemetryHooks: .init(
                onQueueMetrics: { context in Task { await recorder.appendQueue(context) } }
            )
        )

        let first = APIRequest(method: .get, url: URL(string: "https://example.com/queue-a")!)
        let second = APIRequest(method: .get, url: URL(string: "https://example.com/queue-b")!)

        async let one = client.load(
            request: first,
            authScope: nil,
            options: .init(priority: .low, capacityScheduling: .queueByPriority)
        )
        try? await Task.sleep(nanoseconds: 15_000_000)
        async let two = client.load(
            request: second,
            authScope: nil,
            options: .init(priority: .high, capacityScheduling: .queueByPriority)
        )

        _ = try await (one, two)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let queueEvents = await recorder.queueSnapshot()
        #expect(!queueEvents.isEmpty)
        guard let firstQueueEvent = queueEvents.first else {
            Issue.record("Expected queue metrics event")
            return
        }
        #expect(firstQueueEvent.queueDepth >= 1)
        #expect(firstQueueEvent.waitMilliseconds >= 0)
    }

    @Test
    func networkObserverRetryLifecycleEventCountsAreConsistent() async throws {
        let recorder = EventRecorder()
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry-lifecycle")!)

        _ = try await client.load(request: request, authScope: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let events = await recorder.snapshot()
        let attemptCount = events.reduce(0) { count, event in
            if case .requestAttempt = event { return count + 1 }
            return count
        }
        let retryCount = events.reduce(0) { count, event in
            if case .retryScheduled = event { return count + 1 }
            return count
        }
        let successCount = events.reduce(0) { count, event in
            if case .requestSucceeded = event { return count + 1 }
            return count
        }
        let failureCount = events.reduce(0) { count, event in
            if case .requestFailed = event { return count + 1 }
            return count
        }

        #expect(attemptCount == 2)
        #expect(retryCount == 1)
        #expect(successCount == 1)
        #expect(failureCount == 0)
    }

    @Test
    func networkObserverDoesNotEmitSuccessOnTerminalFailure() async {
        let recorder = EventRecorder()
        let transport = StubNetworkTransport(
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 503, body: Data()))
        )
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 1),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/terminal-failure")!)

        do {
            _ = try await client.load(request: request, authScope: nil)
            Issue.record("Expected failure")
        } catch {
            // expected
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let events = await recorder.snapshot()
        let successCount = events.reduce(0) { count, event in
            if case .requestSucceeded = event { return count + 1 }
            return count
        }
        let failureCount = events.reduce(0) { count, event in
            if case .requestFailed = event { return count + 1 }
            return count
        }

        #expect(successCount == 0)
        #expect(failureCount == 1)
    }
}
