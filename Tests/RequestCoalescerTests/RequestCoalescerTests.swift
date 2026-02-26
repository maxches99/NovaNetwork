import Foundation
import Testing
@testable import RequestCoalescer

enum TestError: Error, Equatable { case failed }

struct Payload: Codable, Equatable, Sendable {
    let value: String
}

actor CountingTransport {
    private(set) var callCount = 0
    var result: Result<Data, TestError> = .success(Data("ok".utf8))
    var delayNanos: UInt64 = 100_000_000

    func setResult(_ newValue: Result<Data, TestError>) {
        result = newValue
    }

    func setDelay(_ nanoseconds: UInt64) {
        delayNanos = nanoseconds
    }

    func execute() async -> Result<Data, TestError> {
        callCount += 1
        try? await Task.sleep(nanoseconds: delayNanos)
        return result
    }

    func calls() -> Int { callCount }
}

actor StubNetworkTransport: NetworkTransport {
    private(set) var callCount = 0
    private let delayNanos: UInt64
    private let response: Result<Data, NetworkError>

    init(delayNanos: UInt64 = 100_000_000, response: Result<Data, NetworkError>) {
        self.delayNanos = delayNanos
        self.response = response
    }

    func execute(_ request: APIRequest) async throws -> Data {
        callCount += 1
        try? await Task.sleep(nanoseconds: delayNanos)

        switch response {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func calls() -> Int { callCount }
}

actor FlakyNetworkTransport: NetworkTransport {
    private(set) var callCount = 0
    private var remainingFailures: Int
    private let failure: NetworkError
    private let successData: Data

    init(remainingFailures: Int, failure: NetworkError, successData: Data = Data("ok".utf8)) {
        self.remainingFailures = remainingFailures
        self.failure = failure
        self.successData = successData
    }

    func execute(_ request: APIRequest) async throws -> Data {
        callCount += 1

        if remainingFailures > 0 {
            remainingFailures -= 1
            throw failure
        }

        return successData
    }

    func calls() -> Int { callCount }
}

actor CancellationProbe {
    private(set) var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func wasCancelled() -> Bool { cancelled }
}

actor ScriptedNetworkTransport: NetworkTransport {
    private(set) var callCount = 0
    private var responses: [Result<Data, NetworkError>]
    private let delayNanos: UInt64

    init(responses: [Result<Data, NetworkError>], delayNanos: UInt64 = 0) {
        self.responses = responses
        self.delayNanos = delayNanos
    }

    func execute(_ request: APIRequest) async throws -> Data {
        callCount += 1
        if delayNanos > 0 {
            try? await Task.sleep(nanoseconds: delayNanos)
        }

        guard !responses.isEmpty else {
            throw NetworkError.httpStatus(code: 500, body: Data())
        }

        let response = responses.removeFirst()
        switch response {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    func calls() -> Int { callCount }
}

actor RecordingRetryClock: RetryClock {
    private(set) var sleeps: [UInt64] = []

    func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(nanoseconds)
    }

    func recordedSleeps() -> [UInt64] { sleeps }
}

struct FixedRetryRandom: RetryRandomGenerator {
    let value: Double

    func nextDouble(in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

@Suite
struct RequestCoalescerTests {
    @Test
    func coalescesConcurrentSuccess() async throws {
        let transport = CountingTransport()
        let coalescer = RequestCoalescer<Data, TestError>()

        async let a = coalescer.run(key: "k") { await transport.execute() }
        async let b = coalescer.run(key: "k") { await transport.execute() }

        let (ra, rb) = try await (a, b)
        #expect(ra == rb)
        #expect(await transport.calls() == 1)
    }

    @Test
    func coalescesConcurrentFailure() async {
        let transport = CountingTransport()
        await transport.setResult(.failure(.failed))

        let coalescer = RequestCoalescer<Data, TestError>()

        async let a: Void = {
            do { _ = try await coalescer.run(key: "k") { await transport.execute() } }
            catch { #expect((error as? TestError) == .failed) }
        }()

        async let b: Void = {
            do { _ = try await coalescer.run(key: "k") { await transport.execute() } }
            catch { #expect((error as? TestError) == .failed) }
        }()

        _ = await (a, b)
        #expect(await transport.calls() == 1)
    }

    @Test
    func startsNewCallAfterCompletion() async throws {
        let transport = CountingTransport()
        let coalescer = RequestCoalescer<Data, TestError>()

        _ = try await coalescer.run(key: "k") { await transport.execute() }
        _ = try await coalescer.run(key: "k") { await transport.execute() }

        #expect(await transport.calls() == 2)
    }

    @Test
    func differentKeysDoNotCoalesce() async throws {
        let transport = CountingTransport()
        let coalescer = RequestCoalescer<Data, TestError>()

        async let a = coalescer.run(key: "k1") { await transport.execute() }
        async let b = coalescer.run(key: "k2") { await transport.execute() }

        _ = try await (a, b)
        #expect(await transport.calls() == 2)
    }

    @Test
    func cancelWhenNoWaitersCancelsUnderlyingTask() async {
        let probe = CancellationProbe()
        let coalescer = RequestCoalescer<Data, TestError>(policy: .cancelWhenNoWaiters)

        let taskA = Task {
            try? await coalescer.run(key: "k") {
                await withTaskCancellationHandler {
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        return .success(Data())
                    } catch {
                        return .failure(.failed)
                    }
                } onCancel: {
                    Task { await probe.markCancelled() }
                }
            }
        }

        let taskB = Task {
            try? await coalescer.run(key: "k") {
                await withTaskCancellationHandler {
                    do {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                        return .success(Data())
                    } catch {
                        return .failure(.failed)
                    }
                } onCancel: {
                    Task { await probe.markCancelled() }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        taskA.cancel()
        taskB.cancel()

        _ = await taskA.result
        _ = await taskB.result

        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(await probe.wasCancelled())
    }

    @Test
    func cancelOneWaiterKeepsUnderlyingTaskRunning() async throws {
        let transport = CountingTransport()
        let coalescer = RequestCoalescer<Data, TestError>(policy: .cancelWhenNoWaiters)
        await transport.setDelay(500_000_000)

        let first = Task {
            try await coalescer.run(key: "k") { await transport.execute() }
        }

        let second = Task {
            try await coalescer.run(key: "k") { await transport.execute() }
        }

        // Wait until the second waiter has joined the in-flight request.
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let metrics = await coalescer.snapshotMetrics()
            if metrics.coalescedHits >= 1 {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        first.cancel()
        _ = await first.result
        _ = try await second.value

        #expect(await transport.calls() == 1)
    }

    @Test
    func canonicalizationMakesStableFingerprintForJSONFieldOrder() async {
        let url = URL(string: "https://example.com/api")!
        let body1 = Data(#"{"b":2,"a":1}"#.utf8)
        let body2 = Data(#"{"a":1,"b":2}"#.utf8)

        let f1 = RequestFingerprint.make(method: "POST", url: url, queryItems: nil, body: body1, authScope: "scope")
        let f2 = RequestFingerprint.make(method: "POST", url: url, queryItems: nil, body: body2, authScope: "scope")

        #expect(f1.key == f2.key)
    }

    @Test
    func fingerprintIncludesHeadersByDefault() {
        let url = URL(string: "https://example.com/api")!
        let first = RequestFingerprint.make(
            method: "GET",
            url: url,
            queryItems: nil,
            headers: ["Accept": "application/json"],
            body: nil,
            authScope: nil
        )
        let second = RequestFingerprint.make(
            method: "GET",
            url: url,
            queryItems: nil,
            headers: ["Accept": "text/plain"],
            body: nil,
            authScope: nil
        )

        #expect(first.key != second.key)
    }

    @Test
    func fingerprintPolicyCanIgnoreHeaders() {
        let policy = FingerprintPolicy(headerInclusion: .none)
        let url = URL(string: "https://example.com/api")!

        let first = RequestFingerprint.make(
            method: "GET",
            url: url,
            queryItems: nil,
            headers: ["Accept": "application/json"],
            body: nil,
            authScope: nil,
            policy: policy
        )
        let second = RequestFingerprint.make(
            method: "GET",
            url: url,
            queryItems: nil,
            headers: ["Accept": "text/plain"],
            body: nil,
            authScope: nil,
            policy: policy
        )

        #expect(first.key == second.key)
    }

    @Test
    func networkClientCoalescesEqualRequests() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)

        let request = APIRequest(
            method: .get,
            url: URL(string: "https://example.com/resource")!,
            queryItems: [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")]
        )

        async let a = client.load(request: request, authScope: "user:1")
        async let b = client.load(request: request, authScope: "user:1")

        let (ra, rb) = try await (a, b)
        #expect(ra == rb)
        #expect(await transport.calls() == 1)
    }

    @Test
    func networkClientDoesNotCoalesceDifferentAuthScopes() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/resource")!)

        async let a = client.load(request: request, authScope: "user:1")
        async let b = client.load(request: request, authScope: "user:2")

        _ = try await (a, b)
        #expect(await transport.calls() == 2)
    }

    @Test
    func networkClientDoesNotCoalesceDifferentHeadersByDefault() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)

        let first = APIRequest(
            method: .get,
            url: URL(string: "https://example.com/resource")!,
            headers: ["Accept": "application/json"]
        )
        let second = APIRequest(
            method: .get,
            url: URL(string: "https://example.com/resource")!,
            headers: ["Accept": "text/plain"]
        )

        async let a = client.load(request: first, authScope: "user:1")
        async let b = client.load(request: second, authScope: "user:1")

        _ = try await (a, b)
        #expect(await transport.calls() == 2)
    }

    @Test
    func retryPolicyRetriesRetriableErrors() async throws {
        let transport = FlakyNetworkTransport(
            remainingFailures: 2,
            failure: .httpStatus(code: 503, body: Data())
        )
        let policy = RetryPolicy(maxAttempts: 3, baseDelayNanoseconds: 1_000_000, maxDelayNanoseconds: 2_000_000, jitterRange: nil)
        let client = NetworkClient(transport: transport, retryPolicy: policy)

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/resource")!)
        let data = try await client.load(request: request, authScope: nil)

        #expect(data == Data("ok".utf8))
        #expect(await transport.calls() == 3)
    }

    @Test
    func retryPolicyDoesNotRetryNonRetriableErrors() async {
        let transport = FlakyNetworkTransport(
            remainingFailures: 2,
            failure: .httpStatus(code: 400, body: Data())
        )
        let policy = RetryPolicy(maxAttempts: 3, baseDelayNanoseconds: 1_000_000, maxDelayNanoseconds: 2_000_000, jitterRange: nil)
        let client = NetworkClient(transport: transport, retryPolicy: policy)

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/resource")!)

        do {
            _ = try await client.load(request: request, authScope: nil)
            Issue.record("Expected to throw")
        } catch let error as NetworkError {
            guard case .httpStatus(let code, _) = error else {
                Issue.record("Expected HTTP status error")
                return
            }
            #expect(code == 400)
        } catch {
            Issue.record("Unexpected error type")
        }

        #expect(await transport.calls() == 1)
    }

    @Test
    func networkClientDecodesJSONPayload() async throws {
        let payload = Data(#"{"value":"ok"}"#.utf8)
        let transport = StubNetworkTransport(response: .success(payload))
        let client = NetworkClient(transport: transport)

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/resource")!)
        let decoded: Payload = try await client.load(request: request, authScope: nil)

        #expect(decoded == Payload(value: "ok"))
    }

    @Test
    func exposesCoalescerMetrics() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/resource")!)

        async let a = client.load(request: request, authScope: nil)
        async let b = client.load(request: request, authScope: nil)
        _ = try await (a, b)

        let metrics = await client.coalescerMetrics()
        #expect(metrics.coalescedMisses == 1)
        #expect(metrics.coalescedHits == 1)
        #expect(metrics.finishedOperations == 1)
    }

    @Test
    func cacheFirstReturnsCachedResponse() async throws {
        let transport = ScriptedNetworkTransport(
            responses: [.success(Data("first".utf8))]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/cache")!)

        let first = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .cacheFirst(maxAge: 60)
        )
        let second = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .cacheFirst(maxAge: 60)
        )

        #expect(first == second)
        #expect(await transport.calls() == 1)
    }

    @Test
    func staleWhileRevalidateReturnsStaleThenRefreshes() async throws {
        let transport = ScriptedNetworkTransport(
            responses: [
                .success(Data("v1".utf8)),
                .success(Data("v2".utf8))
            ]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/swr")!)

        try await client.preload(request: request, authScope: nil)
        let stale = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .staleWhileRevalidate(maxAge: 0, staleAge: 60)
        )
        #expect(stale == Data("v1".utf8))

        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await transport.calls() >= 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let refreshed = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .cacheFirst(maxAge: 60)
        )
        #expect(refreshed == Data("v2".utf8))
        #expect(await transport.calls() >= 2)
    }

    @Test
    func invalidateRemovesCachedResponse() async throws {
        let transport = ScriptedNetworkTransport(
            responses: [
                .success(Data("first".utf8)),
                .success(Data("second".utf8))
            ]
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/invalidate")!)

        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))
        await client.invalidate(request: request, authScope: nil)
        let result = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        #expect(result == Data("second".utf8))
        #expect(await transport.calls() == 2)
    }

    @Test
    func maxWaitersLimitBypassesCoalescing() async throws {
        let transport = CountingTransport()
        await transport.setDelay(100_000_000)
        let coalescer = RequestCoalescer<Data, TestError>(
            limits: .init(maxWaitersPerKey: 1)
        )

        async let a = coalescer.run(key: "limit") { await transport.execute() }
        async let b = coalescer.run(key: "limit") { await transport.execute() }
        _ = try await (a, b)

        let metrics = await coalescer.snapshotMetrics()
        #expect(await transport.calls() == 2)
        #expect(metrics.bypassedDueToWaiterLimit == 1)
    }

    @Test
    func inFlightTimeoutEvictsHungEntries() async {
        let coalescer = RequestCoalescer<Data, TestError>(
            limits: .init(inFlightTimeout: 0.05)
        )

        let running = Task {
            try? await coalescer.run(key: "slow") {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return .success(Data())
                } catch {
                    return .failure(.failed)
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        let metrics = await coalescer.snapshotMetrics()
        _ = await running.result

        #expect(metrics.timedOutEntries == 1)
    }

    @Test
    func retryUsesInjectedClockAndRandomGenerator() async throws {
        let transport = FlakyNetworkTransport(
            remainingFailures: 2,
            failure: .httpStatus(code: 503, body: Data())
        )
        let clock = RecordingRetryClock()
        let policy = RetryPolicy(
            maxAttempts: 3,
            baseDelayNanoseconds: 10_000,
            maxDelayNanoseconds: 100_000,
            jitterRange: 1.0...1.0
        )
        let client = NetworkClient(
            transport: transport,
            retryPolicy: policy,
            retryClock: clock,
            retryRandomGenerator: FixedRetryRandom(value: 1.0)
        )

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry")!)
        _ = try await client.load(request: request, authScope: nil)

        #expect(await transport.calls() == 3)
        #expect(await clock.recordedSleeps() == [10_000, 20_000])
    }

    @Test
    func apiRequestBuilderEncodesJSONBody() throws {
        struct Body: Codable, Sendable {
            let value: String
        }

        let request = try APIRequest
            .builder(method: .post, url: URL(string: "https://example.com/builder")!)
            .header("Accept", "application/json")
            .jsonBody(Body(value: "ok"))
            .build()

        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.body != nil)
    }
}
