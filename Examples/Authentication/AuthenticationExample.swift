import Foundation
import NovaNetworkAuth
import NovaNetworkClient

/// Walks the whole authorization code flow against a scripted provider, then shows the two things
/// that are hard to get right by hand: one refresh shared by many callers, and a signed request.
///
/// The provider is scripted rather than live so the example is deterministic and needs no
/// registered client. Every call it makes is the one a real provider would receive.
@main
struct AuthenticationExample {
    /// Answers like an OAuth 2.0 provider, and counts how many times it was asked to refresh.
    actor FakeProvider: NetworkTransport {
        private(set) var refreshCount = 0

        func execute(_ request: APIRequest) async throws -> NetworkResponse {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)

            if body.contains("grant_type=refresh_token") {
                refreshCount += 1
                return json(#"{"access_token":"at-refreshed","expires_in":3600}"#)
            }
            if body.contains("grant_type=authorization_code") {
                return json(#"{"access_token":"at-1","refresh_token":"rt-1","expires_in":3600,"scope":"profile email"}"#)
            }
            return json(#"{"access_token":"at-generic","expires_in":3600}"#)
        }

        func refreshes() -> Int { refreshCount }

        private func json(_ text: String) -> NetworkResponse {
            NetworkResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }
    }

    static func main() async {
        let configuration = OAuth2Configuration(
            clientID: "demo-client",
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            redirectURI: URL(string: "novaapp://callback")!,
            scopes: ["profile", "email"]
        )
        let provider = FakeProvider()
        let oauth = OAuth2Client(configuration: configuration, transport: provider)

        do {
            // 1. Start the flow. Keep the verifier and the state; the callback is worthless without
            //    them, and the state check is what stops someone else's code being redeemed here.
            let pkce = PKCEChallenge.generate()
            let state = UUID().uuidString
            let authorizationURL = try oauth.authorizationURL(state: state, challenge: pkce)
            print("1. Open this in a browser:")
            print("   \(authorizationURL.absoluteString)")
            print("   (presenting it is the app's job — it needs a window anchor this library has no business holding)")

            // 2. The provider sends the user back. Parse what came with them.
            let callback = URL(string: "novaapp://callback?code=auth-code-1&state=\(state)")!
            let code = try oauth.authorizationCode(from: callback, expectedState: state)
            print("2. Callback validated, code: \(code)")

            let tampered = URL(string: "novaapp://callback?code=attacker-code&state=not-our-state")!
            do {
                _ = try oauth.authorizationCode(from: tampered, expectedState: state)
                print("   A tampered callback was accepted — that would be a bug.")
            } catch {
                print("   Tampered callback rejected: \(error.localizedDescription)")
            }

            // 3. Exchange the code for a token.
            let token = try await oauth.exchange(code: code, verifier: pkce.verifier)
            print("3. Token acquired, scopes \(token.scopes.joined(separator: " ")), expires in an hour")

            // 4. Hand it to an authenticator, then let eight callers all need a refresh at once.
            let expired = OAuth2Token(
                accessToken: token.accessToken,
                refreshToken: token.refreshToken,
                scopes: token.scopes,
                expiresAt: Date().addingTimeInterval(-10)
            )
            let authenticator = OAuth2Authenticator(client: oauth, store: InMemoryTokenStore(token: expired))

            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { _ = try? await authenticator.validToken() }
                }
            }
            print("4. Eight callers needed a token at once; the provider saw \(await provider.refreshes()) refresh")

            // 5. The middleware attaches the current token to outgoing requests.
            let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/me")!)
            if let beforeSend = authenticator.middleware.beforeSend {
                let authorized = try await beforeSend(request, "user:1")
                print("5. Middleware attached: \(authorized.headers["Authorization"] ?? "nothing")")
            }

            // 6. Some APIs authenticate with a shared secret instead.
            let signer = HMACRequestSigner(keyID: "key-1", secret: Data("shared-secret".utf8))
            let signed = signer.signed(request, timestamp: Date(), nonce: UUID().uuidString)
            print("6. Signed request header: \(signed.headers["Authorization"]?.prefix(48) ?? "")…")
        } catch {
            print("Example failed: \(error.localizedDescription)")
        }
    }
}
