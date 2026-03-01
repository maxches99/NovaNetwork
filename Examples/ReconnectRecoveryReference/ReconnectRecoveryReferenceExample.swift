import Foundation
import NovaNetworkClient

@main
struct ReconnectRecoveryReferenceExample {
    private static let endpointEnv = "NOVA_WS_URL"

    static func main() async {
        let endpoint = ProcessInfo.processInfo.environment[endpointEnv] ?? "wss://ws.postman-echo.com/raw"
        guard let url = URL(string: endpoint) else {
            print("Invalid WebSocket URL in \(endpointEnv): \(endpoint)")
            return
        }

        let socket = WebSocketClient(
            configuration: .init(
                url: url,
                headers: ["User-Agent": "NovaNetworkClient-ReconnectReference"],
                reconnectPolicy: .init(maxAttempts: 4),
                heartbeatPolicy: .init(intervalNanoseconds: 5_000_000_000, timeoutNanoseconds: 2_000_000_000),
                outboundQueuePolicy: .init(maxQueuedMessages: 32, overflowPolicy: .dropOldest),
                authRefreshPolicy: .init(maxAttempts: 1)
            ),
            telemetryHooks: .init(
                onWebSocketEvent: { event in
                    print("[ws] type=\(event.type.rawValue) reason=\(event.reason ?? "-")")
                }
            )
        )

        let states = await socket.connectionStates()
        let stateTask = Task {
            var count = 0
            for await state in states {
                print("state:", state)
                count += 1
                if count >= 8 { break }
            }
        }

        do {
            try await socket.connect()
            try await socket.send(.text("reconnect-reference-initial"))

            await socket.forceReconnect(reason: "reference-recovery-check")
            try await Task.sleep(nanoseconds: 1_500_000_000)
            try await socket.send(.text("reconnect-reference-after-recovery"))

            let diagnostics = await socket.webSocketDiagnostics()
            print("diagnostics.phase=\(diagnostics.reconnectPhase.rawValue)")
            print("diagnostics.health=\(diagnostics.health)")
            print("diagnostics.queue=\(diagnostics.queuedOutboundMessages)/\(diagnostics.queueCapacity)")
        } catch {
            print("Reconnect recovery reference failed:", error)
        }

        await socket.disconnect(reason: "reference-finished")
        stateTask.cancel()
    }
}
