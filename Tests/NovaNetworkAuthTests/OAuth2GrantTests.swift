import Foundation
import Testing
import NovaNetworkCore
@testable import NovaNetworkAuth

// Requirements: FR-1 (shared SHA-256), FR-2 (PKCE), FR-3/FR-4 (authorization URL and callback),
// FR-5…FR-8 (grants and error envelopes), FR-9 (device flow), FR-10 (expiry).
// Tests: T-1.1, T-2.1, T-3.1, T-3.2, T-4.1…T-4.4, T-5.1, T-6.1.

let epoch = Date(timeIntervalSince1970: 1_800_000_000)

/// Answers token requests from a script and records what was asked.
actor ScriptedTokenTransport: NetworkTransport {
    private var responses: [Result<NetworkResponse, any Error>]
    private(set) var requests: [APIRequest] = []

    init(_ responses: [Result<NetworkResponse, any Error>]) {
        self.responses = responses
    }

    init(json: String, status: Int = 200) {
        responses = [.success(NetworkResponse(statusCode: status, headers: [:], body: Data(json.utf8)))]
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        return try responses.removeFirst().get()
    }

    func recorded() -> [APIRequest] { requests }
    func bodies() -> [String] { requests.map { String(decoding: $0.body ?? Data(), as: UTF8.self) } }
}

func configuration(
    clientSecret: String? = nil,
    scopes: [String] = ["profile", "email"]
) -> OAuth2Configuration {
    OAuth2Configuration(
        clientID: "client-123",
        clientSecret: clientSecret,
        authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
        tokenEndpoint: URL(string: "https://auth.example.com/token")!,
        deviceAuthorizationEndpoint: URL(string: "https://auth.example.com/device")!,
        redirectURI: URL(string: "novaapp://callback")!,
        scopes: scopes
    )
}

func client(_ transport: ScriptedTokenTransport, configuration config: OAuth2Configuration = configuration()) -> OAuth2Client {
    OAuth2Client(configuration: config, transport: transport, now: { epoch })
}

// MARK: - T-1.1, T-2.1 PKCE

@Suite
struct PKCETests {
    @Test
    func aGeneratedVerifierIsTheRecommendedLengthAndAlphabet() {
        for _ in 0..<20 {
            let pkce = PKCEChallenge.generate()

            #expect(pkce.verifier.count == 43)
            #expect(pkce.verifier.allSatisfy { PKCEChallenge.allowedCharacters.contains($0) })
            #expect(pkce.method == "S256")
        }
    }

    @Test
    func generatedVerifiersDifferEveryTime() {
        let verifiers = Set((0..<50).map { _ in PKCEChallenge.generate().verifier })

        #expect(verifiers.count == 50, "a predictable verifier defeats the point of PKCE")
    }

    @Test
    func theChallengeIsBase64URLOfTheSHA256OfTheVerifier() throws {
        let pkce = try PKCEChallenge(verifier: String(repeating: "a", count: 43))
        let expected = PKCEChallenge.base64URLEncoded(SHA256Util.digest(Data(pkce.verifier.utf8)))

        #expect(pkce.challenge == expected)
        #expect(!pkce.challenge.contains("="), "base64url carries no padding")
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))
    }

    @Test
    func theSharedSHA256IsTheOneCoreExposes() {
        // The client's fingerprinting and this module's PKCE hash through the same implementation;
        // a second copy of cryptography is how one of the copies ends up wrong.
        #expect(SHA256Util.digest(Data("abc".utf8)).count == 32)
        #expect(SHA256Util.hex(Data("abc".utf8)) == SHA256Util.digest(Data("abc".utf8)).map { String(format: "%02x", $0) }.joined())
    }

    @Test(arguments: [
        String(repeating: "a", count: 42),
        String(repeating: "a", count: 129),
        String(repeating: "!", count: 43),
        "",
    ])
    func aVerifierOutsideTheSpecIsRejected(verifier: String) {
        #expect(throws: OAuth2Error.self) {
            try PKCEChallenge(verifier: verifier)
        }
    }
}

// MARK: - T-3.1, T-3.2 authorization URL and callback

@Suite
struct AuthorizationURLTests {
    @Test
    func theURLCarriesEverythingTheProviderNeeds() throws {
        let pkce = try PKCEChallenge(verifier: String(repeating: "b", count: 43))
        let url = try client(ScriptedTokenTransport(json: "{}")).authorizationURL(state: "state-1", challenge: pkce)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let value = { (name: String) in items.first { $0.name == name }?.value }

        #expect(url.host == "auth.example.com")
        #expect(value("response_type") == "code")
        #expect(value("client_id") == "client-123")
        #expect(value("state") == "state-1")
        #expect(value("code_challenge") == pkce.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("redirect_uri") == "novaapp://callback")
        #expect(value("scope") == "profile email")
    }

