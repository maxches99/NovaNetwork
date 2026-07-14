import NovaNetworkCore
import Foundation

/// Observable cache, retry, policy, and request lifecycle events.
public enum NetworkClientEvent: Sendable {
    case cacheHit(key: String, isStale: Bool, ageMilliseconds: Double)
    case cacheMiss(key: String)
    case cacheRevalidated(key: String, ageMilliseconds: Double)
    /// Stale cached content was served after an eligible revalidation failure.
    case cacheStaleIfError(key: String, ageMilliseconds: Double, reason: String)
    case requestAttempt(key: String, attempt: Int)
    case retryScheduled(key: String, nextAttempt: Int, delayMilliseconds: Double, reason: String)
    case retrySkipped(key: String, attempt: Int, reason: String)
    case retryExhausted(key: String, attempts: Int, reason: String)
    case requestPolicyUpdated(scope: String, changedFields: [String])
    case requestSucceeded(key: String, attempts: Int)
    case requestFailed(key: String, attempts: Int, reason: String, remainingBudgetMilliseconds: Double?)
    case requestRateLimited(key: String, retryAfterSeconds: TimeInterval?)
    case circuitBreakerOpen(identifier: String)
    case circuitBreakerTransition(
        identifier: String,
        fromState: String,
        toState: String,
        failureCount: Int,
        openDurationMilliseconds: Double
    )
    case memoryPressureHandled(cacheCleared: Bool, inFlightCancelled: Bool)
    case cacheInvalidated(key: String)
}
