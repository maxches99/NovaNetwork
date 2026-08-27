import Foundation
import NovaNetworkCore

/// How a ``CassetteTransport`` treats each request.
public enum CassetteMode: String, Sendable, Equatable, CaseIterable {
    /// Serve recordings only. A request with no recording is an error, and the upstream transport is
    /// never contacted — which is what makes a replaying test deterministic and offline.
    case replay
    /// Perform every request for real and append the exchange to the cassette.
    case record
    /// Replay what the cassette holds and record anything it does not. Running a scenario twice
    /// leaves the second run fully offline.
    case recordMissing
}

/// What to do when every recording for a request has already been replayed.
public enum CassetteRepeatPolicy: String, Sendable, Equatable, CaseIterable {
    /// Throw ``CassetteError/recordingsExhausted(method:url:matches:)``. The default: a test that
    /// asks for more responses than were recorded is usually asking a different question than the
    /// one that was recorded.
    case error
    /// Replay the last matching recording again, for polling loops where the steady state repeats.
    case repeatLast
}

/// A transport that records real exchanges to a cassette, or replays them from one.
///
/// ```swift
/// let transport = CassetteTransport(mode: .replay, cassette: try Cassette.load(from: url))
/// let client = NetworkClient(transport: transport)
/// ```
///
/// The same type covers three jobs: deterministic tests, SwiftUI previews with real payloads, and an
/// app's offline demo mode. Because it is an ordinary ``NetworkTransport``, everything above it —
/// coalescing, caching, retry, telemetry — behaves exactly as it does against a live server.
///
/// Streaming, Server-Sent Events, and managed transfers are not recorded: this conforms to
/// ``NetworkTransport`` alone, so the client falls back to its non-streaming path.
public actor CassetteTransport: NetworkTransport {
    /// How requests are treated.
    public let mode: CassetteMode
    /// The upstream transport used when recording.
    public let upstream: (any NetworkTransport)?
    /// The rule deciding whether a recording answers a request.
    public let matchRule: CassetteMatchRule
    /// The redaction applied before anything is recorded.
    public let redaction: CassetteRedaction
    /// What happens once every matching recording has been replayed.
    public let repeatPolicy: CassetteRepeatPolicy

    private var storage: Cassette
    private var consumed: Set<Int> = []
    private var isDirty = false

    /// Creates a cassette transport.
    ///
    /// - Parameters:
    ///   - mode: Whether to replay, record, or record only what is missing.
    ///   - cassette: The starting recording. Empty when recording from scratch.
    ///   - upstream: The transport used for real requests. Required by ``CassetteMode/record`` and
    ///     ``CassetteMode/recordMissing``.
    ///   - matchRule: How a live request is matched against recordings.
    ///   - redaction: What is stripped before an exchange is stored.
    ///   - repeatPolicy: What happens when matching recordings run out.
    public init(
        mode: CassetteMode,
        cassette: Cassette = Cassette(),
        upstream: (any NetworkTransport)? = nil,
        matchRule: CassetteMatchRule = .default,
        redaction: CassetteRedaction = .default,
        repeatPolicy: CassetteRepeatPolicy = .error
    ) {
        self.mode = mode
        storage = cassette
        self.upstream = upstream
        self.matchRule = matchRule
        self.redaction = redaction
        self.repeatPolicy = repeatPolicy
    }

    /// The cassette as it stands, including anything recorded so far.
    public var cassette: Cassette {
        storage
    }

    /// Whether the cassette changed since it was loaded or last saved.
    public var hasUnsavedChanges: Bool {
        isDirty
    }

    /// Writes the cassette and marks it saved.
    public func save(to url: URL) throws {
        try storage.write(to: url)
        isDirty = false
    }

    /// Replays or records `request`, depending on the mode.
    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        let recorded = record(request)

        switch mode {
        case .replay:
            return try replay(recorded)
        case .record:
            return try await performAndRecord(request, recorded: recorded)
        case .recordMissing:
            if let replayed = try? replay(recorded) {
                return replayed
            }
            return try await performAndRecord(request, recorded: recorded)
        }
    }

    // MARK: - Replay

    private func replay(_ request: RecordedRequest) throws -> NetworkResponse {
        var lastMatchIndex: Int?
        var matchCount = 0

        for (index, interaction) in storage.interactions.enumerated()
        where matchRule.matches(request, candidate: interaction.request) {
            matchCount += 1
            lastMatchIndex = index

            if !consumed.contains(index) {
                consumed.insert(index)
                return response(from: interaction.response)
            }
        }

        guard matchCount > 0 else {
            throw CassetteError.noRecordingMatched(
                method: request.method,
                url: request.url,
                unconsumedInteractions: storage.interactions.count - consumed.count,
                totalInteractions: storage.interactions.count
            )
        }
        guard repeatPolicy == .repeatLast, let lastMatchIndex else {
            throw CassetteError.recordingsExhausted(
                method: request.method,
                url: request.url,
                matches: matchCount
            )
        }
        return response(from: storage.interactions[lastMatchIndex].response)
    }

    // MARK: - Record

    private func performAndRecord(_ request: APIRequest, recorded: RecordedRequest) async throws -> NetworkResponse {
        guard let upstream else {
            throw CassetteError.recordingRequiresUpstream(mode: mode.rawValue)
        }

        // A thrown transport error is not an HTTP exchange, so nothing is appended: the error
        // propagates and the cassette stays exactly as it was.
        let response = try await upstream.execute(request)

        storage.interactions.append(
            RecordedInteraction(request: recorded, response: self.record(response))
        )
        consumed.insert(storage.interactions.count - 1)
        isDirty = true

        return response
    }

    // MARK: - Conversion

    private func record(_ request: APIRequest) -> RecordedRequest {
        RecordedRequest(
            method: request.method.rawValue,
            url: redaction.redacted(url: request.urlRequest().url?.absoluteString ?? request.url.absoluteString),
            headers: redaction.redacted(headers: request.headers),
            body: redaction.redacted(body: request.body).map(RecordedBody.init(data:))
        )
    }

    private func record(_ response: NetworkResponse) -> RecordedResponse {
        RecordedResponse(
            status: response.statusCode,
            headers: redaction.redacted(headers: response.headers),
            body: response.body.isEmpty ? nil : RecordedBody(data: redaction.redacted(body: response.body) ?? response.body)
        )
    }

    private func response(from recorded: RecordedResponse) -> NetworkResponse {
        NetworkResponse(
            statusCode: recorded.status,
            headers: recorded.headers,
            body: recorded.body?.data ?? Data()
        )
    }
}
