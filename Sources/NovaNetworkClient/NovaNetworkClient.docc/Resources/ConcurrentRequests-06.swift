import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct ConcurrentRequests {
    static func main() async {
        let client = NetworkClient()
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json"]
        )
        let authScope = "public"

        do {
            async let first: Todo = client.load(request: request, authScope: authScope)
            async let second: Todo = client.load(request: request, authScope: authScope)
            let (a, b) = try await (first, second)

            let metrics = await client.coalescerMetrics()
            print("Same todo: \(a.id == b.id)")
            print("New operations: \(metrics.coalescedMisses)")
            print("Shared callers: \(metrics.coalescedHits)")

            guard a.id == b.id, metrics.coalescedHits > 0 else {
                print("Verification failed: the callers did not share equivalent work")
                return
            }
            print("Verified: both callers received the same todo from shared work")
        } catch {
            print("Requests failed: \(error.localizedDescription)")
        }
    }
}
