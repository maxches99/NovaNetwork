import Foundation
import NovaNetworkClient

struct EchoResponse: Decodable, Sendable {
    let url: String
    let headers: [String: String]
}

@main
struct MiddlewareExample {
    static func main() async {
        let authMiddleware = NetworkMiddleware(
            beforeSend: { request, _ in
                request.withMergedHeaders([
                    "X-Demo-Client": "NovaNetworkClient",
                    "X-Demo-Env": "examples"
                ])
            }
        )

        let client = NetworkClient(
            transport: Transport(),
            middlewares: [authMiddleware]
        )

        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/anything")!
        )

        do {
            let response: EchoResponse = try await client.load(
                request: request,
                authScope: "public"
            )
            print("URL: \(response.url)")
            print("Injected X-Demo-Client: \(response.headers["X-Demo-Client"] ?? "<missing>")")
            print("Injected X-Demo-Env: \(response.headers["X-Demo-Env"] ?? "<missing>")")
        } catch {
            print("Example failed: \(error)")
        }
    }
}
