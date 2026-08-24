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
    }
}
