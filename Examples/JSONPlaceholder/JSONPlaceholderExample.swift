import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct JSONPlaceholderExample {
    static func main() async {
        let client = NetworkClient(transport: Transport())

        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json"]
        )

        do {
            async let first: Todo = client.load(request: request, authScope: "public")
            async let second: Todo = client.load(request: request, authScope: "public")
            let (todoA, todoB) = try await (first, second)

            print("First title: \(todoA.title)")
            print("Second title: \(todoB.title)")
            print("Same payload: \(todoA.id == todoB.id)")
        } catch {
            print("Example failed: \(error)")
        }
    }
}
