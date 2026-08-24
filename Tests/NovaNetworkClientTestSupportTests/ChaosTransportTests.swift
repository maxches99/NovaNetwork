import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkClientTestSupport

// Requirements: FR-TEST-3 (chaos injection).

@Suite
struct ChaosTransportTests {
    @Test
    func passesThroughToTheWrappedTransportWhenFailureRateIsZero() async throws {
        let wrapped = MockTransport(result: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))))
        let chaos = ChaosTransport(
            wrapping: wrapped,
            policy: ChaosPolicy(failureRate: 0),
            randomGenerator: TestRetryRandom(value: 0.5)
        )

        let response = try await chaos.execute(APIRequest(method: .get, url: URL(string: "https://example.com")!))
        #expect(response.body == Data("ok".utf8))
        #expect(await wrapped.calls == 1)
    }

    @Test
    func injectsAFailureWhenTheRandomDrawIsBelowTheFailureRate() async throws {
        let wrapped = MockTransport(result: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data())))
        let chaos = ChaosTransport(
            wrapping: wrapped,
            policy: ChaosPolicy(failureRate: 1, failureFactory: { .transport(underlying: URLError(.timedOut)) }),
            randomGenerator: TestRetryRandom(value: 0.5)
        )

        await #expect(throws: (any Error).self) {
            _ = try await chaos.execute(APIRequest(method: .get, url: URL(string: "https://example.com")!))
        }
        #expect(await wrapped.calls == 0)
        let failures = await chaos.failureCount()
        #expect(failures == 1)
    }

    @Test
    func doesNotInjectAFailureWhenTheRandomDrawIsAboveTheFailureRate() async throws {
        let wrapped = MockTransport(result: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data())))
        let chaos = ChaosTransport(
            wrapping: wrapped,
            policy: ChaosPolicy(failureRate: 0.3),
            randomGenerator: TestRetryRandom(value: 0.9)
        )

        _ = try await chaos.execute(APIRequest(method: .get, url: URL(string: "https://example.com")!))
        let calls = await chaos.callCount()
        let failures = await chaos.failureCount()
        #expect(calls == 1)
        #expect(failures == 0)
    }

    @Test
    func callCountTracksEveryRequestRegardlessOfOutcome() async throws {
        let wrapped = MockTransport(result: .success(NetworkResponse(statusCode: 200, headers: [:], body: Data())))
        let chaos = ChaosTransport(
            wrapping: wrapped,
            policy: ChaosPolicy(failureRate: 1),
            randomGenerator: TestRetryRandom(value: 0)
        )

        _ = try? await chaos.execute(APIRequest(method: .get, url: URL(string: "https://example.com")!))
        _ = try? await chaos.execute(APIRequest(method: .get, url: URL(string: "https://example.com")!))

        let calls = await chaos.callCount()
        #expect(calls == 2)
    }
}
