import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-SSE-3 (client streaming), FR-SSE-4 (reconnect), FR-SSE-5 (Last-Event-ID).

private final class StubSSETransport: ServerSentEventTransport, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "StubSSETransport.state")
    private let attempts: [[SSEParsedElement]]
    private let errors: [(any Error)?]
    private var callCount = 0
    private var recordedHeaders: [[String: String]] = []

    init(attempts: [[SSEParsedElement]], errors: [(any Error)?] = []) {
        self.attempts = attempts
        self.errors = errors
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func serverSentEventElements(
        _ request: APIRequest,
        authScope: String?
    ) -> AsyncThrowingStream<SSEParsedElement, any Error> {
        let index = stateQueue.sync { () -> Int in
            let current = callCount
            callCount += 1
            recordedHeaders.append(request.headers)
            return current
        }
        let elements = index < attempts.count ? attempts[index] : []
        let error = index < errors.count ? errors[index] : nil
        return AsyncThrowingStream { continuation in
            for element in elements {
                continuation.yield(element)
            }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }

    func headers(atAttempt index: Int) -> [String: String]? {
        stateQueue.sync { index < recordedHeaders.count ? recordedHeaders[index] : nil }
    }

    func attemptCount() -> Int {
        stateQueue.sync { callCount }
    }
}

/// Drains a stream to its natural end (completion or thrown error) rather than breaking out
/// early, so the underlying reconnect loop's lifetime is fully deterministic in tests: nothing
/// depends on ARC releasing the stream/iterator promptly after an early `break`.
private func drain(
    _ stream: AsyncThrowingStream<ServerSentEvent, any Error>
) async -> (events: [ServerSentEvent], error: (any Error)?) {
    var events: [ServerSentEvent] = []
    do {
        for try await event in stream {
            events.append(event)
        }
        return (events, nil)
    } catch {
        return (events, error)
    }
}

private func sseError(_ error: (any Error)?) -> ServerSentEventError? {
    guard case .transport(let underlying) = error as? NetworkError else { return nil }
    return underlying as? ServerSentEventError
}

@Suite
struct ServerSentEventsTests {
    @Test
    func yieldsEventsFromSingleAttemptWhenReconnectDisabled() async throws {
        let transport = StubSSETransport(
            attempts: [
                [.event(ServerSentEvent(id: "1", event: "message", data: "hello"))]
            ]
        )
        let client = NetworkClient(transport: transport)
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil,
            reconnectPolicy: .disabled
        )

        var received: [ServerSentEvent] = []
        for try await event in stream {
            received.append(event)
        }
        #expect(received == [ServerSentEvent(id: "1", event: "message", data: "hello")])
        #expect(transport.attemptCount() == 1)
    }

    @Test
    func reconnectsAfterStreamEndsAndResendsLastEventID() async throws {
        // Both configured attempts end cleanly with one event each; a third (unconfigured)
        // attempt is an empty clean stream that counts against the attempt budget, so
        // maxAttempts: 1 makes the whole reconnect loop terminate deterministically on its own.
        let clock = RecordingRetryClock()
        let transport = StubSSETransport(
            attempts: [
                [.event(ServerSentEvent(id: "1", event: "message", data: "first"))],
                [.event(ServerSentEvent(id: "2", event: "message", data: "second"))],
            ]
        )
        let client = NetworkClient(transport: transport, retryClock: clock)
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil,
            reconnectPolicy: .init(maxAttempts: 1)
        )

        let result = await drain(stream)
        #expect(result.events.map(\.data) == ["first", "second"])
        #expect(sseError(result.error) == .reconnectAttemptsExhausted)
        #expect(transport.attemptCount() == 3)
        #expect(transport.headers(atAttempt: 0)?["Last-Event-ID"] == nil)
        #expect(transport.headers(atAttempt: 1)?["Last-Event-ID"] == "1")
        #expect(transport.headers(atAttempt: 2)?["Last-Event-ID"] == "2")
    }

    @Test
    func reconnectsAfterTransportError() async throws {
        let clock = RecordingRetryClock()
        let transport = StubSSETransport(
            attempts: [
                [],
                [.event(ServerSentEvent(id: nil, event: "message", data: "recovered"))],
            ],
            errors: [NetworkError.transport(underlying: DummyError.boom), nil]
        )
        let client = NetworkClient(transport: transport, retryClock: clock)
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil,
            reconnectPolicy: .init(maxAttempts: 1)
        )

        let result = await drain(stream)
        #expect(result.events == [ServerSentEvent(id: nil, event: "message", data: "recovered")])
        // attempt 1 errors (budget: 1/1), attempt 2 recovers and resets the budget to 0/1, then
        // an unconfigured empty-but-clean attempt 3 pushes the budget past 1 and ends the loop.
        #expect(transport.attemptCount() == 3)
    }

    @Test
    func retryIntervalUpdateFromStreamDrivesReconnectDelay() async throws {
        let clock = RecordingRetryClock()
        let transport = StubSSETransport(
            attempts: [
                [
                    .retryIntervalUpdate(1_500),
                    .event(ServerSentEvent(id: nil, event: "message", data: "first")),
                ],
                [.event(ServerSentEvent(id: nil, event: "message", data: "second"))],
            ]
        )
        let client = NetworkClient(transport: transport, retryClock: clock)
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil,
            reconnectPolicy: .init(maxAttempts: 1)
        )

        _ = await drain(stream)
        let sleeps = await clock.recordedSleeps()
        // Every reconnect after the retry: field arrived (including the final, budget-exhausting
        // one) uses the server-provided 1.5s delay rather than the 3s default.
        #expect(sleeps == [1_500_000_000, 1_500_000_000])
    }

    @Test
    func failsImmediatelyWhenReconnectDisabledAndTransportErrors() async throws {
        let transport = StubSSETransport(
            attempts: [[]],
            errors: [NetworkError.transport(underlying: DummyError.boom)]
        )
        let client = NetworkClient(transport: transport)
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil,
            reconnectPolicy: .disabled
        )

        await #expect(throws: (any Error).self) {
            for try await _ in stream {}
        }
        #expect(transport.attemptCount() == 1)
    }

    @Test
    func failsWithReconnectAttemptsExhaustedAfterMaxAttempts() async throws {
        let clock = RecordingRetryClock()
        let transport = StubSSETransport(
            attempts: [[], [], []],
            errors: [
                NetworkError.transport(underlying: DummyError.boom),
                NetworkError.transport(underlying: DummyError.boom),
                NetworkError.transport(underlying: DummyError.boom),
            ]
        )
        let client = NetworkClient(transport: transport, retryClock: clock)
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil,
            reconnectPolicy: .init(maxAttempts: 2)
        )

        let result = await drain(stream)
        #expect(sseError(result.error) == .reconnectAttemptsExhausted)
        #expect(transport.attemptCount() == 3)
    }

    @Test
    func failsImmediatelyWhenTransportDoesNotSupportSSE() async throws {
        let client = NetworkClient(transport: GenericThrowingTransport(error: DummyError.boom))
        let stream = client.loadServerSentEvents(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
            authScope: nil
        )

        let result = await drain(stream)
        #expect(sseError(result.error) == .transportUnsupported)
    }

    @Test
    func cancellationStopsReconnectLoop() async throws {
        // The stream is created and fully consumed inside its own cancellable Task, rather than
        // stored in a `let` that survives past the point of cancellation: AsyncThrowingStream's
        // onTermination fires on iterator deinitialization, and holding an outer reference to
        // the stream would keep the producer alive regardless of this task's cancellation.
        let clock = RecordingRetryClock()
        let transport = StubSSETransport(
            attempts: [
                [.event(ServerSentEvent(id: "1", event: "message", data: "first"))]
            ]
        )
        let client = NetworkClient(transport: transport, retryClock: clock)

        let task = Task<Void, Never> {
            let stream = client.loadServerSentEvents(
                request: APIRequest(method: .get, url: URL(string: "https://example.com/events")!),
                authScope: nil
            )
            do {
                for try await _ in stream {}
            } catch {}
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        _ = await task.value

        let attemptsRightAfterCancel = transport.attemptCount()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(transport.attemptCount() == attemptsRightAfterCancel)
    }
}
