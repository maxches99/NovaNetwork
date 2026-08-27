import Foundation

/// Aggregates over a set of records: the numbers you want before reading any single request.
public struct DiagnosticsSummary: Sendable, Equatable {
    /// How many records the summary covers.
    public let requestCount: Int
    /// Requests that completed with a 2xx or 3xx status.
    public let succeededCount: Int
    /// Requests that completed with a status of 400 or above.
    public let httpErrorCount: Int
    /// Requests that ended in a transport, decoding, or policy error.
    public let failedCount: Int
    /// Requests that were cancelled.
    public let cancelledCount: Int
    /// Requests still running, or whose end was never observed.
    public let inFlightCount: Int
    /// Requests that took more than one attempt.
    public let retriedCount: Int
    /// Requests that joined another in-flight request instead of starting their own.
    public let coalescedCount: Int
    /// Requests for which a cache outcome was observed.
    public let cacheObservedCount: Int
    /// Requests answered from the cache.
    public let cacheServedCount: Int
    /// Median duration across finished requests.
    public let medianDurationMilliseconds: Double?
    /// 95th percentile duration across finished requests.
    public let p95DurationMilliseconds: Double?

    /// Builds a summary from records.
    public init(records: [RequestDiagnostic]) {
        requestCount = records.count
        succeededCount = records.count { record in
            if case let .completed(status) = record.outcome { status < 400 } else { false }
        }
        httpErrorCount = records.count { record in
            if case let .completed(status) = record.outcome { status >= 400 } else { false }
        }
        failedCount = records.count { if case .failed = $0.outcome { true } else { false } }
        cancelledCount = records.count { if case .cancelled = $0.outcome { true } else { false } }
        inFlightCount = records.count { !$0.outcome.isFinished }
        retriedCount = records.count(where: \.wasRetried)
        coalescedCount = records.count(where: \.wasCoalesced)

        let withCacheOutcome = records.compactMap(\.cacheOutcome)
        cacheObservedCount = withCacheOutcome.count
        cacheServedCount = withCacheOutcome.count(where: \.servedFromCache)

        let durations = records.compactMap(\.durationMilliseconds).sorted()
        medianDurationMilliseconds = Self.percentile(0.5, of: durations)
        p95DurationMilliseconds = Self.percentile(0.95, of: durations)
    }

    /// Share of finished requests that failed: a transport error, or any status from 400 up.
    ///
    /// HTTP errors count. A summary reading "0% failed" next to a list of 500s would be worse than
    /// no summary at all.
    public var failureRate: Double {
        let finished = succeededCount + httpErrorCount + failedCount + cancelledCount
        return finished == 0 ? 0 : Double(httpErrorCount + failedCount) / Double(finished)
    }

    /// Share of requests that joined an in-flight request instead of starting their own.
    public var coalescingRate: Double {
        requestCount == 0 ? 0 : Double(coalescedCount) / Double(requestCount)
    }

    /// Share of cache-observed requests answered from the cache.
    ///
    /// Measured against requests where a cache outcome was actually observed, not against every
    /// request: a client with caching disabled would otherwise report a misleading zero.
    public var cacheHitRate: Double {
        cacheObservedCount == 0 ? 0 : Double(cacheServedCount) / Double(cacheObservedCount)
    }

    /// A one-line rendering, the way the panel header reads.
    public var shortDescription: String {
        String(
            format: "%d requests · %.0f%% failed · %.0f%% coalesced · %.0f%% cache hits",
            requestCount,
            failureRate * 100,
            coalescingRate * 100,
            cacheHitRate * 100
        )
    }

    /// Nearest-rank percentile over pre-sorted values.
    private static func percentile(_ fraction: Double, of sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}
