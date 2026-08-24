import Foundation
import NovaNetworkClient

@main
struct RealtimeChannelTutorial {
    static func main() async {
        let configuration = WebSocketConfiguration(
            url: URL(string: "wss://ws.postman-echo.com/raw")!,
            reconnectPolicy: .init(maxAttempts: 2),
            heartbeatPolicy: .init()
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
        } catch {
            print("Realtime flow failed: \(error.localizedDescription)")
        }
    }
}
