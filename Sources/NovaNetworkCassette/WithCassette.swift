import Foundation
import NovaNetworkCore

/// Runs `body` against a cassette at `url`, saving anything newly recorded.
///
/// This is the one-line form of the whole feature:
///
/// ```swift
/// try await withCassette(at: fixtureURL, upstream: Transport()) { transport in
///     let client = NetworkClient(transport: transport)
///     let user: User = try await client.load(request: request, authScope: nil)
///     #expect(user.name == "Ada")
/// }
/// ```
///
/// The first run records against the real service; every run after that is offline and
/// deterministic, because ``CassetteMode/recordMissing`` replays what the file already holds.
///
/// The cassette is saved only when `body` returns normally. A scope that threw halfway through has
/// recorded an incomplete scenario, and a half-written cassette that later replays silently is worse
/// than no cassette at all.
///
/// - Parameters:
///   - url: Where the cassette lives. A missing file starts an empty recording.
///   - mode: How requests are treated. Defaults to ``CassetteMode/recordMissing``.
///   - upstream: The transport used for real requests while recording.
///   - matchRule: How live requests are matched against recordings.
///   - redaction: What is stripped before an exchange is stored.
///   - repeatPolicy: What happens when matching recordings run out.
///   - isolation: Inherited from the caller, so `body` runs in the caller's isolation domain and may
///     capture whatever a test or a preview already holds. Never pass this explicitly.
///   - body: The scope that uses the transport.
/// - Returns: Whatever `body` returns.
@discardableResult
public func withCassette<T>(
    at url: URL,
    mode: CassetteMode = .recordMissing,
    upstream: (any NetworkTransport)? = nil,
    matchRule: CassetteMatchRule = .default,
    redaction: CassetteRedaction = .default,
    repeatPolicy: CassetteRepeatPolicy = .error,
    isolation: isolated (any Actor)? = #isolation,
    _ body: (CassetteTransport) async throws -> T
) async throws -> T {
    let existing = FileManager.default.fileExists(atPath: url.path) ? try Cassette.load(from: url) : Cassette()

    let transport = CassetteTransport(
        mode: mode,
        cassette: existing,
        upstream: upstream,
        matchRule: matchRule,
        redaction: redaction,
        repeatPolicy: repeatPolicy
    )

    let result = try await body(transport)

    if await transport.hasUnsavedChanges {
        try await transport.save(to: url)
    }
    return result
}
