import Foundation
import NovaNetworkClient

actor TokenVault {
    private var token = "expired-token"

    func current() -> String { token }
    func store(_ value: String) { token = value }
}

func refreshToken(for scope: String?) async throws -> String {
    // Replace this placeholder with your authentication service.
    "fresh-token-for-\(scope ?? "default")"
}

@main
struct AuthRefreshTutorial {
    static func main() async {
        let vault = TokenVault()
        let authMiddleware = NetworkMiddleware(beforeSend: { request, _ in
            let token = await vault.current()
            return request.withMergedHeaders(["Authorization": "Bearer \(token)"])
        })
        let refreshProvider = HTTPAuthRefreshProvider { scope in
            let token = try await refreshToken(for: scope)
            await vault.store(token)
            return ["Authorization": "Bearer \(token)"]
        }

        var configuration = NetworkClientConfiguration()
        configuration.middlewares = [authMiddleware]
        configuration.httpAuthRefreshProvider = refreshProvider
        configuration.httpAuthRefreshPolicy = .init(maxRefreshAttempts: 1)
        let client = NetworkClient(configuration: configuration)
    }
}
