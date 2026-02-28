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
}
