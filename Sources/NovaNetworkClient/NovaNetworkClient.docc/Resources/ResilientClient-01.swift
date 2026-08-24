import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct ResilientClient {
    static func main() async {
        var configuration = NetworkClientConfiguration()
    }
}
