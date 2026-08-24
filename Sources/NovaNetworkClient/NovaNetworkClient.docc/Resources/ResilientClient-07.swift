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
            switch event {
            case .cacheHit(_, let isStale, let ageMilliseconds):
                print("Cache hit: stale=\(isStale), age=\(ageMilliseconds) ms")
            case .cacheMiss:
                print("Cache miss")
            case .cacheRevalidated(_, let ageMilliseconds):
                print("Cache revalidated at age \(ageMilliseconds) ms")
            default:
                break
            }
        }

        let client = NetworkClient(configuration: configuration)
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json"]
        )

        do {
            let first: Todo = try await client.load(request: request, authScope: "public")
            let second: Todo = try await client.load(request: request, authScope: "public")
            print("Loaded \(first.id), then \(second.id)")
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
