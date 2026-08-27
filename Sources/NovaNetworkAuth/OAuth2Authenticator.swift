import Foundation
import NovaNetworkClient
import NovaNetworkCore

/// Holds the current token and refreshes it exactly once, however many callers need it.
///
/// The client already solves the hard half of this: `HTTPAuthRefreshPolicy` coordinates a single
/// refresh across a burst of unauthorized responses, then replays them. What it takes is a closure,
/// and ``refreshProvider`` is that closure filled in.
public actor OAuth2Authenticator {
    /// The client performing grants.
    public nonisolated let client: OAuth2Client
    /// Where the token lives.
    ///
    /// Nonisolated because it never changes and every conforming store is `Sendable`: reading which
    /// store is in use should not have to hop onto the actor.
    public nonisolated let store: any TokenStore

    private let now: @Sendable () -> Date
    private var refreshTask: Task<OAuth2Token, any Error>?

    /// Creates an authenticator.
    ///
    /// - Parameters:
    ///   - client: Performs the grants.
    ///   - store: Where the token lives. In memory by default, so nothing is persisted unless asked.
    ///   - now: Clock used for expiry decisions.
    public init(
        client: OAuth2Client,
        store: any TokenStore = InMemoryTokenStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.client = client
        self.store = store
        self.now = now
    }

    // MARK: - Token lifecycle

    /// The stored token, whatever its state.
    public func currentToken() async throws -> OAuth2Token? {
        try await store.load()
    }

    /// Stores a token obtained elsewhere, such as the end of an authorization code flow.
    public func setToken(_ token: OAuth2Token) async throws {
        try await store.save(token)
    }

    /// Forgets the token, for sign-out.
    public func signOut() async throws {
        refreshTask?.cancel()
        refreshTask = nil
        try await store.clear()
    }

    /// A token that is safe to send, refreshing first when the stored one is expired.
    ///
    /// - Throws: ``OAuth2Error/notAuthenticated`` when there is no token and no refresh token, which
    ///   means the user has to sign in again.
    public func validToken() async throws -> OAuth2Token {
        guard let token = try await store.load() else {
            throw OAuth2Error.notAuthenticated
        }
        guard token.isExpired(now: now(), leeway: client.configuration.expiryLeeway) else {
            return token
        }
        return try await refresh(from: token)
    }

    /// Refreshes now, regardless of the stored token's stated expiry.
    ///
    /// This is what an unauthorized response should trigger: the server disagreeing with the local
    /// clock is exactly the case a timestamp check cannot catch.
    @discardableResult
    public func forceRefresh() async throws -> OAuth2Token {
        guard let token = try await store.load() else {
            throw OAuth2Error.notAuthenticated
        }
        return try await refresh(from: token)
    }

    /// Runs one refresh, however many callers arrive while it is in flight.
    ///
    /// The actor alone is not enough: it suspends at the network call, so a second caller would
    /// start a second refresh. Sharing the task is what makes it single-flight.
    private func refresh(from token: OAuth2Token) async throws -> OAuth2Token {
        if let refreshTask {
            return try await refreshTask.value
        }

        let task = Task<OAuth2Token, any Error> { [client, store] in
            let refreshed = try await client.refresh(token)
            try await store.save(refreshed)
            return refreshed
        }
        refreshTask = task

        do {
            let refreshed = try await task.value
            refreshTask = nil
            return refreshed
        } catch {
            refreshTask = nil
            // A rejected grant means the session is over; keeping the dead token would make every
            // later request fail the same way without ever asking the user to sign in.
            if case OAuth2Error.server(let code, _, _) = error, code == "invalid_grant" {
                try? await store.clear()
            }
            throw error
        }
    }

    // MARK: - Client integration

    /// The refresh provider to hand to `NetworkClient`.
    ///
    /// ```swift
    /// configuration.authRefreshProvider = authenticator.refreshProvider
    /// ```
    public nonisolated var refreshProvider: HTTPAuthRefreshProvider {
        HTTPAuthRefreshProvider { [self] _ in
            let token = try await forceRefresh()
            return ["Authorization": token.authorizationHeaderValue]
        }
    }

    /// Middleware that attaches the current token to outgoing requests.
    ///
    /// A request that already carries an `Authorization` header is left alone, and so is one made
    /// while signed out: sending it unauthenticated lets the server answer, which is more useful
    /// than failing locally on an endpoint that may not need a token at all.
    public nonisolated var middleware: NetworkMiddleware {
        NetworkMiddleware(beforeSend: { [self] request, _ in
            guard request.headers["Authorization"] == nil else { return request }
            guard let token = try? await validToken() else { return request }
            return request.withMergedHeaders(["Authorization": token.authorizationHeaderValue])
        })
    }
}
