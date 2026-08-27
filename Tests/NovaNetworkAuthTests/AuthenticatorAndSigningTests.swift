import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkAuth

#if canImport(CryptoKit)
import CryptoKit
#endif

// Requirements: FR-11 (token stores), FR-12 (single-flight refresh), FR-13 (middleware),
// FR-14/NFR-5 (HMAC signing), DR-1/DR-2 (storage defaults), AR-1.
// Tests: T-7.1, T-7.2, T-8.1, T-8.2, T-9.1, T-9.2.

// MARK: - T-7.x stores

@Suite
struct TokenStoreTests {
    @Test
    func theInMemoryStoreRoundTripsAndClears() async throws {
        let store = InMemoryTokenStore()
        #expect(try await store.load() == nil)

        try await store.save(OAuth2Token(accessToken: "at-1", refreshToken: "rt-1"))
        #expect(try await store.load()?.accessToken == "at-1")

        try await store.clear()
        #expect(try await store.load() == nil)
    }

    @Test
    func anAuthenticatorPersistsNothingByDefault() async throws {
        // Default storage is memory: a library that persists credentials unless told otherwise is a
        // library that persists them in the one app that forgot to look.
        let authenticator = OAuth2Authenticator(client: client(ScriptedTokenTransport(json: "{}")))

        #expect(authenticator.store is InMemoryTokenStore)
    }

    #if canImport(Security)
    @Test
    func theKeychainStoreFilesItemsUnderItsServiceAndAccount() {
        let store = KeychainTokenStore(service: "com.example.app", account: "user-1", accessGroup: "group.example")
        let query = store.baseQuery()

        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.example.app")
        #expect(query[kSecAttrAccount as String] as? String == "user-1")
        #expect(query[kSecAttrAccessGroup as String] as? String == "group.example")
    }

    @Test
    func anAccessGroupIsOmittedWhenNoneWasGiven() {
        let query = KeychainTokenStore(service: "s", account: "a").baseQuery()

        #expect(query[kSecAttrAccessGroup as String] == nil)
    }

    @Test
    func aKeychainFailureDescribesItsOperationAndStatus() {
        let error = KeychainTokenStore.KeychainError(operation: "read", status: -25300)

        #expect(error.errorDescription == "Keychain read failed with status -25300.")
    }
    #endif
}

// MARK: - T-8.x authenticator

@Suite
struct OAuth2AuthenticatorTests {
    private func expiredToken() -> OAuth2Token {
        OAuth2Token(accessToken: "at-old", refreshToken: "rt-1", expiresAt: epoch.addingTimeInterval(-10))
    }

    @Test
    func avalidTokenRefreshesOnlyWhenTheStoredOneIsExpired() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token":"at-new","expires_in":3600}"#)
        let store = InMemoryTokenStore(token: OAuth2Token(accessToken: "at-fresh", refreshToken: "rt-1", expiresAt: epoch.addingTimeInterval(3600)))
        let authenticator = OAuth2Authenticator(client: client(transport), store: store, now: { epoch })

        #expect(try await authenticator.validToken().accessToken == "at-fresh")
        #expect(await transport.recorded().isEmpty, "a live token must not trigger a refresh")

