import Foundation

/// How many requests may be in flight at once, decided from what the server is actually doing.
///
/// A fixed ceiling is a guess. Guess low and a fast server idles; guess high and a struggling one
/// gets buried under the retries its own slowness caused. This policy starts from a guess and then
/// corrects it: additive increase while there is headroom, multiplicative decrease the moment the
/// server says it is struggling — by refusing requests, or by getting slower, which usually comes
/// first.
///
/// It is off unless you ask for it. `RequestExecutionOptions.adaptiveConcurrencyPolicy` is `nil` by
/// default and the client admits requests exactly as it always has.
public struct AdaptiveConcurrencyPolicy: Sendable, Equatable {
    /// The limit never drops below this. One request at a time is still progress.
    public let minimumLimit: Int
    /// The limit never rises above this, however healthy the server looks.
    public let maximumLimit: Int
    /// Where to start before anything has been observed.
    public let initialLimit: Int
    /// What the limit is multiplied by when congestion is observed.
    ///
    /// Decrease has to be multiplicative and increase additive, not the other way round: backing off
    /// slowly from an overloaded server is how a client turns a slowdown into an outage.
    public let backoffFactor: Double
    /// How much slower than the best latency seen counts as the server struggling.
    ///
    /// Latency degrades before a server starts refusing requests, so this is the signal that arrives
    /// in time to matter. Set it to `.infinity` to react only to refusals.
    public let latencyDegradationFactor: Double
    /// How long a caller waits for a slot before giving up, or `nil` to wait as long as it takes.
    public let queueTimeoutSeconds: TimeInterval?

    /// Creates a policy.
    ///
    /// - Parameters:
    ///   - minimumLimit: Clamped to at least 1.
    ///   - maximumLimit: Clamped to at least `minimumLimit`.
    ///   - initialLimit: Clamped into `minimumLimit...maximumLimit`.
    ///   - backoffFactor: Clamped into `0.1...0.95`. A factor of 1 would never back off, and a
    ///     factor of 0 would collapse to the minimum on a single slow response.
    ///   - latencyDegradationFactor: Clamped to at least 1. Below 1 every response would look like
    ///     congestion, including the fastest one ever seen.
    ///   - queueTimeoutSeconds: A non-positive timeout is treated as no timeout.
    public init(
        minimumLimit: Int = 1,
        maximumLimit: Int = 32,
        initialLimit: Int = 8,
        backoffFactor: Double = 0.7,
        latencyDegradationFactor: Double = 2.0,
        queueTimeoutSeconds: TimeInterval? = nil
    ) {
        let floorLimit = max(1, minimumLimit)
        let ceilingLimit = max(floorLimit, maximumLimit)
        self.minimumLimit = floorLimit
        self.maximumLimit = ceilingLimit
        self.initialLimit = min(max(initialLimit, floorLimit), ceilingLimit)
        self.backoffFactor = min(max(backoffFactor, 0.1), 0.95)
        self.latencyDegradationFactor = max(latencyDegradationFactor, 1)
        self.queueTimeoutSeconds = queueTimeoutSeconds.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// What one finished request said about the server's capacity.
public enum ConcurrencySignal: Sendable, Equatable {
    /// The request completed. Its latency is the evidence.
    case succeeded(latencyMilliseconds: Double)
    /// The server refused or timed out: 429, 503, or no answer at all.
    case congested
    /// The request failed for a reason that says nothing about capacity, such as a 404.
    case inconclusive
}

/// Why the limit moved.
public enum ConcurrencyLimitChangeReason: String, Sendable, Equatable {
    /// The server refused a request or stopped answering.
    case congestion
    /// Responses got slower than the best this policy has seen.
    case latency
    /// Every slot was busy and the server kept up, so there may be room for one more.
    case headroom
}

/// The limit, and the evidence behind it.
///
/// Kept as a value type with no concurrency in it, so the algorithm can be tested by calling a
/// function rather than by racing tasks.
public struct AdaptiveConcurrencyState: Sendable, Equatable {
    /// One movement of the limit.
    public struct Change: Sendable, Equatable {
        /// The limit before.
        public let from: Int
        /// The limit after.
        public let to: Int
        /// What moved it.
        public let reason: ConcurrencyLimitChangeReason

        /// Creates a change, which is also what makes one expressible in a test's expectation.
        public init(from: Int, to: Int, reason: ConcurrencyLimitChangeReason) {
            self.from = from
            self.to = to
            self.reason = reason
        }
    }

    /// The policy in force.
    public let policy: AdaptiveConcurrencyPolicy
    /// How many requests may be in flight right now.
    public private(set) var limit: Int
    /// The fastest response seen, which is the yardstick for calling a later one slow.
    public private(set) var bestLatencyMilliseconds: Double?

    /// Starts at the policy's initial limit, with nothing observed yet.
    public init(policy: AdaptiveConcurrencyPolicy) {
        self.policy = policy
        limit = policy.initialLimit
        bestLatencyMilliseconds = nil
    }

    /// Folds one observation into the limit.
    ///
    /// - Parameters:
    ///   - signal: What the request reported.
    ///   - wasSaturated: Whether every slot was busy when this request was admitted. The limit only
    ///     grows when it was actually the thing in the way; raising it while slots sit idle would
    ///     let it drift up to the maximum without evidence that the server can take it.
    /// - Returns: The movement, or `nil` when the limit stayed where it was.
    public mutating func record(_ signal: ConcurrencySignal, wasSaturated: Bool) -> Change? {
        switch signal {
        case .inconclusive:
            return nil

        case .congested:
            return decrease(reason: .congestion)

        case let .succeeded(latency):
            guard latency.isFinite, latency >= 0 else { return nil }
            let best = bestLatencyMilliseconds.map { min($0, latency) } ?? latency
            let previousBest = bestLatencyMilliseconds
            bestLatencyMilliseconds = best

            // Compared against the best seen *before* this sample: a request cannot be slow relative
            // to itself, which is what comparing against the updated best would ask.
            if let previousBest, latency > previousBest * policy.latencyDegradationFactor {
                return decrease(reason: .latency)
            }
            guard wasSaturated else { return nil }
            return increase()
        }
    }

    private mutating func decrease(reason: ConcurrencyLimitChangeReason) -> Change? {
        let reduced = max(policy.minimumLimit, Int((Double(limit) * policy.backoffFactor).rounded(.down)))
        guard reduced != limit else { return nil }
        let change = Change(from: limit, to: reduced, reason: reason)
        limit = reduced
        return change
    }

    private mutating func increase() -> Change? {
        let raised = min(policy.maximumLimit, limit + 1)
        guard raised != limit else { return nil }
        let change = Change(from: limit, to: raised, reason: .headroom)
        limit = raised
        return change
    }
}
