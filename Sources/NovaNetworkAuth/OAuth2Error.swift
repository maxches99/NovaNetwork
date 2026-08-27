import Foundation

/// A failure from an OAuth 2.0 exchange.
public enum OAuth2Error: Error, Equatable, Sendable {
    /// The provider returned an error envelope, per RFC 6749 §5.2.
    ///
    /// `code` is the machine-readable `error` value — `invalid_grant`, `invalid_client`, and so on —
    /// which is what a caller should branch on. The description is for humans and is often absent.
    case server(code: String, description: String?, uri: String?)
    /// The code verifier does not meet RFC 7636's requirements.
    case invalidVerifier(reason: String)
    /// The callback's `state` did not match the one the flow started with.
    ///
    /// Treat this as an attack, not a glitch: it is what stops an attacker's authorization code from
    /// being redeemed in the victim's session.
    case stateMismatch(expected: String, received: String?)
    /// The callback carried neither a code nor an error.
    case missingAuthorizationCode
    /// The configuration has no endpoint for the grant being attempted.
    case missingEndpoint(name: String)
    /// The response was not shaped like anything this library can read.
    case invalidResponse(reason: String)
    /// The device code expired before the user approved it.
    case deviceAuthorizationExpired
    /// The user declined the device authorization.
    case deviceAuthorizationDenied
    /// There is no token, and no way to obtain one without user interaction.
    case notAuthenticated

    /// Reads an RFC 6749 §5.2 error envelope, when the body carries one.
    static func fromEnvelope(_ data: Data) -> OAuth2Error? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["error"] as? String
        else {
            return nil
        }
        return .server(
            code: code,
            description: object["error_description"] as? String,
            uri: object["error_uri"] as? String
        )
    }
}

extension OAuth2Error: LocalizedError {
    /// A description that names the failure without ever quoting a credential.
    public var errorDescription: String? {
        switch self {
        case let .server(code, description, _):
            description.map { "The authorization server rejected the request: \(code) — \($0)" }
                ?? "The authorization server rejected the request: \(code)"
        case let .invalidVerifier(reason):
            "Invalid PKCE code verifier. \(reason)"
        case .stateMismatch:
            "The authorization callback's state did not match the one this flow started with, so the response was discarded."
        case .missingAuthorizationCode:
            "The authorization callback carried neither a code nor an error."
        case let .missingEndpoint(name):
            "This grant needs a \(name) in the configuration, and none was set."
        case let .invalidResponse(reason):
            "The authorization server's response could not be read. \(reason)"
        case .deviceAuthorizationExpired:
            "The device code expired before it was approved. Start the device flow again."
        case .deviceAuthorizationDenied:
            "The device authorization was declined."
        case .notAuthenticated:
            "There is no token, and refreshing one needs the user to sign in again."
        }
    }
}
