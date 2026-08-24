import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

struct TodoEndpoint: Endpoint {
    typealias Response = Todo

    let id: Int

    func makeRequest() throws -> APIRequest {
        APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/\(id)")!,
            headers: ["Accept": "application/json"]
        )
    }
}

@main
struct TypedEndpointExample {
    static func main() async throws {
        let client = NetworkClient()
        let todo = try await client.execute(
            endpoint: TodoEndpoint(id: 1),
            authScope: "public",
            cachePolicy: .cacheFirst(maxAge: 30),
            options: .init(priority: .high, deadlineBudgetSeconds: 5)
        )
        print(todo.title)
    }
}
