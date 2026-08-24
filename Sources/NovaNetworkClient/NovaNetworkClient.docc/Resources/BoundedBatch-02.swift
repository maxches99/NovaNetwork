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
        let requests = (1...12).map { id in
            APIRequest(
                method: .get,
                url: URL(string: "https://jsonplaceholder.typicode.com/todos/\(id)")!
            )
        }
    }
}
