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

        do {
            let payloads = try await client.loadBatch(
                requests: requests,
                authScope: "public",
                batchOptions: .init(maxConcurrentRequests: 4)
            )
            let todos = try payloads.map { try decoder.decode(BatchTodo.self, from: $0) }
            for todo in todos {
                print("[\(todo.id)] \(todo.title)")
            }
        } catch {
            print("Batch failed: \(error.localizedDescription)")
        }
    }
}
