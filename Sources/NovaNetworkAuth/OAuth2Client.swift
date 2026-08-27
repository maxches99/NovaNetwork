import Foundation
import NovaNetworkClient
import NovaNetworkCore

/// A device authorization, as RFC 8628 defines it.
public struct DeviceAuthorization: Sendable, Equatable {
    /// The code this client polls with. Never shown to the user.
    public let deviceCode: String
    /// The short code the user types on another device.
    public let userCode: String
    /// Where the user goes to enter the code.
    public let verificationURI: URL
    /// A URL carrying the code already filled in, when the provider offers one.
    public let verificationURIComplete: URL?
    /// When the device code stops being usable.
    public let expiresAt: Date
    /// Seconds to wait between polls, as the provider requested.
    public let interval: TimeInterval

    /// Creates a device authorization.
    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        verificationURIComplete: URL? = nil,
        expiresAt: Date,
        interval: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresAt = expiresAt
        self.interval = interval
    }
}

/// Performs OAuth 2.0 grants.
///
/// This is the part every adopter writes by hand: building the authorization URL, validating the
/// callback, posting form-encoded grants, and reading an error envelope that is not shaped like the
/// success response. It performs no storage and holds no state — ``OAuth2Authenticator`` does that.
///
/// Presenting a browser is deliberately not here. It needs a window anchor, it differs per platform,
/// and every app already has an opinion; this supplies the URL to open and parses what comes back.
public struct OAuth2Client: Sendable {
    /// The provider and client details.
    public let configuration: OAuth2Configuration

    private let transport: any NetworkTransport
    private let now: @Sendable () -> Date

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - configuration: Provider and client details.
    ///   - transport: How token requests are sent. A plain ``Transport`` by default.
    ///   - now: Clock used for expiry math. Injectable so tests are deterministic.
    public init(
        configuration: OAuth2Configuration,
        transport: any NetworkTransport = Transport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
    }

    // MARK: - Authorization code

