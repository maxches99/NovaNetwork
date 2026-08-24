import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-CFG-1 (configuration struct), FR-CFG-2 (init(configuration:) parity).

private final class TelemetryStartRecorder: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "TelemetryStartRecorder.state")
    private var count = 0

    func increment() { stateQueue.sync { count += 1 } }
    func value() -> Int { stateQueue.sync { count } }
}

@Suite
struct NetworkClientConfigurationTests {
    @Test
    func addMiddlewareAppendsToExistingMiddlewaresWithoutReplacingThem() {
        var configuration = NetworkClientConfiguration()
        let first = NetworkMiddleware(beforeSend: { request, _ in request })
        let second = NetworkMiddleware(beforeSend: { request, _ in request })
        configuration.middlewares = [first]

        configuration.addMiddleware(second)

        #expect(configuration.middlewares.count == 2)
    }

    @Test
    func initFromConfigurationProducesAFunctioningClient() async throws {
        let transport = RequestRecordingTransport()
        var configuration = NetworkClientConfiguration()
        configuration.transport = transport

        let client = NetworkClient(configuration: configuration)
        let data = try await client.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/items")!),
            authScope: nil
        )

        #expect(data == Data("ok".utf8))
        #expect(await transport.snapshot() == ["/items"])
    }

    @Test
    func configurationInitRetriesExactlyLikeTheRawParameterInit() async throws {
        let retryPolicy = RetryPolicy(maxAttempts: 3)
        let clock = RecordingRetryClock()

        let rawTransport = SequenceThrowingTransport(remainingFailures: 2, error: URLError(.timedOut))
        let rawClient = NetworkClient(transport: rawTransport, retryPolicy: retryPolicy, retryClock: clock)
        _ = try await rawClient.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/a")!),
            authScope: nil
        )

        var configuration = NetworkClientConfiguration()
        let configTransport = SequenceThrowingTransport(remainingFailures: 2, error: URLError(.timedOut))
        configuration.transport = configTransport
        configuration.retryPolicy = retryPolicy
        configuration.retryClock = clock
        let configClient = NetworkClient(configuration: configuration)
        _ = try await configClient.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/a")!),
            authScope: nil
        )

        let rawCalls = await rawTransport.calls()
        let configCalls = await configTransport.calls()
        #expect(rawCalls == configCalls)
        #expect(configCalls == 3)
    }

    @Test
    func configurationMiddlewareIsAppliedBeforeSend() async throws {
        let transport = HeaderCapturingTransport()
        var configuration = NetworkClientConfiguration()
        configuration.transport = transport
        configuration.middlewares = [
            NetworkMiddleware(beforeSend: { request, _ in
                request.withMergedHeaders(["X-From-Config": "1"])
            })
        ]

        let client = NetworkClient(configuration: configuration)
        _ = try await client.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/items")!),
            authScope: nil
        )

        #expect(await transport.headers()["X-From-Config"] == "1")
    }

    @Test
    func configurationTelemetryHooksReceiveRequestLifecycleEvents() async throws {
        let recorder = TelemetryStartRecorder()
        var configuration = NetworkClientConfiguration()
        configuration.transport = RequestRecordingTransport()
        configuration.telemetryHooks = NetworkTelemetryHooks(
            onRequestStart: { _ in recorder.increment() }
        )

        let client = NetworkClient(configuration: configuration)
        _ = try await client.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/items")!),
            authScope: nil
        )

        #expect(recorder.value() == 1)
    }

    @Test
    func mutatingAConfigurationAfterBuildingAClientDoesNotAffectThatClient() async throws {
        var configuration = NetworkClientConfiguration()
        let firstTransport = RequestRecordingTransport()
        configuration.transport = firstTransport
        let firstClient = NetworkClient(configuration: configuration)

        // Value-type configuration: mutating it afterward must not reach into `firstClient`.
        let secondTransport = RequestRecordingTransport()
        configuration.transport = secondTransport
        _ = NetworkClient(configuration: configuration)

        _ = try await firstClient.load(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/items")!),
            authScope: nil
        )

        #expect(await firstTransport.snapshot() == ["/items"])
        #expect(await secondTransport.snapshot() == [])
    }
}