        try await store.save(expiredToken())
        #expect(try await authenticator.validToken().accessToken == "at-new")
        #expect(await transport.recorded().count == 1)
    }

    @Test
    func concurrentCallersShareOneRefresh() async throws {
        // The actor alone is not enough: it suspends at the network call, so a second caller would
        // otherwise start a second refresh and one of the two tokens would be thrown away.
        let transport = ScriptedTokenTransport([
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"at-new","expires_in":3600}"#.utf8))),
            .success(NetworkResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"at-second","expires_in":3600}"#.utf8))),
        ])
        let authenticator = OAuth2Authenticator(
            client: client(transport),
            store: InMemoryTokenStore(token: expiredToken()),
            now: { epoch }
        )

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try await authenticator.validToken().accessToken }
            }
            var seen: [String] = []
            for try await token in group { seen.append(token) }
            return seen
        }

        #expect(Set(tokens) == ["at-new"], "every caller gets the same refreshed token")
        #expect(await transport.recorded().count == 1, "one refresh, not eight")
    }

    @Test
    func aRejectedGrantClearsTheDeadTokenSoTheAppCanAskForASignIn() async throws {
        let transport = ScriptedTokenTransport(json: #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#)
        let store = InMemoryTokenStore(token: expiredToken())
        let authenticator = OAuth2Authenticator(client: client(transport), store: store, now: { epoch })

        await #expect(throws: OAuth2Error.self) {
            try await authenticator.validToken()
        }
        #expect(try await store.load() == nil, "keeping a revoked token makes every later request fail the same way")
    }

    @Test
    func aRefreshFailureThatIsNotInvalidGrantKeepsTheToken() async throws {
        let transport = ScriptedTokenTransport([.failure(NetworkError.cancelled)])
        let store = InMemoryTokenStore(token: expiredToken())
        let authenticator = OAuth2Authenticator(client: client(transport), store: store, now: { epoch })

        await #expect(throws: (any Error).self) { try await authenticator.validToken() }
        #expect(try await store.load()?.accessToken == "at-old", "a network blip is not a revoked session")
    }

    @Test
    func signingOutForgetsEverything() async throws {
        let store = InMemoryTokenStore(token: expiredToken())
        let authenticator = OAuth2Authenticator(client: client(ScriptedTokenTransport(json: "{}")), store: store, now: { epoch })

        try await authenticator.signOut()

        #expect(try await store.load() == nil)
        await #expect(throws: OAuth2Error.notAuthenticated) { try await authenticator.validToken() }
    }

    @Test
    func theRefreshProviderHandsTheClientAFreshAuthorizationHeader() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token":"at-new","expires_in":3600}"#)
        let authenticator = OAuth2Authenticator(
            client: client(transport),
            store: InMemoryTokenStore(token: expiredToken()),
            now: { epoch }
        )

        let headers = try await authenticator.refreshProvider.refreshHeaders("user:1")

        #expect(headers["Authorization"] == "Bearer at-new")
    }

    @Test
    func theMiddlewareAttachesTheTokenAndLeavesOtherRequestsAlone() async throws {
        let authenticator = OAuth2Authenticator(
            client: client(ScriptedTokenTransport(json: "{}")),
            store: InMemoryTokenStore(token: OAuth2Token(accessToken: "at-1", expiresAt: epoch.addingTimeInterval(3600))),
            now: { epoch }
        )
        let middleware = authenticator.middleware
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/me")!)

        let beforeSend = try #require(middleware.beforeSend)
        let signed = try await beforeSend(request, "user:1")
        #expect(signed.headers["Authorization"] == "Bearer at-1")

        // A caller who set the header knows something the middleware does not.
        let explicit = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/me")!,
            headers: ["Authorization": "Bearer caller-supplied"]
        )
        let explicitResult = try await beforeSend(explicit, nil)
        #expect(explicitResult.headers["Authorization"] == "Bearer caller-supplied")
    }

    @Test
    func aRequestMadeWhileSignedOutGoesOutUnauthenticated() async throws {
        // Failing locally would break endpoints that need no token at all; letting the server answer
        // is both more useful and more honest.
        let authenticator = OAuth2Authenticator(client: client(ScriptedTokenTransport(json: "{}")), now: { epoch })
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/public")!)

        let beforeSend = try #require(authenticator.middleware.beforeSend)
        let sent = try await beforeSend(request, nil)

        #expect(sent.headers["Authorization"] == nil)
    }
}

// MARK: - T-9.x signing

