import Foundation
import NovaNetworkCore

/// Everything a provider needs to know about your client.
public struct OAuth2Configuration: Sendable, Equatable {
    /// The client identifier issued by the provider.
    public var clientID: String
    /// The client secret, for confidential clients. Public clients leave this `nil` and use PKCE.
    public var clientSecret: String?
    /// Where the user is sent to approve access. Only needed for the authorization code grant.
    public var authorizationEndpoint: URL?
    /// Where grants are exchanged for tokens.
    public var tokenEndpoint: URL
    /// Where a device authorization request is sent, for the device grant.
    public var deviceAuthorizationEndpoint: URL?
    /// Where the provider sends the user back after approval.
    public var redirectURI: URL?
    /// Scopes requested, joined with spaces on the wire.
    public var scopes: [String]
    /// Extra parameters added to the authorization URL, for provider-specific options.
    public var additionalAuthorizationParameters: [String: String]
    /// How early a token counts as expired, to avoid racing the server's clock.
    public var expiryLeeway: TimeInterval

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - clientID: The client identifier.
    ///   - clientSecret: The client secret for confidential clients; omit it for public clients.
    ///   - authorizationEndpoint: Authorization URL, for the authorization code grant.
    ///   - tokenEndpoint: Token URL, used by every grant.
    ///   - deviceAuthorizationEndpoint: Device authorization URL, for the device grant.
    ///   - redirectURI: Redirect URI registered with the provider.
    ///   - scopes: Requested scopes.
    ///   - additionalAuthorizationParameters: Provider-specific authorization parameters.
    ///   - expiryLeeway: Seconds before the stated expiry at which a token is treated as expired.
    ///     Sixty by default, because a token that expires while in flight is indistinguishable from
    ///     one that was never valid.
    public init(
        clientID: String,
        clientSecret: String? = nil,
        authorizationEndpoint: URL? = nil,
        tokenEndpoint: URL,
        deviceAuthorizationEndpoint: URL? = nil,
        redirectURI: URL? = nil,
        scopes: [String] = [],
        additionalAuthorizationParameters: [String: String] = [:],
        expiryLeeway: TimeInterval = 60
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.deviceAuthorizationEndpoint = deviceAuthorizationEndpoint
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.additionalAuthorizationParameters = additionalAuthorizationParameters
        self.expiryLeeway = expiryLeeway
    }
}

/// A PKCE verifier and the challenge derived from it.
///
/// Proof Key for Code Exchange stops an intercepted authorization code from being redeemed by
/// anyone but the client that started the flow. It is required for public clients and harmless for
/// confidential ones, so this library always uses it.
public struct PKCEChallenge: Sendable, Equatable {
    /// The high-entropy secret kept by the client until the code is exchanged.
    public let verifier: String
    /// `base64url(SHA256(verifier))`, sent with the authorization request.
    public let challenge: String
    /// The transformation used, always `S256`. `plain` is permitted by RFC 7636 and not offered here.
    public let method = "S256"

    /// Characters RFC 7636 allows in a verifier.
    static let allowedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Derives a challenge from an existing verifier.
    ///
    /// - Throws: ``OAuth2Error/invalidVerifier(reason:)`` when the verifier is outside the 43–128
    ///   character range or uses characters outside the unreserved set.
    public init(verifier: String) throws {
        guard (43...128).contains(verifier.count) else {
            throw OAuth2Error.invalidVerifier(
                reason: "A code verifier must be 43 to 128 characters; this one is \(verifier.count)."
            )
        }
        guard verifier.allSatisfy({ Self.allowedCharacters.contains($0) }) else {
            throw OAuth2Error.invalidVerifier(
                reason: "A code verifier may only use A-Z, a-z, 0-9, and the characters - . _ ~"
            )
        }
        self.verifier = verifier
        challenge = Self.base64URLEncoded(SHA256Util.digest(Data(verifier.utf8)))
    }

    /// Generates a fresh verifier and its challenge.
    ///
    /// The verifier is 32 random bytes rendered base64url, which is 43 characters — the length RFC
    /// 7636 recommends.
    public static func generate() -> PKCEChallenge {
        var generator = SystemRandomNumberGenerator()
        var bytes = Data(capacity: 32)
        for _ in 0..<32 {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        // 32 random bytes always encode to a 43-character, alphabet-safe verifier. The throwing
        // initializer exists to validate verifiers that came from somewhere else.
        return PKCEChallenge(unchecked: base64URLEncoded(bytes))
    }

    private init(unchecked verifier: String) {
        self.verifier = verifier
        challenge = Self.base64URLEncoded(SHA256Util.digest(Data(verifier.utf8)))
    }

    /// Base64url without padding, as every OAuth 2.0 parameter expects.
    static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
