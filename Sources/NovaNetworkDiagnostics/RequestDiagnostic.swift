import Foundation

/// What a recorded body is worth remembering.
///
/// A diagnostics buffer that keeps every payload is a memory leak with a nice name, so the size is
/// always recorded and the bytes only when the capture policy allows it.
public struct BodySummary: Sendable, Equatable {
    /// Size of the body as sent or received, before any truncation.
    public let byteCount: Int
    /// The captured bytes, subject to the capture policy, or `nil` when only the size was kept.
    public let captured: Data?
    /// Whether ``captured`` holds less than ``byteCount`` because it hit the capture limit.
    public let isTruncated: Bool

    /// Creates a body summary.
    public init(byteCount: Int, captured: Data? = nil, isTruncated: Bool = false) {
        self.byteCount = byteCount
        self.captured = captured
        self.isTruncated = isTruncated
    }
}

/// How a request interacted with the response cache.
public enum CacheOutcome: Sendable, Equatable {
    /// Served from cache.
    case hit(isStale: Bool, ageMilliseconds: Double)
    /// Not in cache.
    case miss
    /// Revalidated against the server and reused.
    case revalidated(ageMilliseconds: Double)
    /// Stale content served because revalidation failed.
    case staleServedAfterError(reason: String)

    /// Whether the response came from the cache rather than the network.
    public var servedFromCache: Bool {
        switch self {
        case .hit, .revalidated, .staleServedAfterError: true
        case .miss: false
        }
    }
}

/// One request, from the first attempt to whatever ended it.
public struct RequestDiagnostic: Sendable, Equatable, Identifiable {
    /// How the request ended.
    public enum Outcome: Sendable, Equatable {
        /// Still running, or the end was never observed.
        case inFlight
        /// Completed with an HTTP status, whatever that status says.
        ///
        /// A transport that returns a 500 as a response rather than throwing has completed the
        /// exchange, so this case covers it; ``RequestDiagnostic/isFailure`` is what decides
        /// whether the status was bad news.
        case completed(status: Int)
        /// Failed, with the reason the client reported.
        case failed(reason: String, status: Int?)
        /// Cancelled before completing.
        case cancelled(reason: String)

        /// Whether the request finished, one way or another.
        public var isFinished: Bool {
            if case .inFlight = self { return false }
            return true
        }
    }

    /// One attempt at the request, including why it was retried.
    public struct Attempt: Sendable, Equatable {
        /// One-based attempt number, as the client counts them.
        public let number: Int
        /// When the attempt began.
        public let startedAt: Date
        /// Delay the client waited before this attempt, when it followed a retry.
        public var retryDelayMilliseconds: Double?
        /// Why the previous attempt was retried.
        public var retryReason: String?

        /// Creates an attempt record.
        public init(
            number: Int,
            startedAt: Date,
            retryDelayMilliseconds: Double? = nil,
            retryReason: String? = nil
        ) {
            self.number = number
            self.startedAt = startedAt
            self.retryDelayMilliseconds = retryDelayMilliseconds
            self.retryReason = retryReason
        }
    }

    /// Stable identity of this record.
    public let id: UUID
    /// The coalescing key the client used, which is also how telemetry refers to the request.
    public let key: String
    /// HTTP method.
    public let method: String
    /// Absolute URL including query items.
    public let url: String
    /// When the first attempt began. `nil` when the record was created from an end event alone.
    public var startedAt: Date?
    /// When the request finished.
    public var endedAt: Date?
    /// Total duration as the client measured it.
    public var durationMilliseconds: Double?
    /// Attempts in order.
    public var attempts: [Attempt]
    /// How the request ended.
    public var outcome: Outcome
    /// The coalescing mode the request ran under.
    public var coalescingMode: String
    /// Whether this request joined another in-flight request instead of starting its own.
    public var wasCoalesced: Bool
    /// How the cache answered, when a cache event was observed for this key.
    public var cacheOutcome: CacheOutcome?
    /// Request headers, redacted.
    public var requestHeaders: [String: String]
    /// Response headers, redacted.
    public var responseHeaders: [String: String]
    /// What was sent.
    public var requestBody: BodySummary?
    /// What came back.
    public var responseBody: BodySummary?

    /// Creates a request record.
    public init(
        id: UUID = UUID(),
        key: String,
        method: String,
        url: String,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationMilliseconds: Double? = nil,
        attempts: [Attempt] = [],
        outcome: Outcome = .inFlight,
        coalescingMode: String = "default",
        wasCoalesced: Bool = false,
        cacheOutcome: CacheOutcome? = nil,
        requestHeaders: [String: String] = [:],
        responseHeaders: [String: String] = [:],
        requestBody: BodySummary? = nil,
        responseBody: BodySummary? = nil
    ) {
        self.id = id
        self.key = key
        self.method = method
        self.url = url
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.attempts = attempts
        self.outcome = outcome
        self.coalescingMode = coalescingMode
        self.wasCoalesced = wasCoalesced
        self.cacheOutcome = cacheOutcome
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBody = requestBody
        self.responseBody = responseBody
    }

    /// Number of attempts the request took.
    public var attemptCount: Int {
        max(attempts.count, 1)
    }

    /// Whether the request was retried at least once.
    public var wasRetried: Bool {
        attempts.count > 1
    }

    /// The HTTP status, when one was received.
    public var status: Int? {
        switch outcome {
        case let .completed(status): status
        case let .failed(_, status): status
        case .inFlight, .cancelled: nil
        }
    }

    /// Whether this request is one a developer would call a failure.
    ///
    /// A transport error, a cancellation, or any status from 400 up. Reporting a 500 as a success
    /// because nothing threw is exactly the kind of quiet lie a diagnostics tool must not tell.
    public var isFailure: Bool {
        switch outcome {
        case let .completed(status): status >= 400
        case .failed, .cancelled: true
        case .inFlight: false
        }
    }

    /// A one-line summary, the way it reads in the panel: `GET /users/1 — 200 in 42 ms`.
    public var shortDescription: String {
        let path = URL(string: url)?.path ?? url
        let outcomeText: String = switch outcome {
        case .inFlight: "in flight"
        case let .completed(status): "\(status)"
        case let .failed(reason, status): status.map { "\($0) — \(reason)" } ?? reason
        case let .cancelled(reason): "cancelled (\(reason))"
        }
        let timing = durationMilliseconds.map { String(format: " in %.0f ms", $0) } ?? ""
        return "\(method) \(path) — \(outcomeText)\(timing)"
    }
}
