import Foundation
import Testing
@testable import NovaNetworkClient

extension E2ECoverageTests {

    @Test
    func e2eWebSocketPublicEchoRoundTrip() async throws {
        guard e2eEnabled() else { return }

        try await withAnyE2EWebSocketURL { url in
            let client = WebSocketClient(
                configuration: .init(
                    url: url,
                    reconnectPolicy: .disabled,
                    heartbeatPolicy: .disabled
                )
            )
            let payload = "nova-e2e-\(UUID().uuidString)"
            let messages = await client.messages()
            defer {
                Task { await client.disconnect(reason: "e2e-finished") }
            }

            try await client.connect()
            try await client.send(.text(payload))
            let first = try await nextWebSocketMessage(from: messages)
            guard case .text(let echoed)? = first else {
                Issue.record("Expected text WebSocket message echo from \(url.absoluteString).")
                return
            }
            #expect(echoed == payload || echoed.range(of: payload) != nil)
        }
    }

    @Test
    func e2eWebSocketPublicHeartbeatKeepsConnectionUsable() async throws {
        guard e2eEnabled() else { return }

        try await withAnyE2EWebSocketURL { url in
            let client = WebSocketClient(
                configuration: .init(
                    url: url,
                    reconnectPolicy: .init(
                        maxAttempts: 1,
                        baseDelayNanoseconds: 300_000_000,
                        maxDelayNanoseconds: 300_000_000,
                        jitterRange: nil
                    ),
                    heartbeatPolicy: .init(
                        intervalNanoseconds: 500_000_000,
                        timeoutNanoseconds: 2_000_000_000
                    )
                )
            )
            let firstPayload = "hb-one-\(UUID().uuidString)"
            let secondPayload = "hb-two-\(UUID().uuidString)"
            let messages = await client.messages()
            defer {
                Task { await client.disconnect(reason: "e2e-finished") }
            }

            try await client.connect()
            try await client.send(.text(firstPayload))
            let first = try await nextWebSocketMessage(from: messages)
            guard case .text(let echoedFirst)? = first else {
                Issue.record("Expected first text echo from \(url.absoluteString).")
                return
            }
            #expect(echoedFirst == firstPayload || echoedFirst.range(of: firstPayload) != nil)

            try? await Task.sleep(nanoseconds: 1_200_000_000)

            try await client.send(.text(secondPayload))
            let second = try await nextWebSocketMessage(from: messages)
            guard case .text(let echoedSecond)? = second else {
                Issue.record("Expected second text echo from \(url.absoluteString).")
                return
            }
            #expect(echoedSecond == secondPayload || echoedSecond.range(of: secondPayload) != nil)
        }
    }

    @Test
    func e2eWebSocketDiskStoreRoundTripAndPartialCorruptionRecovery() async throws {
        guard e2eEnabled() else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ws-e2e-store-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("queue.json")
        let store = DiskWebSocketOutboundQueueStore(fileURL: fileURL)

        let baseline: [WebSocketQueuedMessage] = [
            .init(
                message: .text("e2e-baseline"),
                options: .init(requiresAck: false),
                resolvedMessageID: nil,
                enqueuedAt: Date()
            )
        ]
        try await store.persistQueuedMessages(baseline)
        let restored = try await store.loadQueuedMessages()
        #expect(restored == baseline)

        let valid = WebSocketQueuedMessage(
            message: .text("e2e-valid"),
            options: .init(requiresAck: false),
            resolvedMessageID: nil,
            enqueuedAt: Date()
        )
        let validData = try JSONEncoder().encode(valid)
        let validJSON = try JSONSerialization.jsonObject(with: validData)
        let root: [String: Any] = [
            "schemaVersion": 1,
            "messages": [validJSON, ["broken": true]]
        ]
        let raw = try JSONSerialization.data(withJSONObject: root)
        try raw.write(to: fileURL, options: .atomic)

        do {
            _ = try await store.loadQueuedMessages()
            Issue.record("Expected partial corruption signal.")
        } catch let error as WebSocketOutboundQueueStoreError {
            if case .partiallyCorrupted(let recovered, let droppedCount) = error {
                #expect(recovered == [valid])
                #expect(droppedCount == 1)
            } else {
                Issue.record("Expected partiallyCorrupted error, got \(error).")
            }
        }
    }

    @Test
    func e2eWebSocketClientRestoresRecoveredPersistedQueue() async throws {
        guard e2eEnabled() else { return }

        try await withAnyE2EWebSocketURL { url in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ws-e2e-client-restore-\(UUID().uuidString)", isDirectory: true)
            let fileURL = directory.appendingPathComponent("queue.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let valid = WebSocketQueuedMessage(
                message: .text("restored-valid"),
                options: .init(requiresAck: false),
                resolvedMessageID: nil,
                enqueuedAt: Date()
            )
            let validData = try JSONEncoder().encode(valid)
            let validJSON = try JSONSerialization.jsonObject(with: validData)
            let root: [String: Any] = [
                "schemaVersion": 1,
                "messages": [validJSON, ["broken": true]]
            ]
            let raw = try JSONSerialization.data(withJSONObject: root)
            try raw.write(to: fileURL, options: .atomic)

            let store = DiskWebSocketOutboundQueueStore(fileURL: fileURL)
            let client = WebSocketClient(
                configuration: .init(
                    url: url,
                    reconnectPolicy: .disabled,
                    heartbeatPolicy: .disabled,
                    outboundQueuePolicy: .init(maxQueuedMessages: 8, overflowPolicy: .dropOldest)
                ),
                outboundQueueStore: store
            )
            let messages = await client.messages()
            defer {
                Task { await client.disconnect(reason: "e2e-finished") }
            }

            try await client.connect()
            let first = try await nextWebSocketMessage(from: messages)
            guard case .text(let echoed)? = first else {
                Issue.record("Expected queued message replay echo from \(url.absoluteString).")
                return
            }
            #expect(echoed.range(of: "restored-valid") != nil)
        }
    }
}
