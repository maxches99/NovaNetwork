import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkClientTestSupport

// Requirements: FR-TEST-5 (telemetry recording DSL).

@Suite
struct TelemetryRecorderTests {
    @Test
    func recordsRequestStartAndEndForASuccessfulLoad() async throws {
        let recorder = TelemetryRecorder()
        let transport = MockTransport(result: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))))
        let client = NetworkClient(transport: transport, telemetryHooks: await recorder.makeHooks())

        _ = try await client.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
            authScope: "user:1"
        )

        await waitUntil { await recorder.requestEndCount() == 1 }
        #expect(await recorder.requestStartCount() == 1)
        #expect(await recorder.requestEndCount() == 1)
    }

    @Test
    func recordsCoalescerEventsForConcurrentIdenticalRequests() async throws {
        let recorder = TelemetryRecorder()
        let transport = MockTransport(
            delayNanoseconds: 50_000_000,
            result: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8)))
        )
        let client = NetworkClient(transport: transport, telemetryHooks: await recorder.makeHooks())
        let request = APIRequest(method: .get, url: URL(string: "https://example.com")!)

        async let first = client.load(request: request, authScope: "user:1")
        async let second = client.load(request: request, authScope: "user:1")
        _ = try await (first, second)

        await waitUntil { await recorder.coalescerEventTypes().contains(.coalesced) }
        let types = await recorder.coalescerEventTypes()
        #expect(types.contains(.coalesced))
        #expect(await transport.calls == 1)
    }

    @Test
    func recordsRetryScheduledEventsForRetriableFailures() async throws {
        let recorder = TelemetryRecorder()
        let transport = ScriptedTransport(scripted: [
            .failure(.transport(underlying: URLError(.timedOut))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))),
        ])
        let clock = TestRetryClock()
        let client = NetworkClient(
            transport: transport,
            retryPolicy: RetryPolicy(maxAttempts: 2),
            retryClock: clock,
            telemetryHooks: await recorder.makeHooks()
        )

        _ = try await client.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
            authScope: nil
        )

        await waitUntil { await recorder.retryScheduledCount() == 1 }
        #expect(await recorder.retryScheduledCount() == 1)
    }
}