    /// Builds the URL to open for the authorization code grant.
    ///
    /// - Parameters:
    ///   - state: An unguessable value echoed back in the callback. Keep it and pass it to
    ///     ``authorizationCode(from:expectedState:)``.
    ///   - challenge: The PKCE challenge; keep its verifier for the exchange.
    public func authorizationURL(state: String, challenge: PKCEChallenge) throws -> URL {
        guard let endpoint = configuration.authorizationEndpoint else {
            throw OAuth2Error.missingEndpoint(name: "authorizationEndpoint")
        }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OAuth2Error.invalidResponse(reason: "The authorization endpoint is not a valid URL.")
        }

        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "response_type", value: "code"))
        items.append(URLQueryItem(name: "client_id", value: configuration.clientID))
        items.append(URLQueryItem(name: "state", value: state))
        items.append(URLQueryItem(name: "code_challenge", value: challenge.challenge))
        items.append(URLQueryItem(name: "code_challenge_method", value: challenge.method))
        if let redirect = configuration.redirectURI {
            items.append(URLQueryItem(name: "redirect_uri", value: redirect.absoluteString))
        }
        if !configuration.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")))
        }
        for (name, value) in configuration.additionalAuthorizationParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items

        guard let url = components.url else {
            throw OAuth2Error.invalidResponse(reason: "The authorization parameters did not form a valid URL.")
        }
        return url
    }

    /// Extracts the authorization code from a redirect callback.
    ///
    /// - Throws: ``OAuth2Error/stateMismatch(expected:received:)`` when the echoed state is wrong,
    ///   ``OAuth2Error/server(code:description:uri:)`` when the provider redirected with an error,
    ///   and ``OAuth2Error/missingAuthorizationCode`` when the callback carries neither.
    public func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }

        // State is checked before anything else is read: a mismatched callback is an attacker's
        // response, and its code must never be redeemed.
        guard value("state") == expectedState else {
            throw OAuth2Error.stateMismatch(expected: expectedState, received: value("state"))
        }
        if let error = value("error") {
            throw OAuth2Error.server(
                code: error,
                description: value("error_description"),
                uri: value("error_uri")
            )
        }
        guard let code = value("code") else {
            throw OAuth2Error.missingAuthorizationCode
        }
        return code
    }

    /// Exchanges an authorization code and its PKCE verifier for a token.
    public func exchange(code: String, verifier: String) async throws -> OAuth2Token {
        var parameters = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": configuration.clientID,
            "code_verifier": verifier,
        ]
        if let redirect = configuration.redirectURI {
            parameters["redirect_uri"] = redirect.absoluteString
        }
        return try await requestToken(parameters: parameters)
    }

    // MARK: - Refresh and client credentials

    /// Exchanges a refresh token for a new access token.
    ///
    /// When the provider omits a refresh token from its response — which is the norm — the previous
    /// one is retained.
    public func refresh(_ token: OAuth2Token) async throws -> OAuth2Token {
        guard let refreshToken = token.refreshToken else {
            throw OAuth2Error.notAuthenticated
        }
        let refreshed = try await requestToken(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID,
        ])
        return refreshed.retainingRefreshToken(from: token)
    }

    /// Obtains a token with the client credentials grant, for machine-to-machine calls.
    public func clientCredentialsToken() async throws -> OAuth2Token {
        var parameters = [
            "grant_type": "client_credentials",
            "client_id": configuration.clientID,
        ]
        if !configuration.scopes.isEmpty {
            parameters["scope"] = configuration.scopes.joined(separator: " ")
        }
        return try await requestToken(parameters: parameters)
    }

    // MARK: - Device grant

    /// Starts the device authorization grant, for televisions, consoles, and command-line tools.
    public func requestDeviceAuthorization() async throws -> DeviceAuthorization {
        guard let endpoint = configuration.deviceAuthorizationEndpoint else {
            throw OAuth2Error.missingEndpoint(name: "deviceAuthorizationEndpoint")
        }

        var parameters = ["client_id": configuration.clientID]
        if !configuration.scopes.isEmpty {
            parameters["scope"] = configuration.scopes.joined(separator: " ")
        }

        let response = try await send(formRequest(to: endpoint, parameters: parameters))
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String,
              let verificationText = object["verification_uri"] as? String ?? object["verification_url"] as? String,
              let verificationURI = URL(string: verificationText)
        else {
            throw OAuth2Error.invalidResponse(reason: "The device authorization response is missing required fields.")
        }

        return DeviceAuthorization(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: verificationURI,
            verificationURIComplete: (object["verification_uri_complete"] as? String).flatMap(URL.init(string:)),
            expiresAt: now().addingTimeInterval((object["expires_in"] as? Double) ?? 600),
            interval: (object["interval"] as? Double) ?? 5
        )
    }

    /// Polls until the user approves the device authorization, or it fails.
    ///
    /// Honors RFC 8628's polling rules: `authorization_pending` means wait and retry, and
    /// `slow_down` means wait five seconds longer from now on. Ignoring either is how a device flow
    /// gets rate limited by the provider.
    ///
    /// - Parameters:
    ///   - authorization: The authorization returned by ``requestDeviceAuthorization()``.
    ///   - sleep: How to wait between polls. Injectable so tests do not take minutes.
    public func pollForToken(
        _ authorization: DeviceAuthorization,
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> OAuth2Token {
        var interval = authorization.interval

        while true {
            guard now() < authorization.expiresAt else {
                throw OAuth2Error.deviceAuthorizationExpired
            }
            try await sleep(interval)

            do {
                return try await requestToken(parameters: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": authorization.deviceCode,
                    "client_id": configuration.clientID,
                ])
            } catch let error as OAuth2Error {
                guard case let .server(code, _, _) = error else { throw error }
                switch code {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval += 5
                case "expired_token":
                    throw OAuth2Error.deviceAuthorizationExpired
                case "access_denied":
                    throw OAuth2Error.deviceAuthorizationDenied
                default:
                    throw error
                }
            }
        }
    }

    // MARK: - Transport

    private func requestToken(parameters: [String: String]) async throws -> OAuth2Token {
        let response = try await send(formRequest(to: configuration.tokenEndpoint, parameters: parameters))
        return try OAuth2Token.decode(from: response.body, now: now())
    }

    private func send(_ request: APIRequest) async throws -> NetworkResponse {
        let response: NetworkResponse
        do {
            response = try await transport.execute(request)
        } catch let error as NetworkError {
            // A provider signalling a failed grant with a 4xx puts the reason in the body, which the
            // transport has already turned into an error. The envelope is the useful part.
            guard case let .httpStatus(_, _, body) = error, let envelope = OAuth2Error.fromEnvelope(body) else {
                throw error
            }
            throw envelope
        }

        if let envelope = OAuth2Error.fromEnvelope(response.body) {
            throw envelope
        }
        return response
    }

    private func formRequest(to url: URL, parameters: [String: String]) -> APIRequest {
        var headers = [
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        ]
        if let secret = configuration.clientSecret {
            let credentials = Data("\(configuration.clientID):\(secret)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(credentials)"
        }

        return APIRequest(
            method: .post,
            url: url,
            headers: headers,
            body: Data(Self.formEncoded(parameters).utf8)
        )
    }

    /// Percent-encodes parameters for `application/x-www-form-urlencoded`, sorted so a body is
    /// reproducible and therefore testable.
    static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted { $0.key < $1.key }
            .map { "\(encode($0.key))=\(encode($0.value))" }
            .joined(separator: "&")
    }

    private static func encode(_ value: String) -> String {
        // Form encoding is not path encoding: everything outside the unreserved set must be escaped,
        // and a space becomes a plus.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
