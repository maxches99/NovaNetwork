import Foundation
import NovaNetworkCassette
import NovaNetworkClient

/// Records a real exchange into a cassette, then replays it with the network taken away.
///
/// The first pass performs a live request and writes the recording. The second pass runs against a
/// transport that fails if it is ever called, so a response can only come from the file — which is
/// what makes a replayed test, a SwiftUI preview, or a demo build deterministic and offline.
@main
struct CassetteExample {
    struct Todo: Decodable, Sendable {
        let id: Int
        let title: String
    }

    /// A transport that refuses to work, proving replay never reaches the network.
    struct OfflineTransport: NetworkTransport {
        struct NetworkIsGone: Error {}

        func execute(_ request: APIRequest) async throws -> NetworkResponse {
            throw NetworkIsGone()
        }
    }

    static func main() async {
        let cassetteURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-cassette-example", isDirectory: true)
            .appendingPathComponent("todo.json")
        defer { try? FileManager.default.removeItem(at: cassetteURL.deletingLastPathComponent()) }

        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json", "Authorization": "Bearer example-token"]
        )

        do {
            let recorded: Todo = try await withCassette(at: cassetteURL, upstream: Transport()) { transport in
                try await NetworkClient(transport: transport).load(request: request, authScope: "public")
            }
            print("Recorded live: \(recorded.id) — \(recorded.title)")

            let saved = try String(contentsOf: cassetteURL, encoding: .utf8)
            print("Cassette written to \(cassetteURL.path) (\(saved.count) bytes)")
            print("Credential redacted in the file: \(!saved.contains("example-token"))")

            let replayed: Todo = try await withCassette(at: cassetteURL, mode: .replay, upstream: OfflineTransport()) { transport in
                try await NetworkClient(transport: transport).load(request: request, authScope: "public")
            }
            print("Replayed offline: \(replayed.id) — \(replayed.title)")
            print("Same payload: \(replayed.id == recorded.id && replayed.title == recorded.title)")
        } catch {
            print("Example failed: \(error.localizedDescription)")
            print("The first pass needs network access; later passes replay from the cassette.")
        }
    }
}
