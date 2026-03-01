import Foundation
import Testing
@testable import NovaNetworkClient

private actor MockWebSocketTransport: WebSocketTransport {
    private(set) var connected = false
    private(set) var connectCalls = 0
    private var connectResults: [Result<Void, Error>]
    private var receiveQueue: [Result<WebSocketMessage, Error>] = []
    private var pingResults: [Result<Void, Error>] = []
    private var sendResults: [Result<Void, Error>] = []
    private var sentMessages: [WebSocketMessage] = []

    init(connectResults: [Result<Void, Error>] = [.success(())]) {
        self.connectResults = connectResults
    }

    func connect(url: URL, headers: [String: String]) async throws {
        connectCalls += 1
        let result: Result<Void, Error>
        if connectResults.isEmpty {
            result = .success(())
        } else {
            result = connectResults.removeFirst()
        }
        switch result {
        case .success:
            connected = true
        case .failure(let error):
            throw error
        }
    }

    func receive() async throws -> WebSocketMessage {
        while receiveQueue.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
            if Task.isCancelled {
                throw CancellationError()
            }
        }

        let next = receiveQueue.removeFirst()
        switch next {
        case .success(let message):
            return message
        case .failure(let error):
            throw error
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard connected else {
            throw WebSocketError.disconnected
        }
        sentMessages.append(message)
        guard !sendResults.isEmpty else { return }
        let next = sendResults.removeFirst()
        switch next {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func ping() async throws {
        guard connected else {
            throw WebSocketError.disconnected
        }
        guard !pingResults.isEmpty else { return }
        let next = pingResults.removeFirst()
        switch next {
        case .success:
            return
        case .failure(let error):
            throw error
        }
    }

    func disconnect(reason: String?) async {
        connected = false
    }

    func enqueue(_ result: Result<WebSocketMessage, Error>) {
        receiveQueue.append(result)
    }

    func enqueuePing(_ result: Result<Void, Error>) {
        pingResults.append(result)
    }

    func enqueueSend(_ result: Result<Void, Error>) {
        sendResults.append(result)
    }

    func connectCount() -> Int {
        connectCalls
    }

    func snapshotSentMessages() -> [WebSocketMessage] {
        sentMessages
    }
}

private actor ImmediateRetryClock: RetryClock {
    func sleep(nanoseconds: UInt64) async throws {}
}

private actor CancellationRetryClock: RetryClock {
    func sleep(nanoseconds: UInt64) async throws {
        throw CancellationError()
    }
}

private struct WSFixedRetryRandom: RetryRandomGenerator {
    let value: Double

    func nextDouble(in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private final class MockURLSessionWebSocketTask: URLSessionWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var receiveResults: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var sendResults: [Result<Void, Error>] = []
    private var pingResults: [Error?] = []
    private(set) var sentMessages: [URLSessionWebSocketTask.Message] = []
    private(set) var cancelledReason: Data?

    func resume() {}

    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard let result = dequeueReceiveResult() else {
            throw WebSocketError.disconnected
        }
        switch result {
        case .success(let message):
            return message
        case .failure(let error):
            throw error
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let result = appendSentAndDequeueSendResult(message)
        if case .failure(let error) = result {
            throw error
        }
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        lock.lock()
        let next = pingResults.isEmpty ? nil : pingResults.removeFirst()
        lock.unlock()
        pongReceiveHandler(next)
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        cancelledReason = reason
        lock.unlock()
    }

    func enqueueReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        receiveResults.append(result)
        lock.unlock()
    }

    func enqueueSend(_ result: Result<Void, Error>) {
        lock.lock()
        sendResults.append(result)
        lock.unlock()
    }

    func enqueuePing(_ error: Error?) {
        lock.lock()
        pingResults.append(error)
        lock.unlock()
    }

    func snapshotSentMessages() -> [URLSessionWebSocketTask.Message] {
        lock.lock()
        let snapshot = sentMessages
        lock.unlock()
        return snapshot
    }

    private func dequeueReceiveResult() -> Result<URLSessionWebSocketTask.Message, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !receiveResults.isEmpty else { return nil }
        return receiveResults.removeFirst()
    }

    private func appendSentAndDequeueSendResult(_ message: URLSessionWebSocketTask.Message) -> Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        sentMessages.append(message)
        return sendResults.isEmpty ? .success(()) : sendResults.removeFirst()
    }
}

