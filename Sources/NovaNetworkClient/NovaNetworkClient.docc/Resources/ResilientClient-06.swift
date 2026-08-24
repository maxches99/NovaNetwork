import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct ResilientClient {
    static func main() async {
        var configuration = NetworkClientConfiguration()
        configuration.retryPolicy = RetryPolicy(
            maxAttempts: 3,
            baseDelayNanoseconds: 200_000_000,
            maxDelayNanoseconds: 2_000_000_000
        )
        configuration.defaultCachePolicy = .cacheFirst(maxAge: 30)
        configuration.networkObserver = { event in
            print("Network event: \(event)")
        }

        let client = NetworkClient(configuration: configuration)
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json"]
        )

        do {
            let todo: Todo = try await client.load(request: request, authScope: "public")
            print("Loaded \(todo.id)")
        } catch let error as NetworkError {
            switch error {
            case .httpStatus(let code, _, _):
                print("Server returned HTTP \(code)")
            case .cancelled:
                print("Request was cancelled")
            default:
                print(error.localizedDescription)
            }
        } catch {
            print("Request setup failed: \(error.localizedDescription)")
        }
    }
}
