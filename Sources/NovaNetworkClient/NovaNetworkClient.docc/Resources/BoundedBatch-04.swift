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
            let results = try await client.loadBatchResults(
                requests: requests,
                authScope: "public",
                batchOptions: .init(maxConcurrentRequests: 4)
            )
            for item in results {
                switch item.result {
                case .success(let payload):
                    let todo = try decoder.decode(BatchTodo.self, from: payload)
                    print("[\(todo.id)] \(todo.title)")
                case .failure(let error):
                    print("Request \(item.index) failed: \(error.localizedDescription)")
                }
            }
        } catch {
            print("Batch configuration failed: \(error.localizedDescription)")
        }
    }
}
