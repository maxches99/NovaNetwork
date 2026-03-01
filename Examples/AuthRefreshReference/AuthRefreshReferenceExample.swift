import Foundation
import NovaNetworkClient

actor AccessTokenVault {
    private var token: String = "expired-token"

    func current() -> String {
        token
    }

    func refresh() {
        token = "fresh-token"
    }
}

actor AuthAwareTransport: NetworkTransport {
    private var authFailures = 0

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        let auth = request.headers["Authorization"] ?? ""
        if auth != "Bearer fresh-token" {
            authFailures += 1
            throw NetworkError.httpStatus(code: 401, body: Data("unauthorized".utf8))
        }

        let body = Data("{\"status\":\"ok\",\"source\":\"refreshed\"}".utf8)
        return NetworkResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    func unauthorizedCount() -> Int {
        authFailures
    }
}

@main
struct AuthRefreshReferenceExample {
    static func main() async {
        let tokenVault = AccessTokenVault()
        let transport = AuthAwareTransport()

        let authMiddleware = NetworkMiddleware(beforeSend: { request, _ in
            let token = await tokenVault.current()
            return request.withMergedHeaders(["Authorization": "Bearer \(token)"])
        })

        let preset = NetworkClientPreset.restHeavy
        let client = NetworkClient(
            transport: transport,
            retryPolicy: preset.retryPolicy,
            defaultCachePolicy: preset.defaultCachePolicy,
            middlewares: [authMiddleware]
        )
        await client.applyRuntimePolicy(from: preset)

        let request = APIRequest(method: .get, url: URL(string: "https://reference.local/auth/refresh")!)

        do {
            _ = try await client.load(request: request, authScope: "user:42", options: preset.requestOptions())
            print("Unexpected success on first request")
        } catch let error as NetworkError {
            guard case .httpStatus(let code, _, _) = error, code == 401 else {
                print("Unexpected error:", error)
                return
            }

            await tokenVault.refresh()
            do {
                let data = try await client.load(request: request, authScope: "user:42", options: preset.requestOptions())
                print("Refresh recovered session. Payload bytes: \(data.count)")
                print("Unauthorized attempts before recovery: \(await transport.unauthorizedCount())")
            } catch {
                print("Auth refresh retry failed:", error)
            }
        } catch {
            print("Unexpected failure:", error)
        }
    }
}
