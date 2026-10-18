import Foundation
import Testing
@testable import NovaNetworkClient

private actor ResumeTestTransport: WebSocketTransport {
    private var receiveQueue: [Result<WebSocketMessage, Error>] = []
    private var sent: [WebSocketMessage] = []
    private var connected = false
    private var connects = 0

    func connect(url: URL, headers: [String: String]) async throws {
        connects += 1
        connected = true
    }

    func receive() async throws -> WebSocketMessage {
        while receiveQueue.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        switch receiveQueue.removeFirst() {
        case .success(let message):
            return message
        case .failure(let error):
            throw error
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard connected else { throw WebSocketError.disconnected }
        sent.append(message)
    }

    func ping() async throws {}

    func disconnect(reason: String?) async {
        connected = false
    }

    func enqueue(_ message: WebSocketMessage) {
        receiveQueue.append(.success(message))
    }

    func dropConnection() {
        receiveQueue.append(.failure(WebSocketError.transport(description: "drop")))
    }

    func connectCount() -> Int { connects }
    func sentMessages() -> [WebSocketMessage] { sent }
    func pendingInbound() -> Int { receiveQueue.count }
}

private actor ResumeImmediateClock: RetryClock {
    func sleep(nanoseconds: UInt64) async throws {}
}

private struct ResumeFixedRandom: RetryRandomGenerator {
    func nextDouble(in range: ClosedRange<Double>) -> Double { range.upperBound }
}

private final class ResumeTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [TelemetryWebSocketContext] = []

    func append(_ event: TelemetryWebSocketContext) {
        lock.lock(); events.append(event); lock.unlock()
    }

    func snapshot() -> [TelemetryWebSocketContext] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func reasons(_ type: TelemetryWebSocketEventType) -> [String?] {
        snapshot().filter { $0.type == type }.map(\.reason)
    }
}

private actor Collected<Element: Sendable> {
    private(set) var items: [Element] = []
    func append(_ item: Element) { items.append(item) }
}

private struct Harness {
    let transport = ResumeTestTransport()
    let telemetry = ResumeTelemetry()
    let client: WebSocketClient
    let delivered = Collected<WebSocketMessage>()
    let resumeEvents = Collected<WebSocketEventResumeEvent>()