    @Test
    func providerSpecificParametersAreCarriedThrough() throws {
        var config = configuration()
        config.additionalAuthorizationParameters = ["audience": "https://api.example.com", "prompt": "consent"]
        let url = try client(ScriptedTokenTransport(json: "{}"), configuration: config)
            .authorizationURL(state: "s", challenge: PKCEChallenge.generate())
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(items.contains { $0.name == "audience" && $0.value == "https://api.example.com" })
        #expect(items.contains { $0.name == "prompt" && $0.value == "consent" })
    }

    @Test
    func aMissingAuthorizationEndpointIsReportedByName() {
        var config = configuration()
        config.authorizationEndpoint = nil

        #expect(throws: OAuth2Error.missingEndpoint(name: "authorizationEndpoint")) {
            try client(ScriptedTokenTransport(json: "{}"), configuration: config)
                .authorizationURL(state: "s", challenge: PKCEChallenge.generate())
        }
    }

    @Test
    func theCallbackYieldsItsCode() throws {
        let callback = URL(string: "novaapp://callback?code=auth-code-1&state=state-1")!

        #expect(try client(ScriptedTokenTransport(json: "{}")).authorizationCode(from: callback, expectedState: "state-1") == "auth-code-1")
    }

    @Test
    func aStateMismatchIsRejectedBeforeTheCodeIsEvenRead() {
        // This is what stops an attacker's authorization code from being redeemed in the victim's
        // session, so it is checked first and the code is never returned.
        let callback = URL(string: "novaapp://callback?code=attacker-code&state=wrong")!

        #expect(throws: OAuth2Error.stateMismatch(expected: "state-1", received: "wrong")) {
            try client(ScriptedTokenTransport(json: "{}")).authorizationCode(from: callback, expectedState: "state-1")
        }
    }

    @Test
    func anErrorRedirectBecomesTheServersError() {
        let callback = URL(string: "novaapp://callback?error=access_denied&error_description=User%20said%20no&state=state-1")!

        #expect(throws: OAuth2Error.server(code: "access_denied", description: "User said no", uri: nil)) {
            try client(ScriptedTokenTransport(json: "{}")).authorizationCode(from: callback, expectedState: "state-1")
        }
    }

    @Test
    func aCallbackWithNeitherCodeNorErrorIsRejected() {
        let callback = URL(string: "novaapp://callback?state=state-1")!

        #expect(throws: OAuth2Error.missingAuthorizationCode) {
            try client(ScriptedTokenTransport(json: "{}")).authorizationCode(from: callback, expectedState: "state-1")
        }
    }
}

// MARK: - T-4.x grants

@Suite
struct GrantTests {
    @Test
    func theAuthorizationCodeGrantSendsWhatRFC6749Requires() async throws {
        let transport = ScriptedTokenTransport(
            json: #"{"access_token":"at-1","token_type":"Bearer","refresh_token":"rt-1","expires_in":3600,"scope":"profile email"}"#
        )

        let token = try await client(transport).exchange(code: "auth-code-1", verifier: "verifier-1")

        #expect(token.accessToken == "at-1")
        #expect(token.refreshToken == "rt-1")
        #expect(token.scopes == ["profile", "email"])
        #expect(token.expiresAt == epoch.addingTimeInterval(3600))

        let request = try #require(await transport.recorded().first)
        let body = try #require(await transport.bodies().first)
        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://auth.example.com/token")
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(body.contains("grant_type=authorization_code"))
        #expect(body.contains("code=auth-code-1"))
        #expect(body.contains("code_verifier=verifier-1"))
        #expect(body.contains("redirect_uri=novaapp%3A%2F%2Fcallback"))
    }

    @Test
    func aConfidentialClientAuthenticatesWithBasicCredentials() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token":"at-1"}"#)

        _ = try await client(transport, configuration: configuration(clientSecret: "s3cret")).clientCredentialsToken()

