import Foundation

/// A token as the provider issued it.
public struct OAuth2Token: Sendable, Equatable, Codable {
    /// The credential sent with requests.
    public let accessToken: String
    /// The token type, `Bearer` unless the provider says otherwise.
    public let tokenType: String
    /// The credential used to obtain a new access token, when the provider issued one.
    public let refreshToken: String?
    /// Scopes the provider actually granted, which may be narrower than those requested.
    public let scopes: [String]
    /// When the access token stops being valid, or `nil` when the provider did not say.
    public let expiresAt: Date?

    /// Creates a token.
    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        refreshToken: String? = nil,
        scopes: [String] = [],
        expiresAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.scopes = scopes
        self.expiresAt = expiresAt
    }

    /// The value for an `Authorization` header.
    public var authorizationHeaderValue: String {
        "\(tokenType) \(accessToken)"
    }

    /// Whether the token should be refreshed before use.
    ///
    /// A token with no stated expiry is never treated as expired: the provider chose not to say, and
    /// guessing would refresh working credentials on a timer.
    ///
    /// - Parameters:
    ///   - now: The current time.
    ///   - leeway: How long before the stated expiry to start treating the token as expired.
    public func isExpired(now: Date, leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return now.addingTimeInterval(leeway) >= expiresAt
    }

    /// Returns a copy carrying `refreshToken` when this token has none.
    ///
    /// Providers routinely omit the refresh token from a refresh response, meaning "keep using the
    /// one you have". Dropping it there is how a session ends an hour later for no visible reason.
    public func retainingRefreshToken(from previous: OAuth2Token?) -> OAuth2Token {
        guard refreshToken == nil, let inherited = previous?.refreshToken else { return self }
        return OAuth2Token(
            accessToken: accessToken,
            tokenType: tokenType,
            refreshToken: inherited,
            scopes: scopes,
            expiresAt: expiresAt
        )
    }

    /// Parses a token endpoint response body.
    ///
    /// - Parameters:
    ///   - data: The response body.
    ///   - now: Clock used to turn `expires_in` into an absolute expiry.
    /// - Throws: ``OAuth2Error/invalidResponse(reason:)`` when the payload is not a token.
    public static func decode(from data: Data, now: Date) throws -> OAuth2Token {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuth2Error.invalidResponse(reason: "The token response was not a JSON object.")
        }
        guard let accessToken = object["access_token"] as? String else {
            throw OAuth2Error.invalidResponse(reason: "The token response has no access_token.")
        }

        let expiresAt: Date?
        if let seconds = object["expires_in"] as? Double {
            expiresAt = now.addingTimeInterval(seconds)
        } else if let seconds = (object["expires_in"] as? String).flatMap(Double.init) {
            expiresAt = now.addingTimeInterval(seconds)
        } else {
            expiresAt = nil
        }

        return OAuth2Token(
            accessToken: accessToken,
            tokenType: object["token_type"] as? String ?? "Bearer",
            refreshToken: object["refresh_token"] as? String,
            scopes: (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? [],
            expiresAt: expiresAt
        )
    }
}
