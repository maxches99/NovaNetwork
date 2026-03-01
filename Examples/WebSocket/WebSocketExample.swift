import Foundation
import NovaNetworkClient

@main
struct WebSocketExample {
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
                headers: ["User-Agent": "NovaNetworkClient-WebSocketExample"],
                reconnectPolicy: .init(maxAttempts: 2),
                heartbeatPolicy: .init()
            )
        )

        let payload = "nova-websocket-example-\(UUID().uuidString)"
        let stateStream = await socket.connectionStates()
        let statePrinter = Task {
            var iterator = stateStream.makeAsyncIterator()
            var printed = 0
            while printed < 5, let state = await iterator.next() {
                print("state:", state)
                printed += 1
            }
        }

        do {
            try await socket.connect()
            try await socket.send(.text(payload))

            let messages = await socket.messages()
            if let response = try await nextMessage(from: messages, timeoutNanoseconds: 12_000_000_000) {
                print("received:", response)
            } else {
                print("No message received before timeout.")
            }
        } catch {
            print("WebSocket example failed:", error)
        }

        await socket.disconnect(reason: "example-finished")
        statePrinter.cancel()
    }

    private static func nextMessage(
        from stream: AsyncThrowingStream<WebSocketMessage, Error>,
        timeoutNanoseconds: UInt64
    ) async throws -> WebSocketMessage? {
        try await withThrowingTaskGroup(of: WebSocketMessage?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
