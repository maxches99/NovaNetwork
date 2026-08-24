import Foundation
import NovaNetworkClient

@main
struct RealtimeChannelTutorial {
    static func main() async {
        // Replace this placeholder with your production WebSocket endpoint.
        let serviceURL = URL(string: "wss://realtime.example.com/socket")!
        let configuration = WebSocketConfiguration(
            url: serviceURL,
            reconnectPolicy: .init(maxAttempts: 2),
            heartbeatPolicy: .init(),
            subscriptionReplayPolicy: .init(maxAttemptsPerSubscription: 2)
        )
        let socket = WebSocketClient(configuration: configuration)
        let states = await socket.connectionStates()
        let statePrinter = Task {
            for await state in states {
                print("state:", state)
            }
        }

        do {
            try await socket.connect()
            try await socket.send(.text("hello from Nova"))
            let messages = await socket.messages()
            if let message = try await nextMessage(from: messages) {
                print("received:", message)
            }
        } catch {
            print("Realtime flow failed: \(error.localizedDescription)")
        }

        await socket.disconnect(reason: "tutorial-complete")
        statePrinter.cancel()
    }

    private static func nextMessage(
        from stream: AsyncThrowingStream<WebSocketMessage, Error>
    ) async throws -> WebSocketMessage? {
        try await withThrowingTaskGroup(of: WebSocketMessage?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 12_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
