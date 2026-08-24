import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct FirstRequest {
    static func main() async {
        let client = NetworkClient()
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json"]
        )

        do {
            let todo: Todo = try await client.load(
                request: request,
                authScope: "public"
            )
            print(todo.title)
        } catch {
            print("Request failed: \(error.localizedDescription)")
        }
    }
}
