import NovaNetworkCore
import Foundation

public enum RequestPriority: Int, Sendable {
    case low = 0
    case medium = 1
    case high = 2
}

public enum CapacityScheduling: Sendable {
    case bypassWhenAtCapacity
    case queueByPriority
}

public enum CoalescingMode: Sendable, Equatable {
    case `default`
    case custom(String)
    case disabled
}

public struct RequestExecutionOptions: Sendable {
    public let coalescerLimitsOverride: RequestCoalescer<NetworkResponse, NetworkError>.Limits?
    public let priority: RequestPriority
    public let capacityScheduling: CapacityScheduling
    public let coalescingMode: CoalescingMode
    public let deadlineBudgetSeconds: TimeInterval?
    public let circuitBreakerPolicy: CircuitBreakerPolicy?
    public let rateLimitPolicy: RateLimitPolicy?
    public let idempotencyPolicy: IdempotencyPolicy?
    public let offlineQueuePolicy: OfflineQueuePolicy
    /// Whether this request must go out whatever the network path looks like.
    ///
    /// A sign-in, a token refresh, a payment confirmation. `NetworkPathPolicy` lets essential
    /// requests through a metered or constrained path; a policy that also blocked the login would
    /// be a policy nobody could adopt.
    public let isEssential: Bool

    public init(
        coalescerLimitsOverride: RequestCoalescer<NetworkResponse, NetworkError>.Limits? = nil,
        priority: RequestPriority = .medium,
        capacityScheduling: CapacityScheduling = .bypassWhenAtCapacity,
        coalescingMode: CoalescingMode = .default,
        deadlineBudgetSeconds: TimeInterval? = nil,
        circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
        rateLimitPolicy: RateLimitPolicy? = nil,
        idempotencyPolicy: IdempotencyPolicy? = nil,
        offlineQueuePolicy: OfflineQueuePolicy = .disabled,
        isEssential: Bool = false
    ) {
        self.coalescerLimitsOverride = coalescerLimitsOverride
        self.priority = priority
        self.capacityScheduling = capacityScheduling
        self.coalescingMode = coalescingMode
        self.deadlineBudgetSeconds = deadlineBudgetSeconds.map { max(0, $0) }
        self.circuitBreakerPolicy = circuitBreakerPolicy
        self.rateLimitPolicy = rateLimitPolicy
        self.idempotencyPolicy = idempotencyPolicy
        self.offlineQueuePolicy = offlineQueuePolicy
        self.isEssential = isEssential
    }
}
