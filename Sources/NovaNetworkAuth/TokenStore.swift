import Foundation

/// Where a token lives between launches, if anywhere.
///
/// The choice is explicit on purpose. A library that persists credentials unless told otherwise is
/// a library that persists credentials in the one app that forgot to look.
public protocol TokenStore: Sendable {
    /// Reads the stored token, or `nil` when there is none.
    func load() async throws -> OAuth2Token?
    /// Replaces the stored token.
    func save(_ token: OAuth2Token) async throws
    /// Removes the stored token.
    func clear() async throws
}

/// Keeps the token in memory only, so nothing survives the process.
///
/// The default, because forgetting a token on relaunch is a smaller problem than leaking one.
public actor InMemoryTokenStore: TokenStore {
    private var token: OAuth2Token?

    /// Creates an empty store, or one primed with a token.
    public init(token: OAuth2Token? = nil) {
        self.token = token
    }

    public func load() async throws -> OAuth2Token? {
        token
    }

    public func save(_ token: OAuth2Token) async throws {
        self.token = token
    }

    public func clear() async throws {
        token = nil
    }
}
