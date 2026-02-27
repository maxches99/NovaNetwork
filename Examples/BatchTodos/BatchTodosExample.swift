import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct BatchTodosExample {
    static func main() async {
        let client = NetworkClient(transport: Transport())
        let decoder = JSONDecoder()

        let requests = [
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!),
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/2")!),
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/3")!)
        ]

        do {
            let payloads = try await client.loadBatch(
                requests: requests,
                authScope: "public"
            )
            let todos = try payloads.map { try decoder.decode(Todo.self, from: $0) }

            for todo in todos {
                print("[\(todo.id)] \(todo.title) | completed=\(todo.completed)")
            }
        } catch {
            print("Example failed: \(error)")
        }
    }
}