    init(policy: WebSocketEventResumePolicy?) async {
        let telemetry = self.telemetry
        client = WebSocketClient(
            configuration: .init(
                url: URL(string: "wss://example.com/ws")!,
                reconnectPolicy: .init(maxAttempts: 1, baseDelayNanoseconds: 0, maxDelayNanoseconds: 0, jitterRange: nil),
                heartbeatPolicy: .disabled
            ),
            transport: transport,
            retryClock: ResumeImmediateClock(),
            retryRandomGenerator: ResumeFixedRandom(),
            telemetryHooks: NetworkTelemetryHooks(onWebSocketEvent: { telemetry.append($0) }),
            eventResumePolicy: policy
        )
        let messages = await client.messages()
        let delivered = self.delivered
        Task {
            for try await message in messages { await delivered.append(message) }
        }
        let events = await client.eventResumeEvents()
        let resumeEvents = self.resumeEvents
        Task {
            for await event in events { await resumeEvents.append(event) }
        }
        // Both streams attach to their hubs asynchronously.
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func receive(_ messages: WebSocketMessage...) async {
        for message in messages {
            await transport.enqueue(message)
        }
        await until { await transport.pendingInbound() == 0 }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    func reconnect() async {
        let before = await transport.connectCount()
        await transport.dropConnection()
        await until { await transport.connectCount() > before }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    func deliveredTexts() async -> [String] {
        await delivered.items.compactMap {
            guard case .text(let text) = $0 else { return nil }
            return text
        }
    }

    private func until(_ condition: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, !(await condition()) {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

private func event(_ stream: String, _ seq: Int) -> WebSocketMessage {
    .text("{\"stream\":\"\(stream)\",\"seq\":\(seq)}")
}

private let ordersSubscription = WebSocketMessage.text("{\"type\":\"subscribe\",\"channel\":\"orders\"}")

struct WebSocketEventResumeTests {
    // T-17.1 — FR-WS-RESUME-2, FR-WS-RESUME-3, AR-WS-RESUME-1
    @Test
    func aReconnectAsksForTheEventsAfterTheLastOneDelivered() async throws {
        let harness = await Harness(policy: .default)
        try await harness.client.connect()
        await harness.client.registerSubscription(id: "orders", message: ordersSubscription)
        await harness.receive(event("orders", 1), event("orders", 2))
        #expect(await harness.client.eventCursor(forStream: "orders") == 2)

        await harness.reconnect()

        let sent = await harness.transport.sentMessages()
        #expect(sent == [.text("{\"afterSeq\":2,\"channel\":\"orders\",\"type\":\"subscribe\"}")])
        #expect(harness.telemetry.reasons(.eventResumeRequested) == ["orders:2"])
        let requested = harness.telemetry.snapshot().first { $0.type == .eventResumeRequested }
        let restoreStarted = harness.telemetry.snapshot().first { $0.type == .subscriptionRestoreStarted }
        #expect(requested?.correlationID != nil)
        #expect(requested?.correlationID == restoreStarted?.correlationID)
        #expect(await harness.resumeEvents.items == [.resumeRequested(streamID: "orders", afterSequence: 2)])
    }

    // T-17.2 — FR-WS-RESUME-4, AR-WS-RESUME-3
    @Test
    func eventsTheAppAlreadyHasAreNotDeliveredAgain() async throws {
        let harness = await Harness(policy: .default)
        try await harness.client.connect()
        await harness.receive(event("orders", 1), event("orders", 2), event("orders", 2), event("orders", 1), event("orders", 3))

        #expect(await harness.deliveredTexts() == [
            "{\"stream\":\"orders\",\"seq\":1}",
            "{\"stream\":\"orders\",\"seq\":2}",
            "{\"stream\":\"orders\",\"seq\":3}"
        ])
        #expect(harness.telemetry.reasons(.eventDuplicateDropped) == ["orders:2", "orders:1"])
        #expect(harness.telemetry.snapshot().filter { $0.type == .messageReceived }.count == 3)
    }

    // T-17.3 — FR-WS-RESUME-5, AR-WS-RESUME-2
    @Test
    func aSkippedSequenceIsDeliveredAndReportedAsAGap() async throws {
        let harness = await Harness(policy: .default)
        try await harness.client.connect()
        await harness.receive(event("orders", 1), event("orders", 4), event("orders", 5))

        #expect(await harness.deliveredTexts().count == 3)
        #expect(await harness.client.eventCursor(forStream: "orders") == 5)
        #expect(await harness.resumeEvents.items == [
            .gapDetected(streamID: "orders", expectedSequence: 2, receivedSequence: 4)
        ])
        #expect(harness.telemetry.reasons(.eventGapDetected) == ["orders:2-4"])
    }

    // T-17.4 — FR-WS-RESUME-6, AR-WS-RESUME-4
    @Test
    func aResyncSignalClearsTheCursorAndStillReachesTheApp() async throws {
        let harness = await Harness(policy: .default)
        try await harness.client.connect()
        let resync = "{\"type\":\"resync_required\",\"stream\":\"orders\"}"
        await harness.receive(event("orders", 5), .text(resync))

        #expect(await harness.client.eventCursor(forStream: "orders") == nil)
        #expect(await harness.deliveredTexts().last == resync)
        #expect(await harness.resumeEvents.items == [.resyncRequired(streamID: "orders")])
        #expect(harness.telemetry.reasons(.eventResyncRequired) == ["orders"])

        // The server restarted its numbering; the first event after the signal is not a duplicate.
        await harness.receive(event("orders", 1))
        #expect(await harness.deliveredTexts().last == "{\"stream\":\"orders\",\"seq\":1}")
        #expect(await harness.client.eventCursor(forStream: "orders") == 1)
    }

    // T-17.5 — FR-WS-RESUME-7, EC-WS-RESUME-3
    @Test
    func theAppCanSeedResetAndForgetCursors() async throws {
        let harness = await Harness(policy: .default)
        let client = harness.client
        try await client.connect()

        await client.seedEventCursor(41, forStream: "orders")
        await client.registerSubscription(id: "orders", message: ordersSubscription)
        await harness.receive(event("orders", 41))
        #expect(await harness.deliveredTexts().isEmpty)

        await harness.reconnect()
        #expect(await harness.transport.sentMessages() == [
            .text("{\"afterSeq\":41,\"channel\":\"orders\",\"type\":\"subscribe\"}")
        ])

        await client.resetEventCursor(forStream: "orders")
        #expect(await client.eventCursor(forStream: "orders") == nil)

        await client.seedEventCursor(3, forStream: "orders")
        await client.unregisterSubscription(id: "orders")
        #expect(await client.eventCursor(forStream: "orders") == nil)

        await client.seedEventCursor(3, forStream: "orders")
        await client.seedEventCursor(9, forStream: "prices")
        await client.clearSubscriptions()
        #expect(await client.eventCursor(forStream: "orders") == nil)
        #expect(await client.eventCursor(forStream: "prices") == nil)
    }

