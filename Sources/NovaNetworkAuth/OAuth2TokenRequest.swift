import Foundation
import NovaNetworkCore

/// The shape of a token request on the wire.
///
/// RFC 6749 §4 says form-encoded body, `grant_type` inside it. Plenty of providers that call
/// themselves OAuth 2.0 want something else — Supabase's GoTrue reads `grant_type` from the query
/// string and the rest from a JSON body — and a client that cannot say so is a client those
/// providers cannot use.
///
/// ```swift
/// var configuration = OAuth2Configuration(clientID: projectRef, tokenEndpoint: gotrueTokenURL)
/// configuration.tokenRequestStyle = .init(
///     bodyEncoding: .json,
///     grantTypePlacement: .query,
///     additionalHeaders: ["apikey": anonKey]
/// )
/// ```
public struct OAuth2TokenRequestStyle: Sendable, Equatable {
    /// How the parameters are written into the request body.
    public enum BodyEncoding: String, Sendable, Equatable {
        /// `application/x-www-form-urlencoded`, as RFC 6749 specifies.
        case formURLEncoded
        /// A flat JSON object of the same parameters.
        case json
    }

    /// Where `grant_type` is carried.
    public enum GrantTypePlacement: String, Sendable, Equatable {
        /// In the request body, alongside the other parameters.
        case body
        /// In the endpoint's query string, leaving the body to everything else.
        case query
    }

    /// How the parameters are encoded.
    public var bodyEncoding: BodyEncoding
    /// Where `grant_type` is written.
    public var grantTypePlacement: GrantTypePlacement
    /// Headers added to every token request, applied last so they can override the defaults.
    ///
    /// This is where a provider-wide API key goes.
    public var additionalHeaders: [String: String]

    /// Creates a request style.
    ///
    /// - Parameters:
    ///   - bodyEncoding: How parameters are encoded. Form-encoded by default, as RFC 6749 requires.
    ///   - grantTypePlacement: Where `grant_type` goes. The body by default.
    ///   - additionalHeaders: Extra headers, applied after the ones this client sets.
    public init(
        bodyEncoding: BodyEncoding = .formURLEncoded,
        grantTypePlacement: GrantTypePlacement = .body,
        additionalHeaders: [String: String] = [:]
    ) {
        self.bodyEncoding = bodyEncoding
        self.grantTypePlacement = grantTypePlacement
        self.additionalHeaders = additionalHeaders
    }

    /// The RFC 6749 shape: form-encoded body, `grant_type` inside it.
    public static let standard = OAuth2TokenRequestStyle()
}

extension OAuth2TokenRequestStyle.BodyEncoding {
    /// The `Content-Type` this encoding produces.
    var contentType: String {
        switch self {
        case .formURLEncoded:
            return "application/x-www-form-urlencoded"
        case .json:
            return "application/json"
        }
    }

    /// Encodes the parameters, sorted so a body is reproducible and therefore testable.
    func encode(_ parameters: [String: String]) -> Data {
        switch self {
        case .formURLEncoded:
            return Data(OAuth2Client.formEncoded(parameters).utf8)
        case .json:
            return OAuth2Client.jsonEncoded(parameters)
        }
    }
}

/// One token request, described rather than sent.
///
/// An ``OAuth2TokenExchange`` receives this instead of the request ``OAuth2Client`` would have
/// built, so an adopter whose provider does not accept that request can answer the same question
/// their own way.
public struct OAuth2Grant: Sendable, Equatable {
    /// The `grant_type` value, such as `refresh_token` or `authorization_code`.
    public let type: String
    /// Every parameter the standard request would have carried, `grant_type` included.
    public let parameters: [String: String]
    /// The endpoint the standard request would have been sent to.
    public let endpoint: URL
    /// The token being refreshed, when this grant is a refresh; `nil` for every other grant.
    ///
    /// A provider that returns no new refresh token leaves the old one usable, and this is where it
    /// comes from.
    public let currentToken: OAuth2Token?

    /// Creates a grant description.
    public init(
        type: String,
        parameters: [String: String],
        endpoint: URL,
        currentToken: OAuth2Token? = nil
    ) {
        self.type = type
        self.parameters = parameters
        self.endpoint = endpoint
        self.currentToken = currentToken
    }
}

/// Turns a grant into a token, in place of the request ``OAuth2Client`` would have sent.
///
/// Supply one when the provider's token endpoint is not shaped like RFC 6749 in a way
/// ``OAuth2TokenRequestStyle`` cannot describe — a different parameter vocabulary, a signature over
/// the body, a grant that is not an OAuth grant at all. Everything else stays library-side:
/// ``OAuth2Authenticator`` still holds the token, still refreshes once across a burst of
/// unauthorized responses, and still attaches it through its middleware.
///
/// ```swift
/// let authenticator = OAuth2Authenticator(
///     configuration: configuration,
///     exchange: OAuth2TokenExchange { grant in try await myTokenRequest(grant) },
///     store: KeychainTokenStore(service: "com.example.app", account: "session")
/// )
/// ```
public struct OAuth2TokenExchange: Sendable {
    /// Performs one grant.
    public typealias Handler = @Sendable (OAuth2Grant) async throws -> OAuth2Token

    private let handler: Handler

    /// Creates an exchange from a closure.
    public init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    /// Runs the grant and returns the token it produced.
    public func token(for grant: OAuth2Grant) async throws -> OAuth2Token {
        try await handler(grant)
    }
}
