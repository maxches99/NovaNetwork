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

    public init(
        coalescerLimitsOverride: RequestCoalescer<NetworkResponse, NetworkError>.Limits? = nil,
        priority: RequestPriority = .medium,
        capacityScheduling: CapacityScheduling = .bypassWhenAtCapacity,
        coalescingMode: CoalescingMode = .default,
        deadlineBudgetSeconds: TimeInterval? = nil,
        circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
        rateLimitPolicy: RateLimitPolicy? = nil,
        idempotencyPolicy: IdempotencyPolicy? = nil
    ) {
        self.coalescerLimitsOverride = coalescerLimitsOverride
        self.priority = priority
        self.capacityScheduling = capacityScheduling
        self.coalescingMode = coalescingMode
        self.deadlineBudgetSeconds = deadlineBudgetSeconds.map { max(0, $0) }
        self.circuitBreakerPolicy = circuitBreakerPolicy
        self.rateLimitPolicy = rateLimitPolicy
        self.idempotencyPolicy = idempotencyPolicy
    }
}