    // T-17.6 — FR-WS-RESUME-1, FR-WS-RESUME-8, EC-WS-RESUME-1
    @Test
    func theDefaultConventionReadsAndWritesJSON() throws {
        let policy = WebSocketEventResumePolicy.default

        #expect(policy.position(event("orders", 7)) == .init(streamID: "orders", sequence: 7))
        #expect(policy.position(.binary(Data("{\"stream\":\"a\",\"seq\":0}".utf8))) == .init(streamID: "a", sequence: 0))
        #expect(policy.position(.text("{\"stream\":\"a\",\"seq\":-1}")) == nil)
        #expect(policy.position(.text("{\"stream\":\"a\",\"seq\":\"7\"}")) == nil)
        #expect(policy.position(.text("{\"seq\":7}")) == nil)
        #expect(policy.position(.text("not json")) == nil)

        #expect(policy.resumeMessage(ordersSubscription, 3) == .text("{\"afterSeq\":3,\"channel\":\"orders\",\"type\":\"subscribe\"}"))
        #expect(policy.resumeMessage(.text("SUB orders"), 3) == nil)
        #expect(policy.resumeMessage(.text("[1,2]"), 3) == nil)

        #expect(policy.resyncSignal(.text("{\"type\":\"resync_required\",\"stream\":\"orders\"}")) == "orders")
        #expect(policy.resyncSignal(.text("{\"type\":\"ack\",\"stream\":\"orders\"}")) == nil)
        #expect(policy.resyncSignal(event("orders", 1)) == nil)

        let custom = WebSocketEventResumePolicy(
            position: { message in
                guard case .text(let text) = message else { return nil }
                let parts = text.split(separator: "|")
                guard parts.count == 3, parts[0] == "evt", let seq = UInt64(parts[2]) else { return nil }
                return .init(streamID: String(parts[1]), sequence: seq)
            },
            resumeMessage: { _, after in .text("SUB orders FROM \(after)") }
        )
        #expect(custom.position(.text("evt|orders|12")) == .init(streamID: "orders", sequence: 12))
        #expect(custom.resyncSignal(.text("anything")) == nil)
    }

    // T-17.6 — EC-WS-RESUME-1
    @Test
    func aSubscriptionThePolicyCannotRewriteIsResentUnchanged() async throws {
        let harness = await Harness(policy: .default)
        try await harness.client.connect()
        await harness.client.registerSubscription(id: "orders", message: .text("SUB orders"))
        await harness.receive(event("orders", 1))

        await harness.reconnect()

        #expect(await harness.transport.sentMessages() == [.text("SUB orders")])
        #expect(harness.telemetry.reasons(.eventResumeRequested).isEmpty)
    }

    // T-17.7 — EC-WS-RESUME-2, EC-WS-RESUME-4
    @Test
    func unsequencedFramesPassThroughAndTheFirstEventStartsTheCursor() async throws {
        let harness = await Harness(policy: .default)
        try await harness.client.connect()
        await harness.receive(
            .text("{\"type\":\"ack\",\"messageId\":\"m1\"}"),
            .text("hello"),
            event("orders", 10),
            event("orders", 11)
        )

        #expect(await harness.deliveredTexts().count == 4)
        #expect(await harness.client.eventCursor(forStream: "orders") == 11)
        #expect(await harness.resumeEvents.items.isEmpty)
    }

    // T-17.8 — regression: without a policy nothing changes
    @Test
    func withoutAPolicyTheClientBehavesAsBefore() async throws {
        let harness = await Harness(policy: nil)
        try await harness.client.connect()
        await harness.client.registerSubscription(id: "orders", message: ordersSubscription)
        await harness.receive(event("orders", 1), event("orders", 1))

        #expect(await harness.deliveredTexts().count == 2)
        #expect(await harness.client.eventCursor(forStream: "orders") == nil)

        await harness.reconnect()
        #expect(await harness.transport.sentMessages() == [ordersSubscription])
        let types = harness.telemetry.snapshot().map(\.type)
        #expect(!types.contains(.eventResumeRequested))
        #expect(!types.contains(.eventDuplicateDropped))
    }

    @Test
    func thePublicInitializerAcceptsAPolicy() async {
        let client = WebSocketClient(
            configuration: .init(url: URL(string: "wss://example.com/ws")!),
            eventResume: .default
        )
        await client.seedEventCursor(1, forStream: "s")
        #expect(await client.eventCursor(forStream: "s") == 1)
    }
}