private final class URLRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        let snapshot = request
        lock.unlock()
        return snapshot
    }
}

private actor WebSocketTelemetryRecorder {
    private(set) var events: [TelemetryWebSocketContext] = []

    func append(_ event: TelemetryWebSocketContext) {
        events.append(event)
    }

    func types() -> [TelemetryWebSocketEventType] {
        events.map(\.type)
    }

    func snapshot() -> [TelemetryWebSocketContext] {
        events
    }
}

@Suite(.serialized)
struct WebSocketClientTests {
    @Test
    func connectEmitsExpectedStateTransitions() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: transport
        )

        let states = await client.connectionStates()
        let consumer = Task { () -> [WebSocketConnectionState] in
            var iterator = states.makeAsyncIterator()
            var received: [WebSocketConnectionState] = []
            while received.count < 3, let next = await iterator.next() {
                received.append(next)
            }
            return received
        }

        try await client.connect()
        let received = await consumer.value

        #expect(received.count == 3)
        #expect(received[0] == .disconnected)

        if case .connecting(let attempt) = received[1] {
            #expect(attempt == 1)
        } else {
            Issue.record("Expected .connecting state at index 1")
        }

        if case .connected = received[2] {
            // expected
        } else {
            Issue.record("Expected .connected state at index 2")
        }
    }

    @Test
    func sendWhenDisconnectedThrowsTypedError() async {
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: MockWebSocketTransport()
        )

        do {
            try await client.send(.text("hello"))
            Issue.record("Expected send to throw when disconnected")
        } catch let error as WebSocketError {
            #expect(error == .disconnected)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func messagesStreamYieldsInboundMessage() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: transport
        )

        let stream = await client.messages()
        let consumer = Task { () -> WebSocketMessage? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await client.connect()
        await transport.enqueue(.success(.text("hello")))

        let next = try await consumer.value
        #expect(next == .text("hello"))
    }

    @Test
    func disconnectFinishesMessageStream() async throws {
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: MockWebSocketTransport()
        )
        let stream = await client.messages()
        let consumer = Task { () -> WebSocketMessage? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await client.connect()
        await client.disconnect(reason: "done")

        let first = try await consumer.value
        #expect(first == nil)
    }

    @Test
    func receiveFailureTriggersReconnectAndRecovers() async throws {
        let transport = MockWebSocketTransport(
            connectResults: [.success(()), .success(())]
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 1,
                    baseDelayNanoseconds: 0,
                    maxDelayNanoseconds: 0,
                    jitterRange: nil
                ),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryRandomGenerator: WSFixedRetryRandom(value: 1)
        )

        let states = await client.connectionStates()
        let stateConsumer = Task { () -> [WebSocketConnectionState] in
            var iterator = states.makeAsyncIterator()
            var received: [WebSocketConnectionState] = []
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, let next = await iterator.next() {
                received.append(next)
                if received.count >= 6, case .connected = next {
                    break
                }
            }
            return received
        }

        let stream = await client.messages()
        let messageConsumer = Task { () -> WebSocketMessage? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.transport(description: "socket dropped")))
        await transport.enqueue(.success(.text("after-reconnect")))

        let message = try await messageConsumer.value
        let received = await stateConsumer.value

        #expect(message == .text("after-reconnect"))
        #expect(received.first == .disconnected)
        #expect(received.contains { if case .connecting = $0 { return true }; return false })
        #expect(received.contains { if case .unhealthy = $0 { return true }; return false })
        #expect(received.contains { if case .reconnecting(let attempt, _) = $0 { return attempt == 1 }; return false })
        #expect(received.last.map { if case .connected = $0 { return true }; return false } == true)

        #expect(await transport.connectCount() == 2)
    }

    @Test
    func reconnectExhaustionTransitionsToFailed() async throws {
        let transport = MockWebSocketTransport(
            connectResults: [
                .success(()),
                .failure(WebSocketError.transport(description: "reconnect-1")),
                .failure(WebSocketError.transport(description: "reconnect-2"))
            ]
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 2,
                    baseDelayNanoseconds: 0,
                    maxDelayNanoseconds: 0,
                    jitterRange: nil
                ),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock(),
            retryRandomGenerator: WSFixedRetryRandom(value: 1)
        )

        let states = await client.connectionStates()
        let consumer = Task { () -> [WebSocketConnectionState] in
            var iterator = states.makeAsyncIterator()
            var received: [WebSocketConnectionState] = []
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, let next = await iterator.next() {
                received.append(next)
                if case .failed = next {
                    break
                }
            }
            return received
        }

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.transport(description: "socket dropped")))

        let received = await consumer.value
        guard let final = received.last else {
            Issue.record("Expected final state")
            return
        }

        if case .failed(let error) = final {
            #expect(error == .reconnectExhausted)
        } else {
            Issue.record("Expected final .failed(.reconnectExhausted)")
        }
    }

    @Test
    func heartbeatTimeoutTriggersReconnectTransition() async throws {
        let transport = MockWebSocketTransport(
            connectResults: [.success(()), .success(())]
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 1,
                    baseDelayNanoseconds: 0,
                    maxDelayNanoseconds: 0,
                    jitterRange: nil
                ),
                heartbeatPolicy: .init(
                    intervalNanoseconds: 5_000_000,
                    timeoutNanoseconds: 1_000_000
                )
            ),
            transport: transport
        )

        let states = await client.connectionStates()
        let consumer = Task { () -> [WebSocketConnectionState] in
            var iterator = states.makeAsyncIterator()
            var received: [WebSocketConnectionState] = []
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, let next = await iterator.next() {
                received.append(next)
                if case .reconnecting = next {
                    break
                }
            }
            return received
        }

        try await client.connect()
        await transport.enqueuePing(.failure(WebSocketError.timeout))

        let received = await consumer.value
        #expect(received.contains {
            if case .reconnecting = $0 { return true }
            return false
        })
    }

    @Test
    func telemetryEmitsReconnectAttemptAndSuccess() async throws {
        let transport = MockWebSocketTransport(connectResults: [.success(()), .success(())])
        let recorder = WebSocketTelemetryRecorder()
        let hooks = NetworkTelemetryHooks(
            onWebSocketEvent: { context in
                Task { await recorder.append(context) }
            }
        )

        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 1,
                    baseDelayNanoseconds: 0,
                    maxDelayNanoseconds: 0,
                    jitterRange: nil
                ),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock(),
            retryRandomGenerator: WSFixedRetryRandom(value: 1),
            telemetryHooks: hooks
        )

        let stream = await client.messages()
        let waiter = Task { () -> WebSocketMessage? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.transport(description: "drop")))
        await transport.enqueue(.success(.text("ok")))
        let message = try await waiter.value
        #expect(message == .text("ok"))
        try await client.send(.text("client-message"))

        try? await Task.sleep(nanoseconds: 20_000_000)
        let events = await recorder.snapshot()
        let types = events.map(\.type)
        #expect(types.contains(.connectStarted))
        #expect(types.contains(.connectSuccess))
        #expect(types.contains(.reconnectAttempt))
        #expect(types.contains(.reconnectSuccess))
        #expect(types.contains(.messageReceived))
        #expect(types.contains(.messageSent))

        let reconnectAttempt = events.first { $0.type == .reconnectAttempt }
        #expect(reconnectAttempt?.attempt == 1)
        #expect((reconnectAttempt?.error ?? "").range(of: "transport") != nil)

        let messageReceived = events.first { $0.type == .messageReceived }
        #expect(messageReceived?.messageKind == "text")

        let messageSent = events.first { $0.type == .messageSent }
        #expect(messageSent?.messageKind == "text")
    }

    @Test
    func telemetryEmitsReconnectExhaustedOnTerminalReconnectFailure() async throws {
        let transport = MockWebSocketTransport(
            connectResults: [
                .success(()),
                .failure(WebSocketError.transport(description: "reconnect-fail"))
            ]
        )
        let recorder = WebSocketTelemetryRecorder()
        let hooks = NetworkTelemetryHooks(
            onWebSocketEvent: { context in
                Task { await recorder.append(context) }
            }
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 1,
                    baseDelayNanoseconds: 0,
                    maxDelayNanoseconds: 0,
                    jitterRange: nil
                ),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock(),
            retryRandomGenerator: WSFixedRetryRandom(value: 1),
            telemetryHooks: hooks
        )

        let states = await client.connectionStates()
        let stateWaiter = Task { () -> WebSocketConnectionState? in
            var iterator = states.makeAsyncIterator()
            var latest: WebSocketConnectionState?
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline, let next = await iterator.next() {
                latest = next
                if case .failed = next {
                    return next
                }
            }
            return latest
        }

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.transport(description: "drop")))
        let terminal = await stateWaiter.value
        if case .failed(let error)? = terminal {
            #expect(error == .reconnectExhausted)
        } else {
            Issue.record("Expected terminal reconnect exhaustion failure")
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        let events = await recorder.snapshot()
        let types = events.map(\.type)
        #expect(types.contains(.reconnectAttempt))
        #expect(types.contains(.reconnectExhausted))

        let reconnectAttempt = events.first { $0.type == .reconnectAttempt }
        #expect(reconnectAttempt?.attempt == 1)
        #expect((reconnectAttempt?.error ?? "").range(of: "transport") != nil)

        let connectFailed = events.first { $0.type == .connectFailed }
        #expect((connectFailed?.error ?? "").range(of: "reconnectExhausted") != nil)
    }

    @Test
    func connectMapsAuthAndTimeoutAndCancellationErrors() async {
        let authClient = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: MockWebSocketTransport(connectResults: [.failure(URLError(.userAuthenticationRequired))])
        )
        do {
            try await authClient.connect()
            Issue.record("Expected auth connect failure.")
        } catch let error as WebSocketError {
            if case .auth = error {} else {
                Issue.record("Expected auth error, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        let timeoutClient = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: MockWebSocketTransport(connectResults: [.failure(URLError(.timedOut))])
        )
        do {
            try await timeoutClient.connect()
            Issue.record("Expected timeout connect failure.")
        } catch let error as WebSocketError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        let cancelledClient = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: MockWebSocketTransport(connectResults: [.failure(CancellationError())])
        )
        do {
            try await cancelledClient.connect()
            Issue.record("Expected cancelled connect failure.")
        } catch let error as WebSocketError {
            #expect(error == .cancelled)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test
    func sendMapsTransportErrorsAndEmitsBinaryTelemetryKind() async throws {
        let recorder = WebSocketTelemetryRecorder()
        let hooks = NetworkTelemetryHooks(
            onWebSocketEvent: { context in
                Task { await recorder.append(context) }
            }
        )
        let transport = MockWebSocketTransport()
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: transport,
            telemetryHooks: hooks
        )
        try await client.connect()

        await transport.enqueueSend(.failure(URLError(.badServerResponse)))
        do {
            try await client.send(.binary(Data([1, 2, 3])))
            Issue.record("Expected send to fail with mapped transport error.")
        } catch let error as WebSocketError {
            if case .transport = error {} else {
                Issue.record("Expected transport error, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        try await client.send(.binary(Data([4, 5, 6])))
        try? await Task.sleep(nanoseconds: 20_000_000)
        let sentBinary = await recorder.snapshot().first {
            $0.type == .messageSent && $0.messageKind == "binary"
        }
        #expect(sentBinary != nil)
    }

    @Test
    func nonRetriableReceiveFailureTransitionsToFailedAndStreamThrows() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(maxAttempts: 2),
                heartbeatPolicy: .disabled
            ),
            transport: transport
        )
        let stream = await client.messages()
        let waiter = Task { () -> WebSocketMessage? in
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }

        let states = await client.connectionStates()
        let terminal = Task { () -> WebSocketConnectionState? in
            var iterator = states.makeAsyncIterator()
            while let next = await iterator.next() {
                if case .failed = next { return next }
            }
            return nil
        }

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.protocolViolation(description: "bad frame")))

        do {
            _ = try await waiter.value
            Issue.record("Expected stream failure.")
        } catch let error as WebSocketError {
            if case .protocolViolation = error {} else {
                Issue.record("Expected protocol violation, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error \(error)")
        }

        if case .failed(let error)? = await terminal.value {
            if case .protocolViolation = error {} else {
                Issue.record("Expected protocol violation state, got \(error)")
            }
        } else {
            Issue.record("Expected terminal failed state.")
        }
    }

    @Test
    func reconnectLoopHandlesCancellationFromClock() async throws {
        let transport = MockWebSocketTransport(connectResults: [.success(())])
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(maxAttempts: 3),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: CancellationRetryClock(),
            retryRandomGenerator: WSFixedRetryRandom(value: 1)
        )

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.transport(description: "drop")))
        try? await Task.sleep(nanoseconds: 30_000_000)
        await client.disconnect(reason: "cleanup")
    }

    @Test
    func reconnectFailureWithNonRetriableErrorFailsImmediately() async throws {
        let transport = MockWebSocketTransport(
            connectResults: [
                .success(()),
                .failure(WebSocketError.auth(description: "token expired"))
            ]
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(maxAttempts: 3, jitterRange: 0.9...1.1),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock(),
            retryRandomGenerator: WSFixedRetryRandom(value: 1)
        )

        let states = await client.connectionStates()
        let waiter = Task { () -> WebSocketConnectionState? in
            var iterator = states.makeAsyncIterator()
            while let next = await iterator.next() {
                if case .failed = next { return next }
            }
            return nil
        }

        try await client.connect()
        await transport.enqueue(.failure(WebSocketError.transport(description: "drop")))
        if case .failed(let error)? = await waiter.value {
            if case .auth = error {} else {
                Issue.record("Expected non-retriable auth failure, got \(error)")
            }
        } else {
            Issue.record("Expected failed terminal state.")
        }
    }

    @Test
    func connectReturnsWhenAlreadyConnected() async throws {
        let transport = MockWebSocketTransport(connectResults: [.success(())])
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            transport: transport
        )

        try await client.connect()
        try await client.connect()
        #expect(await transport.connectCount() == 1)
    }

    @Test
    func forceReconnectPerformsImmediateReconnectAttempt() async throws {
        let transport = MockWebSocketTransport(connectResults: [.success(()), .success(())])
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 2,
                    baseDelayNanoseconds: 1_000_000_000,
                    maxDelayNanoseconds: 1_000_000_000,
                    jitterRange: nil
                ),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock()
        )

        let states = await client.connectionStates()
        let consumer = Task { () -> [WebSocketConnectionState] in
            var iterator = states.makeAsyncIterator()
            var received: [WebSocketConnectionState] = []
            while received.count < 5, let next = await iterator.next() {
                received.append(next)
            }
            return received
        }

        try await client.connect()
        await client.forceReconnect(reason: "manual")
        let received = await consumer.value

        #expect(await transport.connectCount() == 2)
        #expect(await client.connectionHealth() == .healthy)
        if case .reconnecting(let attempt, let delay) = received[3] {
            #expect(attempt == 1)
            #expect(delay == 0)
        } else {
            Issue.record("Expected reconnecting state after forceReconnect.")
        }
    }

    @Test
    func heartbeatTimeoutEmitsUnhealthyStateAndHealthStatus() async throws {
        let transport = MockWebSocketTransport(connectResults: [.success(())])
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .disabled,
                heartbeatPolicy: .init(
                    intervalNanoseconds: 5_000_000,
                    timeoutNanoseconds: 1_000_000
                )
            ),
            transport: transport
        )

        let states = await client.connectionStates()
        let consumer = Task { () -> [WebSocketConnectionState] in
            var iterator = states.makeAsyncIterator()
            var received: [WebSocketConnectionState] = []
            let deadline = Date().addingTimeInterval(1.0)
            while Date() < deadline, let next = await iterator.next() {
                received.append(next)
                if case .failed = next {
                    break
                }
            }
            return received
        }

        try await client.connect()
        await transport.enqueuePing(.failure(WebSocketError.timeout))
        let received = await consumer.value

        #expect(received.contains {
            if case .unhealthy(.timeout) = $0 { return true }
            return false
        })
        #expect(await client.connectionHealth() == .unhealthy(reason: "timeout"))
    }

    @Test
    func sendWithAckCompletesWhenAckFrameArrives() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                heartbeatPolicy: .disabled
            ),
            transport: transport
        )

        try await client.connect()
        let sendTask = Task {
            try await client.send(
                .text("{\"type\":\"event\"}"),
                options: .init(requiresAck: true, messageID: "msg-1", ackTimeoutNanoseconds: 1_000_000_000)
            )
        }

        await transport.enqueue(.success(.text("{\"type\":\"ack\",\"messageId\":\"msg-1\"}")))
        try await sendTask.value
    }

    @Test
    func sendWithAckTimeoutThrowsTypedErrorAndEmitsTelemetry() async throws {
        let transport = MockWebSocketTransport()
        let recorder = WebSocketTelemetryRecorder()
        let hooks = NetworkTelemetryHooks(
            onWebSocketEvent: { context in
                Task { await recorder.append(context) }
            }
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock(),
            telemetryHooks: hooks
        )

        try await client.connect()
        do {
            try await client.send(
                .text("{\"type\":\"event\"}"),
                options: .init(requiresAck: true, messageID: "msg-timeout", ackTimeoutNanoseconds: 1)
            )
            Issue.record("Expected ack timeout")
        } catch let error as WebSocketError {
            #expect(error == .ackTimeout(messageID: "msg-timeout"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        let ackTimeout = await recorder.snapshot().first { $0.type == .ackTimeout }
        #expect(ackTimeout?.messageID == "msg-timeout")
    }

    @Test
    func queuedMessagesFlushOnConnectWithDropOldestPolicy() async throws {
        let transport = MockWebSocketTransport()
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                heartbeatPolicy: .disabled,
                outboundQueuePolicy: .init(maxQueuedMessages: 2, overflowPolicy: .dropOldest)
            ),
            transport: transport
        )

        try await client.send(.text("first"))
        try await client.send(.text("second"))
        try await client.send(.text("third"))
        try await client.connect()

        let sent = await transport.snapshotSentMessages()
        #expect(sent == [.text("second"), .text("third")])
    }

    @Test
    func queuedMessagesDropNewestWhenPolicyConfigured() async throws {
        let transport = MockWebSocketTransport()
        let recorder = WebSocketTelemetryRecorder()
        let hooks = NetworkTelemetryHooks(
            onWebSocketEvent: { context in
                Task { await recorder.append(context) }
            }
        )
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                heartbeatPolicy: .disabled,
                outboundQueuePolicy: .init(maxQueuedMessages: 1, overflowPolicy: .dropNewest)
            ),
            transport: transport,
            telemetryHooks: hooks
        )

        try await client.send(.text("first"))
        try await client.send(.text("second"))
        try await client.connect()

        let sent = await transport.snapshotSentMessages()
        #expect(sent == [.text("first")])

        try? await Task.sleep(nanoseconds: 20_000_000)
        let dropped = await recorder.snapshot().first { $0.type == .messageDropped }
        #expect(dropped?.queuePolicy == "dropNewest")
    }

    @Test
    func ackPendingMessageIsResentAfterReconnect() async throws {
        let transport = MockWebSocketTransport(connectResults: [.success(()), .success(())])
        let client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(
                    maxAttempts: 1,
                    baseDelayNanoseconds: 0,
                    maxDelayNanoseconds: 0,
                    jitterRange: nil
                ),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ImmediateRetryClock(),
            retryRandomGenerator: WSFixedRetryRandom(value: 1)
        )

        try await client.connect()
        let sendTask = Task {
            try await client.send(
                .text("{\"type\":\"event\"}"),
                options: .init(requiresAck: true, messageID: "msg-reconnect", ackTimeoutNanoseconds: 30_000_000_000)
            )
        }

        let firstSendDeadline = Date().addingTimeInterval(1.0)
        while Date() < firstSendDeadline {
            let sent = await transport.snapshotSentMessages()
            if sent.contains(.text("{\"type\":\"event\"}")) {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        await transport.enqueue(.failure(WebSocketError.transport(description: "drop")))
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let sent = await transport.snapshotSentMessages()
            let resentCount = sent.filter { $0 == .text("{\"type\":\"event\"}") }.count
            if resentCount >= 2 {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let sent = await transport.snapshotSentMessages()
        let resentCount = sent.filter { $0 == .text("{\"type\":\"event\"}") }.count
        #expect(resentCount == 2)

        await client.disconnect(reason: "done")
        do {
            try await sendTask.value
            Issue.record("Expected pending ack send task to finish with disconnect after manual shutdown.")
        } catch let error as WebSocketError {
            #expect(
                error == .disconnected ||
                error == .ackTimeout(messageID: "msg-reconnect")
            )
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func urlSessionWebSocketTransportCoversDisconnectedGuardsAndConnectDisconnect() async throws {
        let task = MockURLSessionWebSocketTask()
        let capture = URLRequestCapture()
        let transport = URLSessionWebSocketTransport { request in
            capture.set(request)
            return task
        }

        do {
            _ = try await transport.receive()
            Issue.record("Expected receive() to throw when disconnected.")
        } catch let error as WebSocketError {
            #expect(error == .disconnected)
        }

        do {
            try await transport.send(.text("payload"))
            Issue.record("Expected send() to throw when disconnected.")
        } catch let error as WebSocketError {
            #expect(error == .disconnected)
        }

        do {
            try await transport.ping()
            Issue.record("Expected ping() to throw when disconnected.")
        } catch let error as WebSocketError {
            #expect(error == .disconnected)
        }

        try await transport.connect(url: URL(string: "wss://example.com/ws")!, headers: ["X-Test": "1"])
        #expect(capture.get()?.url?.absoluteString == "wss://example.com/ws")
        #expect(capture.get()?.value(forHTTPHeaderField: "X-Test") == "1")

        task.enqueueReceive(.success(.string("hello")))
        task.enqueueReceive(.success(.data(Data([7, 8]))))
        #expect(try await transport.receive() == .text("hello"))
        #expect(try await transport.receive() == .binary(Data([7, 8])))

        try await transport.send(.text("payload"))
        try await transport.send(.binary(Data([1, 2, 3])))
        #expect(task.snapshotSentMessages().count == 2)

        try await transport.ping()
        task.enqueuePing(URLError(.cannotConnectToHost))
        do {
            try await transport.ping()
            Issue.record("Expected ping to propagate error from task.")
        } catch {
            // expected
        }

        task.enqueueSend(.failure(URLError(.badServerResponse)))
        do {
            try await transport.send(.text("will-fail"))
            Issue.record("Expected send to propagate error from task.")
        } catch {
            // expected
        }

        task.enqueueReceive(.failure(WebSocketError.transport(description: "receive-fail")))
        do {
            _ = try await transport.receive()
            Issue.record("Expected receive to propagate queued failure.")
        } catch {
            // expected
        }

        await transport.disconnect(reason: "done")
        #expect(task.cancelledReason == Data("done".utf8))
    }

    @Test
    func urlSessionWebSocketTransportDefaultSessionInitializerIsCallable() async throws {
        let transport = URLSessionWebSocketTransport(session: URLSession(configuration: .ephemeral))
        try await transport.connect(url: URL(string: "ws://127.0.0.1:9/ws")!, headers: [:])
        await transport.disconnect(reason: nil)
    }
}
