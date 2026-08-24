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
    }
}
