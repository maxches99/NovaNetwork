import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

let client = NetworkClient()
let request = APIRequest(
    method: .get,
    url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
    headers: ["Accept": "application/json"]
)

let todo: Todo = try await client.load(
    request: request,
    authScope: "public"
)
print(todo.title)
