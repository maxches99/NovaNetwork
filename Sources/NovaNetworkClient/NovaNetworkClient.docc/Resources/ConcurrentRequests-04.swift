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
let authScope = "public"

async let first: Todo = client.load(request: request, authScope: authScope)
async let second: Todo = client.load(request: request, authScope: authScope)
let (a, b) = try await (first, second)