@Suite
struct RequestSigningTests {
    private let signer = HMACRequestSigner(keyID: "key-1", secret: Data("shared-secret".utf8))
    private let request = APIRequest(
        method: .post,
        url: URL(string: "https://api.example.com/orders")!,
        queryItems: [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")],
        headers: ["Content-Type": "application/json"],
        body: Data(#"{"total":10}"#.utf8)
    )

    @Test
    func theCanonicalStringIsTheDocumentedSixLines() {
        let canonical = signer.canonicalString(for: request, timestamp: epoch, nonce: "nonce-1")
        let lines = canonical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.count == 6)
        #expect(lines[0] == "POST")
        #expect(lines[1] == "/orders")
        #expect(lines[2] == "a=1&b=2", "query items are sorted so a reordering client still verifies")
        #expect(lines[3] == String(Int(epoch.timeIntervalSince1970)))
        #expect(lines[4] == "nonce-1")
        #expect(lines[5] == SHA256Util.hex(Data(#"{"total":10}"#.utf8)))
    }

    @Test
    func theSameRequestSignsTheSameWayEveryTime() {
        let first = signer.signature(for: request, timestamp: epoch, nonce: "nonce-1")
        let second = signer.signature(for: request, timestamp: epoch, nonce: "nonce-1")

        #expect(first == second)
        #expect(first.count == 64, "hex-encoded SHA-256")
    }

    @Test
    func anyChangeToTheRequestChangesTheSignature() {
        let baseline = signer.signature(for: request, timestamp: epoch, nonce: "nonce-1")
        let differentBody = APIRequest(
            method: .post,
            url: request.url,
            queryItems: request.queryItems,
            headers: request.headers,
            body: Data(#"{"total":11}"#.utf8)
        )

        #expect(signer.signature(for: differentBody, timestamp: epoch, nonce: "nonce-1") != baseline)
        #expect(signer.signature(for: request, timestamp: epoch.addingTimeInterval(1), nonce: "nonce-1") != baseline)
        #expect(signer.signature(for: request, timestamp: epoch, nonce: "nonce-2") != baseline)
        #expect(HMACRequestSigner(keyID: "key-1", secret: Data("other".utf8))
            .signature(for: request, timestamp: epoch, nonce: "nonce-1") != baseline)
    }

    @Test
    func aSignedRequestCarriesEverythingTheServerNeedsToVerify() {
        let signed = signer.signed(request, timestamp: epoch, nonce: "nonce-1")
        let authorization = signed.headers["Authorization"] ?? ""

        #expect(authorization.hasPrefix("HMAC-SHA256 keyId=key-1,"))
        #expect(authorization.contains("nonce=nonce-1"))
        #expect(authorization.contains("signature=\(signer.signature(for: request, timestamp: epoch, nonce: "nonce-1"))"))
        #expect(signed.headers["X-Nova-Timestamp"] == String(Int(epoch.timeIntervalSince1970)))
        #expect(signed.headers["X-Nova-Nonce"] == "nonce-1")
        #expect(signed.headers["Content-Type"] == "application/json", "existing headers survive")
    }

    @Test
    func theMiddlewareSignsEveryOutgoingRequest() async throws {
        let middleware = signer.middleware(now: { epoch }, nonce: { "fixed-nonce" })

        let beforeSend = try #require(middleware.beforeSend)
        let sent = try await beforeSend(request, nil)

        #expect(sent.headers["X-Nova-Nonce"] == "fixed-nonce")
        #expect(sent.headers["Authorization"]?.contains("signature=") == true)
    }

    #if canImport(CryptoKit)
    @Test
    func thePortableHMACAgreesWithCryptoKitOnEveryTestedInput() {
        // Asserting a vector recalled from memory would pass for the wrong reasons. Comparing the
        // two implementations does not.
        for _ in 0..<200 {
            let key = Data((0..<Int.random(in: 1...200)).map { _ in UInt8.random(in: 0...255) })
            let message = Data((0..<Int.random(in: 0...500)).map { _ in UInt8.random(in: 0...255) })

            let portable = HMACSHA256.portableAuthenticate(message, key: key)
            let platform = Data(CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(
                for: message,
                using: SymmetricKey(data: key)
            ))

            #expect(portable == platform)
        }
    }

    @Test
    func theTwoImplementationsAgreeOnKeysLongerThanTheBlockSize() {
        // A key over 64 bytes is hashed first; getting that branch wrong is the classic HMAC bug.
        let key = Data(repeating: 0xAB, count: 200)
        let message = Data("message".utf8)

        #expect(HMACSHA256.portableAuthenticate(message, key: key) == HMACSHA256.authenticate(message, key: key))
    }
    #endif
}

// MARK: - Error descriptions and small surfaces

@Suite
struct OAuth2ErrorTests {
    @Test
    func everyFailureExplainsItselfWithoutQuotingACredential() {
        let errors: [OAuth2Error] = [
            .server(code: "invalid_client", description: nil, uri: nil),
            .server(code: "invalid_grant", description: "Expired", uri: "https://docs"),
            .invalidVerifier(reason: "too short"),
            .stateMismatch(expected: "a", received: "b"),
            .missingAuthorizationCode,
            .missingEndpoint(name: "tokenEndpoint"),
            .invalidResponse(reason: "not JSON"),
            .deviceAuthorizationExpired,
            .deviceAuthorizationDenied,
            .notAuthenticated,
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "\(error) needs a description")
            #expect(!description.contains("access_token"))
            #expect(!description.contains("Bearer"))
        }
    }

