import Foundation
import NovaNetworkClient

struct BatchTodo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct BoundedBatchTutorial {
    static func main() async {
        let client = NetworkClient(transport: Transport())
        let decoder = JSONDecoder()
    }
}
