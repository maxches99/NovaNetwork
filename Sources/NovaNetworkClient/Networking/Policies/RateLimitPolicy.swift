import Foundation

public struct RateLimitPolicy: Sendable {
    public let maxRequests: Int
    public let intervalSeconds: TimeInterval

    public init(maxRequests: Int, intervalSeconds: TimeInterval) {
        self.maxRequests = max(1, maxRequests)
        self.intervalSeconds = max(0.001, intervalSeconds)
    }
}

actor KeyRateLimiter {
    private var eventsByKey: [String: [UInt64]] = [:]

    func acquire(key: String, policy: RateLimitPolicy) -> TimeInterval? {
        let now = DispatchTime.now().uptimeNanoseconds
        let intervalNs = UInt64(policy.intervalSeconds * 1_000_000_000)
        let lowerBound = now >= intervalNs ? now - intervalNs : 0

        var events = eventsByKey[key, default: []].filter { $0 >= lowerBound }
        if events.count < policy.maxRequests {
            events.append(now)
            eventsByKey[key] = events
            return nil
        }

        guard let earliest = events.min() else {
            return policy.intervalSeconds
        }
        let unlockNs = earliest.saturatingAdd(intervalNs)
        let retryNs = unlockNs > now ? (unlockNs - now) : 0
        eventsByKey[key] = events
        return TimeInterval(retryNs) / 1_000_000_000
    }
}

private extension UInt64 {
    func saturatingAdd(_ rhs: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}
