import Foundation
import Testing
import NovaNetworkCore
@testable import NovaNetworkAuth

// Requirements: FR-OAUTH-SHAPE-1...3 (request style), FR-OAUTH-EXCHANGE-1...3 (injected exchange).

/// Records the grants it is asked to perform and answers with a scripted token.
private actor GrantRecorder {
    private(set) var grants: [OAuth2Grant] = []
    private let token: OAuth2Token

    init(token: OAuth2Token) {
        self.token = token
    }

    func perform(_ grant: OAuth2Grant) -> OAuth2Token {
        grants.append(grant)
        return token
    }

    func recorded() -> [OAuth2Grant] { grants }
}

// MARK: - Request style

@Suite
struct OAuth2TokenRequestStyleTests {
    private let token = OAuth2Token(accessToken: "old", refreshToken: "refresh-1")

    @Test
    func theDefaultStyleIsStillRFC6749() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token": "new"}"#)

        _ = try await client(transport).refresh(token)

        let request = try #require(await transport.recorded().first)
        #expect(request.queryItems.isEmpty)
        #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(
            String(decoding: request.body ?? Data(), as: UTF8.self)
                == "client_id=client-123&grant_type=refresh_token&refresh_token=refresh-1"
        )
    }

    @Test
    func aJSONBodyWithGrantTypeInTheQueryMatchesGoTrue() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token": "new"}"#)
        var config = configuration()
        config.tokenRequestStyle = .init(
            bodyEncoding: .json,
            grantTypePlacement: .query,
            additionalHeaders: ["apikey": "anon-key"]
        )

        _ = try await client(transport, configuration: config).refresh(token)

        let request = try #require(await transport.recorded().first)
        #expect(request.queryItems == [URLQueryItem(name: "grant_type", value: "refresh_token")])
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["apikey"] == "anon-key")
        #expect(
            String(decoding: request.body ?? Data(), as: UTF8.self)
                == #"{"client_id":"client-123","refresh_token":"refresh-1"}"#
        )
    }

    @Test
    func additionalHeadersAreAppliedAfterTheOnesThisClientSets() async throws {
        let transport = ScriptedTokenTransport(json: #"{"access_token": "new"}"#)
        var config = configuration(clientSecret: "s3cret")
        config.tokenRequestStyle = .init(additionalHeaders: ["Accept": "application/vnd.example+json"])

        _ = try await client(transport, configuration: config).refresh(token)

        let request = try #require(await transport.recorded().first)
        #expect(request.headers["Accept"] == "application/vnd.example+json")
        #expect(request.headers["Authorization"]?.hasPrefix("Basic ") == true)
    }

    @Test
    func theDeviceAuthorizationRequestUsesTheSameStyle() async throws {
        let transport = ScriptedTokenTransport(
            json: #"{"device_code": "d", "user_code": "U", "verification_uri": "https://example.com/device"}"#
        )
        var config = configuration()
        config.tokenRequestStyle = .init(bodyEncoding: .json)

        _ = try await client(transport, configuration: config).requestDeviceAuthorization()

        let request = try #require(await transport.recorded().first)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(
            String(decoding: request.body ?? Data(), as: UTF8.self)
                == #"{"client_id":"client-123","scope":"profile email"}"#
        )
    }

    @Test
    func aStyleWithGrantTypeInTheQueryLeavesARequestThatHasNoneAlone() async throws {
        let transport = ScriptedTokenTransport(
            json: #"{"device_code": "d", "user_code": "U", "verification_uri": "https://example.com/device"}"#
        )
        var config = configuration()
        config.tokenRequestStyle = .init(grantTypePlacement: .query)

        _ = try await client(transport, configuration: config).requestDeviceAuthorization()

        let request = try #require(await transport.recorded().first)
        #expect(request.queryItems.isEmpty)
    }
}

// MARK: - Injected exchange

@Suite
struct OAuth2TokenExchangeTests {
    private let stored = OAuth2Token(accessToken: "old", refreshToken: "refresh-1")

    @Test
    func anInjectedExchangeReplacesTheTokenRequestEntirely() async throws {
        let recorder = GrantRecorder(token: OAuth2Token(accessToken: "new", refreshToken: "refresh-2"))
        let transport = ScriptedTokenTransport([])
        let client = OAuth2Client(
            configuration: configuration(),
            transport: transport,
            tokenExchange: OAuth2TokenExchange { await recorder.perform($0) },
            now: { epoch }
        )

        let refreshed = try await client.refresh(stored)

        #expect(refreshed.accessToken == "new")
        #expect(await transport.recorded().isEmpty)
        let grant = try #require(await recorder.recorded().first)
        #expect(grant.type == "refresh_token")
        #expect(grant.parameters["refresh_token"] == "refresh-1")
        #expect(grant.endpoint == URL(string: "https://auth.example.com/token")!)
        #expect(grant.currentToken == stored)
    }

    @Test
    func anInjectedExchangeStillKeepsARefreshTokenTheProviderOmitted() async throws {
        let recorder = GrantRecorder(token: OAuth2Token(accessToken: "new"))
        let client = OAuth2Client(
            configuration: configuration(),
            transport: ScriptedTokenTransport([]),
            tokenExchange: OAuth2TokenExchange { await recorder.perform($0) },
            now: { epoch }
        )

        let refreshed = try await client.refresh(stored)

        #expect(refreshed.refreshToken == "refresh-1")
    }

    @Test
    func everyOtherGrantReachesTheExchangeToo() async throws {
        let recorder = GrantRecorder(token: OAuth2Token(accessToken: "new"))
        let client = OAuth2Client(
            configuration: configuration(),
            transport: ScriptedTokenTransport([]),
            tokenExchange: OAuth2TokenExchange { await recorder.perform($0) },
            now: { epoch }
        )

        _ = try await client.exchange(code: "code-1", verifier: String(repeating: "a", count: 43))
        _ = try await client.clientCredentialsToken()

        let types = await recorder.recorded().map(\.type)
        #expect(types == ["authorization_code", "client_credentials"])
    }

    @Test
    func theAuthenticatorRefreshesOnceThroughAnInjectedExchange() async throws {
        // `validToken` rather than `forceRefresh`: a caller arriving after the refresh has landed
        // should find a live token and send nothing, which is what makes "one grant" the assertion
        // rather than a race. `forceRefresh` refreshes unconditionally, by design.
        let recorder = GrantRecorder(
            token: OAuth2Token(accessToken: "new", refreshToken: "refresh-2", expiresAt: epoch.addingTimeInterval(3600))
        )
        let store = InMemoryTokenStore(
            token: OAuth2Token(accessToken: "old", refreshToken: "refresh-1", expiresAt: epoch.addingTimeInterval(-10))
        )
        let authenticator = OAuth2Authenticator(
            configuration: configuration(),
            exchange: OAuth2TokenExchange { grant in
                // Yield so the other callers arrive while this one is still in flight; without
                // single-flight refresh each of them would perform a grant of its own.
                await Task.yield()
                return await recorder.perform(grant)
            },
            store: store,
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

        #expect(Set(tokens) == ["new"], "every caller gets the same refreshed token")
        #expect(await recorder.recorded().count == 1, "one grant, not eight")
        #expect(try await store.load()?.refreshToken == "refresh-2")
    }
}