        let request = try #require(await transport.recorded().first)
        let expected = Data("client-123:s3cret".utf8).base64EncodedString()
        #expect(request.headers["Authorization"] == "Basic \(expected)")
    }

    @Test
    func refreshingKeepsTheOldRefreshTokenWhenTheServerOmitsANewOne() async throws {
        // Providers routinely omit it, meaning "keep using the one you have". Dropping it is how a
        // session ends an hour later for no visible reason.
        let transport = ScriptedTokenTransport(json: #"{"access_token":"at-2","expires_in":3600}"#)
        let existing = OAuth2Token(accessToken: "at-1", refreshToken: "rt-1", expiresAt: epoch)

        let refreshed = try await client(transport).refresh(existing)

        #expect(refreshed.accessToken == "at-2")
        #expect(refreshed.refreshToken == "rt-1")
    }

    @Test
    func aNewRefreshTokenReplacesTheOldOne() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token":"at-2","refresh_token":"rt-2"}"#)
        let existing = OAuth2Token(accessToken: "at-1", refreshToken: "rt-1")

        #expect(try await client(transport).refresh(existing).refreshToken == "rt-2")
    }

    @Test
    func refreshingWithoutARefreshTokenSaysTheUserMustSignInAgain() async {
        let transport = ScriptedTokenTransport(json: "{}")

        await #expect(throws: OAuth2Error.notAuthenticated) {
            try await client(transport).refresh(OAuth2Token(accessToken: "at-1"))
        }
    }

    @Test
    func theClientCredentialsGrantRequestsItsScopes() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token":"at-1","token_type":"Bearer"}"#)

        let token = try await client(transport).clientCredentialsToken()

        #expect(token.accessToken == "at-1")
        let body = try #require(await transport.bodies().first)
        #expect(body.contains("grant_type=client_credentials"))
        #expect(body.contains("scope=profile%20email"))
    }

    @Test
    func anErrorEnvelopeBecomesATypedErrorWhateverTheStatus() async {
        let envelope = #"{"error":"invalid_grant","error_description":"Code already used","error_uri":"https://docs.example.com/e"}"#

        // Some providers answer 400, some answer 200 with an envelope. Both mean the same thing.
        let asFailure = ScriptedTokenTransport([
            .failure(NetworkError.httpStatus(code: 400, headers: [:], body: Data(envelope.utf8))),
        ])
        let asSuccess = ScriptedTokenTransport(json: envelope)

        for transport in [asFailure, asSuccess] {
            await #expect(throws: OAuth2Error.server(
                code: "invalid_grant",
                description: "Code already used",
                uri: "https://docs.example.com/e"
            )) {
                try await client(transport).exchange(code: "c", verifier: "v")
            }
        }
    }

    @Test
    func anErrorMessageNamesTheFailureWithoutQuotingCredentials() {
        let error = OAuth2Error.server(code: "invalid_grant", description: "Code already used", uri: nil)
        let description = try! #require(error.errorDescription)

        #expect(description.contains("invalid_grant"))
        #expect(description.contains("Code already used"))
        #expect(!description.contains("access_token"))
    }

    @Test
    func aResponseThatIsNotATokenIsRejected() async {
        await #expect(throws: OAuth2Error.self) {
            try await client(ScriptedTokenTransport(json: #"{"nothing":"useful"}"#)).clientCredentialsToken()
        }
        await #expect(throws: OAuth2Error.self) {
            try await client(ScriptedTokenTransport(json: "not json at all")).clientCredentialsToken()
        }
    }

    @Test
    func aTransportFailureWithNoEnvelopePropagatesUnchanged() async {
        let transport = ScriptedTokenTransport([.failure(NetworkError.cancelled)])

        await #expect(throws: NetworkError.cancelled) {
            try await client(transport).clientCredentialsToken()
        }
    }

    @Test
    func formEncodingEscapesEverythingOutsideTheUnreservedSet() {
        let encoded = OAuth2Client.formEncoded(["redirect_uri": "novaapp://cb?x=1", "scope": "a b"])

        #expect(encoded == "redirect_uri=novaapp%3A%2F%2Fcb%3Fx%3D1&scope=a%20b")
    }
}

// MARK: - T-5.1 device flow