    @Test
    func aStateMismatchDoesNotEchoTheValuesIntoTheMessage() {
        // Neither value belongs in a log: one is ours, the other is an attacker's.
        let description = OAuth2Error.stateMismatch(expected: "our-state", received: "attacker-state").errorDescription ?? ""

        #expect(!description.contains("our-state"))
        #expect(!description.contains("attacker-state"))
    }

    @Test
    func anEnvelopeIsRecognizedOnlyWhenItReallyIsOne() {
        #expect(OAuth2Error.fromEnvelope(Data(#"{"error":"invalid_grant"}"#.utf8)) != nil)
        #expect(OAuth2Error.fromEnvelope(Data(#"{"access_token":"at"}"#.utf8)) == nil)
        #expect(OAuth2Error.fromEnvelope(Data("not json".utf8)) == nil)
        #expect(OAuth2Error.fromEnvelope(Data()) == nil)
    }
}

@Suite
struct AuthSmallSurfaceTests {
    @Test
    func aConfigurationWithoutRedirectOrScopesOmitsThemFromTheURL() throws {
        let config = OAuth2Configuration(
            clientID: "c",
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize?tenant=acme")!,
            tokenEndpoint: URL(string: "https://auth.example.com/token")!
        )
        let url = try client(ScriptedTokenTransport(json: "{}"), configuration: config)
            .authorizationURL(state: "s", challenge: PKCEChallenge.generate())
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(!items.contains { $0.name == "redirect_uri" })
        #expect(!items.contains { $0.name == "scope" })
        #expect(items.contains { $0.name == "tenant" && $0.value == "acme" }, "existing query items survive")
        #expect(config.expiryLeeway == 60)
    }

    @Test
    func storingATokenMakesItTheCurrentOne() async throws {
        let authenticator = OAuth2Authenticator(client: client(ScriptedTokenTransport(json: "{}")), now: { epoch })

        #expect(try await authenticator.currentToken() == nil)
        try await authenticator.setToken(OAuth2Token(accessToken: "at-1"))
        #expect(try await authenticator.currentToken()?.accessToken == "at-1")
    }

    @Test
    func forcingARefreshWithNoTokenSaysSo() async {
        let authenticator = OAuth2Authenticator(client: client(ScriptedTokenTransport(json: "{}")), now: { epoch })

        await #expect(throws: OAuth2Error.notAuthenticated) { try await authenticator.forceRefresh() }
    }

    @Test
    func aSignerCanUseADifferentHeaderAndScheme() {
        let signer = HMACRequestSigner(
            keyID: "k",
            secret: Data("s".utf8),
            headerName: "X-Signature",
            scheme: "ACME1"
        )
        let signed = signer.signed(
            APIRequest(method: .get, url: URL(string: "https://api.example.com/x")!),
            timestamp: epoch,
            nonce: "n"
        )

        #expect(signed.headers["X-Signature"]?.hasPrefix("ACME1 keyId=k,") == true)
        #expect(signed.headers["Authorization"] == nil)
    }

    @Test
    func hmacHexIsTheHexOfTheAuthenticationCode() {
        let message = Data("message".utf8)
        let key = Data("key".utf8)

        #expect(HMACSHA256.hex(message, key: key) == HMACSHA256.authenticate(message, key: key).map { String(format: "%02x", $0) }.joined())
        #expect(HMACSHA256.hex(message, key: key).count == 64)
    }

    @Test
    func aRequestWithNoBodyHashesTheEmptyBody() {
        let signer = HMACRequestSigner(keyID: "k", secret: Data("s".utf8))
        let canonical = signer.canonicalString(
            for: APIRequest(method: .get, url: URL(string: "https://api.example.com/x")!),
            timestamp: epoch,
            nonce: "n"
        )

        #expect(canonical.hasSuffix(SHA256Util.hex(Data())))
    }
}
