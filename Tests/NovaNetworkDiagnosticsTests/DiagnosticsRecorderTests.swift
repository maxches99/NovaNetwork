import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkDiagnostics

// Requirements: FR-1 (one record per request), FR-2 (attempts and retry reasons), FR-3 (coalescing
// and cancellation), FR-4 (cache outcomes), FR-5 (bounded storage), FR-6 (body capture), AR-1.
// Tests: T-1.1…T-1.5, T-2.2…T-2.5, T-8.1.

/// A fixed clock, so records are deterministic instead of merely plausible.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            return current
        }
    }

    func advance(milliseconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(milliseconds / 1000)
    }
}

func sampleRequest(
    _ path: String = "/users/1",
    method: URLMethod = .get,
    headers: [String: String] = [:],
    body: Data? = nil
) -> APIRequest {
    APIRequest(
        method: method,
        url: URL(string: "https://api.example.com\(path)")!,
        headers: headers,
        body: body
    )
}

func startContext(key: String = "k", attempt: Int = 1, request: APIRequest = sampleRequest()) -> TelemetryRequestContext {
    TelemetryRequestContext(key: key, attempt: attempt, coalescingMode: .default, request: request)
}

func endContext(
    key: String = "k",
    attempt: Int = 1,
    request: APIRequest = sampleRequest(),
    status: Int? = 200,
    body: Data = Data(#"{"ok":true}"#.utf8),
    headers: [String: String] = ["Content-Type": "application/json"],
    error: NetworkError? = nil,
    duration: Double = 42
) -> TelemetryResponseContext {
    TelemetryResponseContext(
        request: TelemetryRequestContext(key: key, attempt: attempt, coalescingMode: .default, request: request),
        response: status.map { NetworkResponse(statusCode: $0, headers: headers, body: body) },
        error: error,
        durationMilliseconds: duration
    )
}

@Suite
struct DiagnosticsRecorderTests {
    @Test
    func aCompletedRequestBecomesOneReadableRecord() async {
        let clock = TestClock()
        let recorder = DiagnosticsRecorder(now: clock.now)

        await recorder.recordStart(startContext())
        clock.advance(milliseconds: 42)
        await recorder.recordEnd(endContext())

        let records = await recorder.snapshot()
        #expect(records.count == 1)
        #expect(records[0].method == "GET")
        #expect(records[0].url == "https://api.example.com/users/1")
        #expect(records[0].outcome == .completed(status: 200))
        #expect(abs((records[0].durationMilliseconds ?? 0) - 42) < 0.01)
        #expect(records[0].shortDescription == "GET /users/1 — 200 in 42 ms")
    }

    @Test
    func retriesAppearAsAttemptsCarryingTheirDelayAndReason() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordStart(startContext(attempt: 1))
        await recorder.recordRetryScheduled(TelemetryRetryContext(
            key: "k", attempt: 1, nextAttempt: 2, delayMilliseconds: 200, reason: "server-error", request: sampleRequest()
        ))
        await recorder.recordStart(startContext(attempt: 2))
        await recorder.recordRetryScheduled(TelemetryRetryContext(
            key: "k", attempt: 2, nextAttempt: 3, delayMilliseconds: 400, reason: "timeout", request: sampleRequest()
        ))
        await recorder.recordStart(startContext(attempt: 3))
        await recorder.recordEnd(endContext(attempt: 3))

        let record = try #require(await recorder.snapshot().first)
        #expect(record.attemptCount == 3)
        #expect(record.wasRetried)
        #expect(record.attempts.map(\.number) == [1, 2, 3])
        #expect(record.attempts[1].retryDelayMilliseconds == 200)
        #expect(record.attempts[1].retryReason == "server-error")
        #expect(record.attempts[2].retryReason == "timeout")
        #expect(record.attempts[0].retryReason == nil)
    }

    @Test
    func aCoalescedRequestIsMarkedAndACancelledOneRecordsItsReason() async {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordStart(startContext(key: "shared"))
        await recorder.recordCoalescerEvent(TelemetryCoalescerContext(type: .coalesced, key: "shared", waiterCount: 2))
        await recorder.recordStart(startContext(key: "cancelled-key"))
        await recorder.recordCancellation(TelemetryCancellationContext(
            key: "cancelled-key", attempt: 1, reason: "caller-cancelled", request: sampleRequest()
        ))

        let records = await recorder.snapshot()
        #expect(records.first(where: { $0.key == "shared" })?.wasCoalesced == true)
        #expect(records.first(where: { $0.key == "cancelled-key" })?.outcome == .cancelled(reason: "caller-cancelled"))
    }

    @Test
    func cacheEventsAnnotateTheRecordForTheirKey() async {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordStart(startContext(key: "cached"))
        await recorder.record(.cacheHit(key: "cached", isStale: true, ageMilliseconds: 1_500))
        await recorder.recordEnd(endContext(key: "cached"))

        await recorder.recordStart(startContext(key: "fresh"))
        await recorder.record(.cacheMiss(key: "fresh"))

        let records = await recorder.snapshot()
        #expect(records.first(where: { $0.key == "cached" })?.cacheOutcome == .hit(isStale: true, ageMilliseconds: 1_500))
        #expect(records.first(where: { $0.key == "cached" })?.cacheOutcome?.servedFromCache == true)
        #expect(records.first(where: { $0.key == "fresh" })?.cacheOutcome == .miss)
        #expect(records.first(where: { $0.key == "fresh" })?.cacheOutcome?.servedFromCache == false)
    }

    @Test
    func anEndWithoutAStartStillProducesAUsableRecord() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        // Hooks are delivered asynchronously, so this ordering is possible under load. Losing the
        // request entirely would be the worse answer.
        await recorder.recordEnd(endContext(status: 503, error: nil))

        let record = try #require(await recorder.snapshot().first)
        #expect(record.startedAt == nil)
        #expect(record.outcome == .completed(status: 503))
        #expect(record.durationMilliseconds == 42)
    }

    @Test
    func aFailureRecordsTheReasonTheClientReported() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordStart(startContext())
        await recorder.recordEnd(endContext(status: nil, error: .cancelled))

        let record = try #require(await recorder.snapshot().first)
        guard case let .failed(reason, status) = record.outcome else {
            Issue.record("Expected a failed outcome, got \(record.outcome)")
            return
        }
        #expect(status == nil)
        #expect(!reason.isEmpty)
    }

    @Test
    func storageIsBoundedAndDropsTheOldestFirst() async {
        let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 10), now: TestClock().now)

        for index in 0..<25 {
            await recorder.recordStart(startContext(key: "k\(index)", request: sampleRequest("/items/\(index)")))
        }

        let records = await recorder.snapshot()
        #expect(records.count == 10)
        #expect(records.first?.key == "k15")
        #expect(records.last?.key == "k24")
    }

    @Test
    func aCapacityOfZeroRetainsNothing() async {
        let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 0), now: TestClock().now)

        await recorder.recordStart(startContext())
        await recorder.recordEnd(endContext())

        #expect(await recorder.snapshot().isEmpty)
        #expect(await recorder.summary().requestCount == 0)
    }

    @Test(arguments: [
        (BodyCapturePolicy.none, false, false),
        (BodyCapturePolicy.sizeOnly, false, false),
        (BodyCapturePolicy.bounded(maxBytes: 8), true, true),
    ])
    func bodyCaptureFollowsItsPolicy(policy: BodyCapturePolicy, capturesBytes: Bool, truncates: Bool) async throws {
        let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(bodyCapture: policy), now: TestClock().now)
        let body = Data(String(repeating: "a", count: 100).utf8)

        await recorder.recordStart(startContext(request: sampleRequest(method: .post, body: body)))

        let record = try #require(await recorder.snapshot().first)
        if policy == .none {
            #expect(record.requestBody == nil)
        } else {
            #expect(record.requestBody?.byteCount == 100)
            #expect((record.requestBody?.captured != nil) == capturesBytes)
            #expect(record.requestBody?.isTruncated == truncates)
            if truncates {
                #expect(record.requestBody?.captured?.count == 8)
            }
        }
    }

    @Test
    func concurrentRecordingKeepsEveryRequest() async {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    await recorder.recordStart(startContext(key: "k\(index)"))
                    await recorder.recordEnd(endContext(key: "k\(index)"))
                }
            }
        }

        let records = await recorder.snapshot()
        #expect(records.count == 50)
        #expect(records.filter(\.outcome.isFinished).count == 50)
    }

    @Test
    func clearingRemovesEverything() async {
        let recorder = DiagnosticsRecorder(now: TestClock().now)
        await recorder.recordStart(startContext())

        await recorder.clear()

        #expect(await recorder.snapshot().isEmpty)
    }
}