@Suite
struct DeviceFlowTests {
    private let deviceJSON = #"""
    {"device_code":"dc-1","user_code":"WDJB-MJHT","verification_uri":"https://example.com/device",
     "verification_uri_complete":"https://example.com/device?user_code=WDJB-MJHT","expires_in":1800,"interval":5}
    """#

    @Test
    func theDeviceAuthorizationIsReadInFull() async throws {
        let transport = ScriptedTokenTransport(json: deviceJSON)

        let authorization = try await client(transport).requestDeviceAuthorization()

        #expect(authorization.deviceCode == "dc-1")
        #expect(authorization.userCode == "WDJB-MJHT")
        #expect(authorization.verificationURI.absoluteString == "https://example.com/device")
        #expect(authorization.verificationURIComplete?.query == "user_code=WDJB-MJHT")
        #expect(authorization.expiresAt == epoch.addingTimeInterval(1800))
        #expect(authorization.interval == 5)
    }

    @Test
    func pollingWaitsThroughPendingAndBacksOffWhenToldTo() async throws {
        let pending = NetworkResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"authorization_pending"}"#.utf8))
        let slowDown = NetworkResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"slow_down"}"#.utf8))
        let issued = NetworkResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"at-1"}"#.utf8))
        let transport = ScriptedTokenTransport([.success(pending), .success(slowDown), .success(issued)])

        let authorization = DeviceAuthorization(
            deviceCode: "dc-1",
            userCode: "WDJB-MJHT",
            verificationURI: URL(string: "https://example.com/device")!,
            expiresAt: epoch.addingTimeInterval(1800),
            interval: 5
        )

        let waits = WaitRecorder()
        let token = try await client(transport).pollForToken(authorization) { await waits.record($0) }

        #expect(token.accessToken == "at-1")
        // RFC 8628: slow_down means add five seconds to the interval, from then on.
        #expect(await waits.recorded == [5, 5, 10])
    }

    @Test(arguments: [
        ("expired_token", OAuth2Error.deviceAuthorizationExpired),
        ("access_denied", OAuth2Error.deviceAuthorizationDenied),
    ])
    func aTerminalDeviceErrorStopsPolling(code: String, expected: OAuth2Error) async {
        let transport = ScriptedTokenTransport(json: #"{"error":"\#(code)"}"#)
        let authorization = DeviceAuthorization(
            deviceCode: "dc-1",
            userCode: "U",
            verificationURI: URL(string: "https://example.com/device")!,
            expiresAt: epoch.addingTimeInterval(1800),
            interval: 1
        )

        await #expect(throws: expected) {
            try await client(transport).pollForToken(authorization) { _ in }
        }
    }

    @Test
    func pollingStopsOnceTheDeviceCodeHasExpired() async {
        let transport = ScriptedTokenTransport(json: #"{"error":"authorization_pending"}"#)
        let authorization = DeviceAuthorization(
            deviceCode: "dc-1",
            userCode: "U",
            verificationURI: URL(string: "https://example.com/device")!,
            expiresAt: epoch.addingTimeInterval(-1),
            interval: 1
        )

        await #expect(throws: OAuth2Error.deviceAuthorizationExpired) {
            try await client(transport).pollForToken(authorization) { _ in }
        }
    }

    @Test
    func aMissingDeviceEndpointIsReportedByName() async {
        var config = configuration()
        config.deviceAuthorizationEndpoint = nil

        await #expect(throws: OAuth2Error.missingEndpoint(name: "deviceAuthorizationEndpoint")) {
            try await client(ScriptedTokenTransport(json: "{}"), configuration: config).requestDeviceAuthorization()
        }
    }
}

/// Records how long each poll waited.
actor WaitRecorder {
    private(set) var recorded: [TimeInterval] = []

    func record(_ interval: TimeInterval) {
        recorded.append(interval)
    }
}

// MARK: - T-6.1 token expiry

@Suite
struct OAuth2TokenTests {
    @Test
    func aTokenIsExpiredEarlyByItsLeeway() {
        let token = OAuth2Token(accessToken: "at", expiresAt: epoch.addingTimeInterval(100))

        #expect(!token.isExpired(now: epoch, leeway: 60))
        #expect(token.isExpired(now: epoch.addingTimeInterval(41), leeway: 60))
        #expect(token.isExpired(now: epoch.addingTimeInterval(101), leeway: 0))
        #expect(!token.isExpired(now: epoch.addingTimeInterval(99), leeway: 0))
    }

    @Test
    func aTokenWithNoStatedExpiryIsNeverTreatedAsExpired() {
        // The provider chose not to say. Guessing would refresh working credentials on a timer.
        let token = OAuth2Token(accessToken: "at")

        #expect(!token.isExpired(now: epoch.addingTimeInterval(100_000), leeway: 60))
    }

    @Test
    func theAuthorizationHeaderUsesTheProvidersTokenType() {
        #expect(OAuth2Token(accessToken: "at").authorizationHeaderValue == "Bearer at")
        #expect(OAuth2Token(accessToken: "at", tokenType: "DPoP").authorizationHeaderValue == "DPoP at")
    }

    @Test
    func expiresInIsAcceptedAsANumberOrAString() throws {
        let numeric = try OAuth2Token.decode(from: Data(#"{"access_token":"a","expires_in":60}"#.utf8), now: epoch)
        let text = try OAuth2Token.decode(from: Data(#"{"access_token":"a","expires_in":"60"}"#.utf8), now: epoch)

        #expect(numeric.expiresAt == epoch.addingTimeInterval(60))
        #expect(text.expiresAt == epoch.addingTimeInterval(60))
    }

    @Test
    func aTokenRoundTripsThroughCodable() throws {
        let token = OAuth2Token(
            accessToken: "at",
            tokenType: "Bearer",
            refreshToken: "rt",
            scopes: ["a", "b"],
            expiresAt: epoch
        )
        let decoded = try JSONDecoder().decode(OAuth2Token.self, from: JSONEncoder().encode(token))

        #expect(decoded == token)
    }
}
