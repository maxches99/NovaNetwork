import Foundation
import NovaNetworkCore

/// How long a request may run before the client sends it a second time.
public enum HedgingDelay: Sendable, Equatable {
    /// Always wait this many seconds.
    case fixed(seconds: TimeInterval)

    /// Wait the given percentile of recent successful latencies to the request's host.
    ///
    /// - Parameters:
    ///   - percentile: Between `0` and `1`; `0.95` is p95.
    ///   - minimumSamples: How many latencies a host needs before its percentile is trusted.
    ///   - fallbackSeconds: The delay until then.
    ///   - floorSeconds: The delay never goes below this, so a host that is always fast is not
    ///     hedged on every scheduling hiccup.
    case percentile(
        _ percentile: Double,
        minimumSamples: Int = 20,
        fallbackSeconds: TimeInterval = 1,
        floorSeconds: TimeInterval = 0.05
    )
}

/// When to send a slow request a second time, and take whichever answer comes first.
///
/// A retry starts after an attempt *fails*. A hedge starts while the attempt is still running, so it
/// helps with the requests that are not failing, just slow: a busy replica, a lost packet waiting on
/// a retransmit timer. The first successful response wins and the other request is cancelled.
///
/// Only requests that are safe to send twice are hedged. ``defaultEligibility`` admits `GET`,
/// `HEAD`, and `OPTIONS`, and any request with an `Idempotency-Key` header. A custom
/// `isEligible` owns that decision: hedging a write that has no idempotency key sends the write twice.
///
/// Hedges are budgeted. Each eligible request earns `maximumHedgeRatio` of a hedge, up to `burst`
/// saved, and each hedge spends one — so a server that is slow because it is overloaded does not
/// receive twice the traffic.
///
/// ```swift
/// var configuration = NetworkClientConfiguration()
/// configuration.hedging = HedgingPolicy(delay: .percentile(0.95))
/// ```
public struct HedgingPolicy: Sendable {
    /// Decides whether a request may be sent twice.
    public typealias Eligibility = @Sendable (APIRequest) -> Bool

    /// When to hedge.
    public let delay: HedgingDelay
    /// The fraction of eligible requests that may be hedged over time, between `0` and `1`.
    public let maximumHedgeRatio: Double
    /// How many unspent hedges may be saved up, and how many the budget starts with.
    ///
    /// The budget can always save at least one, so a burst of `0` still lets the ratio earn hedges;
    /// it only means none are available before the first is earned.
    public let burst: Int
    /// Which requests may be hedged.
    public let isEligible: Eligibility

    /// Creates a policy.
    ///
    /// Values outside their range are clamped: the ratio to `0...1`, the burst to at least `0`, the
    /// percentile to `0...1`, delays to at least `0`, and the minimum sample count to at least `1`.
    ///
    /// - Parameters:
    ///   - delay: When to hedge. Defaults to p95 of recent latencies to the same host.
    ///   - maximumHedgeRatio: The share of eligible requests that may be hedged. Defaults to 5%.
    ///   - burst: Hedges that may be saved up. Defaults to 2.
    ///   - isEligible: Which requests may be hedged. Defaults to ``defaultEligibility``.
    public init(
        delay: HedgingDelay = .percentile(0.95),
        maximumHedgeRatio: Double = 0.05,
        burst: Int = 2,
        isEligible: @escaping Eligibility = HedgingPolicy.defaultEligibility
    ) {
        self.delay = Self.clamped(delay)
        self.maximumHedgeRatio = min(max(maximumHedgeRatio, 0), 1)
        self.burst = max(burst, 0)
        self.isEligible = isEligible
    }

    /// Admits safe methods, and any request carrying an `Idempotency-Key` header.
    public static let defaultEligibility: Eligibility = { request in
        if request.method.isSafe { return true }
        return request.headers.keys.contains { $0.caseInsensitiveCompare("Idempotency-Key") == .orderedSame }
    }

    private static func clamped(_ delay: HedgingDelay) -> HedgingDelay {
        switch delay {
        case .fixed(let seconds):
            return .fixed(seconds: max(seconds, 0))
        case let .percentile(percentile, minimumSamples, fallbackSeconds, floorSeconds):
            return .percentile(
                min(max(percentile, 0), 1),
                minimumSamples: max(minimumSamples, 1),
                fallbackSeconds: max(fallbackSeconds, 0),
                floorSeconds: max(floorSeconds, 0)
            )
        }
    }
}

/// The hedge budget and the latency history it decides from.
actor HedgingState {
    static let samplesPerHost = 128

    private let policy: HedgingPolicy
    private var tokens: Double
    private var latencies: [String: [Double]] = [:]

    init(policy: HedgingPolicy) {
        self.policy = policy
        self.tokens = Double(policy.burst)
    }

    /// Records one eligible request, earning its share of a hedge.
    func recordEligibleRequest() {
        tokens = min(tokens + policy.maximumHedgeRatio, Double(max(policy.burst, 1)))
    }

    /// Spends one hedge, if there is one to spend.
    func trySpendHedge() -> Bool {
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    /// Remembers how long a successful request to `host` took.
    func recordLatency(seconds: Double, host: String) {
        var samples = latencies[host, default: []]
        samples.append(seconds)
        if samples.count > Self.samplesPerHost {
            samples.removeFirst(samples.count - Self.samplesPerHost)
        }
        latencies[host] = samples
    }

    /// How long to wait before hedging a request to `host`, in seconds.
    func delaySeconds(host: String) -> Double {
        switch policy.delay {
        case .fixed(let seconds):
            return seconds
        case let .percentile(percentile, minimumSamples, fallbackSeconds, floorSeconds):
            let samples = latencies[host, default: []]
            guard samples.count >= minimumSamples else { return max(fallbackSeconds, floorSeconds) }
            // Nearest rank: the smallest sample with at least `percentile` of the samples at or below it.
            let sorted = samples.sorted()
            let rank = Int((Double(sorted.count) * percentile).rounded(.up))
            let index = min(max(rank - 1, 0), sorted.count - 1)
            return max(sorted[index], floorSeconds)
        }
    }
}