// MARK: - T-8.1 through a real client

@Suite
struct DiagnosticsClientIntegrationTests {
    /// Answers every request, so a real client run produces real telemetry.
    private actor EchoTransport: NetworkTransport {
        private(set) var callCount = 0

        func execute(_ request: APIRequest) async throws -> NetworkResponse {
            callCount += 1
            return NetworkResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"ok":true}"#.utf8)
            )
        }

        func calls() -> Int { callCount }
    }

    @Test
    func installingARecorderDoesNotChangeWhatTheClientDoes() async throws {
        let plainTransport = EchoTransport()
        let observedTransport = EchoTransport()
        let request = sampleRequest()

        let plain = try await NetworkClient(transport: plainTransport).load(request: request, authScope: nil)

        let recorder = DiagnosticsRecorder()
        var configuration = NetworkClientConfiguration()
        configuration.transport = observedTransport
        configuration.telemetryHooks = recorder.hooks
        let observed = try await NetworkClient(configuration: configuration).load(request: request, authScope: nil)

        #expect(plain == observed)
        #expect(await plainTransport.calls() == observedTransport.calls())
    }

    @Test
    func realTrafficLandsInTheRecorder() async throws {
        let recorder = DiagnosticsRecorder()
        var configuration = NetworkClientConfiguration()
        configuration.transport = EchoTransport()
        configuration.telemetryHooks = recorder.hooks
        let client = NetworkClient(configuration: configuration)

        _ = try await client.load(request: sampleRequest(), authScope: nil)

        // Hooks hand work to the recorder asynchronously, so wait for the record rather than
        // assuming it has landed.
        try await waitUntil("the request is recorded") { await recorder.snapshot().isEmpty == false }

        let record = try #require(await recorder.snapshot().first)
        #expect(record.method == "GET")
        #expect(record.outcome == .completed(status: 200))
    }
}

/// Polls until `condition` holds or the deadline passes.
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting until \(description)", sourceLocation: sourceLocation)
}
