import Foundation

public struct NetworkClientPreset: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case restHeavy = "rest_heavy"
        case realtimeHeavy = "realtime_heavy"
        case offlineFirst = "offline_first"
    }

    public struct RequestOverrides: Sendable {
        public let priority: RequestPriority?
        public let capacityScheduling: CapacityScheduling?
        public let coalescingMode: CoalescingMode?
        public let deadlineBudgetSeconds: TimeInterval?
        public let circuitBreakerPolicy: CircuitBreakerPolicy?
        public let rateLimitPolicy: RateLimitPolicy?
        public let idempotencyPolicy: IdempotencyPolicy?
        public let offlineQueuePolicy: OfflineQueuePolicy?

        public init(
            priority: RequestPriority? = nil,
            capacityScheduling: CapacityScheduling? = nil,
            coalescingMode: CoalescingMode? = nil,
            deadlineBudgetSeconds: TimeInterval? = nil,
            circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
            rateLimitPolicy: RateLimitPolicy? = nil,
            idempotencyPolicy: IdempotencyPolicy? = nil,
            offlineQueuePolicy: OfflineQueuePolicy? = nil
        ) {
            self.priority = priority
            self.capacityScheduling = capacityScheduling
            self.coalescingMode = coalescingMode
            self.deadlineBudgetSeconds = deadlineBudgetSeconds.map { max(0, $0) }
            self.circuitBreakerPolicy = circuitBreakerPolicy
            self.rateLimitPolicy = rateLimitPolicy
            self.idempotencyPolicy = idempotencyPolicy
            self.offlineQueuePolicy = offlineQueuePolicy
        }
    }

    public let kind: Kind
    public let retryPolicy: RetryPolicy
    public let defaultCachePolicy: CachePolicy
    public let runtimePolicy: NetworkClientRuntimePolicy
    public let defaultRequestOptions: RequestExecutionOptions
    public let tradeoffs: [String]

    public init(
        kind: Kind,
        retryPolicy: RetryPolicy,
        defaultCachePolicy: CachePolicy,
        runtimePolicy: NetworkClientRuntimePolicy,
        defaultRequestOptions: RequestExecutionOptions,
        tradeoffs: [String]
    ) {
        self.kind = kind
        self.retryPolicy = retryPolicy
        self.defaultCachePolicy = defaultCachePolicy
        self.runtimePolicy = runtimePolicy
        self.defaultRequestOptions = defaultRequestOptions
        self.tradeoffs = tradeoffs
    }

    public func requestOptions(overrides: RequestOverrides = .init()) -> RequestExecutionOptions {
        RequestExecutionOptions(
            coalescerLimitsOverride: defaultRequestOptions.coalescerLimitsOverride,
            priority: overrides.priority ?? defaultRequestOptions.priority,
            capacityScheduling: overrides.capacityScheduling ?? defaultRequestOptions.capacityScheduling,
            coalescingMode: overrides.coalescingMode ?? defaultRequestOptions.coalescingMode,
            deadlineBudgetSeconds: overrides.deadlineBudgetSeconds ?? defaultRequestOptions.deadlineBudgetSeconds,
            circuitBreakerPolicy: overrides.circuitBreakerPolicy ?? defaultRequestOptions.circuitBreakerPolicy,
            rateLimitPolicy: overrides.rateLimitPolicy ?? defaultRequestOptions.rateLimitPolicy,
            idempotencyPolicy: overrides.idempotencyPolicy ?? defaultRequestOptions.idempotencyPolicy,
            offlineQueuePolicy: overrides.offlineQueuePolicy ?? defaultRequestOptions.offlineQueuePolicy
        )
    }
}

public extension NetworkClientPreset {
    static var restHeavy: NetworkClientPreset {
        NetworkClientPreset(
            kind: .restHeavy,
            retryPolicy: RetryPolicy(
                maxAttempts: 3,
                retryBudget: 6,
                retryNonIdempotentRequests: false,
                baseDelayNanoseconds: 250_000_000,
                maxDelayNanoseconds: 2_000_000_000,
                maxRetryAfterNanoseconds: 60_000_000_000,
                respectRetryAfterHeader: true,
                jitterRange: 0.8...1.2,
                retriableHTTPStatusCodes: [408, 429, 500, 502, 503, 504],
                retriableURLErrorCodes: [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost],
                adaptiveProfiles: [
                    .rateLimited: RetryProfile(maxAttempts: 4, baseDelayNanoseconds: 500_000_000, maxDelayNanoseconds: 5_000_000_000, jitterRange: 0.9...1.15),
                    .serverError: RetryProfile(maxAttempts: 3, baseDelayNanoseconds: 300_000_000, maxDelayNanoseconds: 2_500_000_000, jitterRange: 0.8...1.2)
                ]
            ),
            defaultCachePolicy: .cacheFirst(maxAge: 15),
            runtimePolicy: NetworkClientRuntimePolicy(
                deadlineBudgetSeconds: 8,
                circuitBreakerPolicy: CircuitBreakerPolicy(
                    scope: .host,
                    failureThreshold: 5,
                    cooldownSeconds: 8,
                    halfOpenJitterSeconds: 1,
                    probePolicy: .singleProbe
                ),
                coalescingPolicy: CoalescingPolicy(dedupeTTLSeconds: 2)
            ),
            defaultRequestOptions: RequestExecutionOptions(
                priority: .medium,
                capacityScheduling: .queueByPriority,
                coalescingMode: .default,
                rateLimitPolicy: RateLimitPolicy(maxRequests: 12, intervalSeconds: 1),
                idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
                offlineQueuePolicy: .disabled
            ),
            tradeoffs: [
                "Prioritizes throughput and API-protection over lowest per-request latency.",
                "Cache-first defaults can serve slightly stale data within max-age windows.",
                "Aggressive protection (rate limit + breaker) may surface controlled failures earlier."
            ]
        )
    }

    static var realtimeHeavy: NetworkClientPreset {
        NetworkClientPreset(
            kind: .realtimeHeavy,
            retryPolicy: RetryPolicy(
                maxAttempts: 2,
                retryBudget: 3,
                retryNonIdempotentRequests: false,
                baseDelayNanoseconds: 120_000_000,
                maxDelayNanoseconds: 900_000_000,
                maxRetryAfterNanoseconds: 5_000_000_000,
                respectRetryAfterHeader: true,
                jitterRange: 0.9...1.1,
                retriableHTTPStatusCodes: [408, 429, 500, 502, 503, 504],
                retriableURLErrorCodes: [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost],
                adaptiveProfiles: [
                    .timeout: RetryProfile(maxAttempts: 2, baseDelayNanoseconds: 80_000_000, maxDelayNanoseconds: 400_000_000, jitterRange: 0.9...1.1),
                    .networkUnreachable: RetryProfile(maxAttempts: 2, baseDelayNanoseconds: 150_000_000, maxDelayNanoseconds: 1_000_000_000, jitterRange: 0.9...1.2)
                ]
            ),
            defaultCachePolicy: .networkOnly,
            runtimePolicy: NetworkClientRuntimePolicy(
                deadlineBudgetSeconds: 2.5,
                circuitBreakerPolicy: CircuitBreakerPolicy(
                    scope: .host,
                    failureThreshold: 3,
                    cooldownSeconds: 4,
                    halfOpenJitterSeconds: 0.5,
                    probePolicy: .parallelProbes(maxConcurrent: 2)
                ),
                coalescingPolicy: CoalescingPolicy(dedupeTTLSeconds: 0.25)
            ),
            defaultRequestOptions: RequestExecutionOptions(
                priority: .high,
                capacityScheduling: .queueByPriority,
                coalescingMode: .default,
                rateLimitPolicy: RateLimitPolicy(maxRequests: 30, intervalSeconds: 1),
                idempotencyPolicy: nil,
                offlineQueuePolicy: .disabled
            ),
            tradeoffs: [
                "Favors low-latency retries and fast failover over deep retry persistence.",
                "Network-only reads avoid stale snapshots but increase dependency on connectivity.",
                "Higher per-key request budget can increase backend pressure in bursty sessions."
            ]
        )
    }

    static var offlineFirst: NetworkClientPreset {
        NetworkClientPreset(
            kind: .offlineFirst,
            retryPolicy: RetryPolicy(
                maxAttempts: 4,
                retryBudget: 8,
                retryNonIdempotentRequests: false,
                baseDelayNanoseconds: 300_000_000,
                maxDelayNanoseconds: 5_000_000_000,
                maxRetryAfterNanoseconds: 90_000_000_000,
                respectRetryAfterHeader: true,
                jitterRange: 0.85...1.2,
                retriableHTTPStatusCodes: [408, 409, 429, 500, 502, 503, 504],
                retriableURLErrorCodes: [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost],
                adaptiveProfiles: [
                    .networkUnreachable: RetryProfile(maxAttempts: 4, baseDelayNanoseconds: 500_000_000, maxDelayNanoseconds: 8_000_000_000, jitterRange: 0.9...1.2),
                    .rateLimited: RetryProfile(maxAttempts: 5, baseDelayNanoseconds: 700_000_000, maxDelayNanoseconds: 10_000_000_000, jitterRange: 0.95...1.1)
                ]
            ),
            defaultCachePolicy: .staleWhileRevalidate(maxAge: 10, staleAge: 90),
            runtimePolicy: NetworkClientRuntimePolicy(
                deadlineBudgetSeconds: 12,
                circuitBreakerPolicy: CircuitBreakerPolicy(
                    scope: .host,
                    failureThreshold: 6,
                    cooldownSeconds: 6,
                    halfOpenJitterSeconds: 1,
                    probePolicy: .singleProbe
                ),
                coalescingPolicy: CoalescingPolicy(dedupeTTLSeconds: 8)
            ),
            defaultRequestOptions: RequestExecutionOptions(
                priority: .medium,
                capacityScheduling: .queueByPriority,
                coalescingMode: .default,
                rateLimitPolicy: RateLimitPolicy(maxRequests: 8, intervalSeconds: 1),
                idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
                offlineQueuePolicy: OfflineQueuePolicy(
                    mode: .enqueueWhenOffline,
                    maxEntries: 5_000,
                    ttlSeconds: 7 * 24 * 60 * 60,
                    maxReplayAttempts: 8,
                    replayConflictPolicy: .manualReview,
                    replayDedupeWindowSeconds: 24 * 60 * 60,
                    replayPriority: .normal,
                    replaySchedulerPolicy: .init()
                )
            ),
            tradeoffs: [
                "Prioritizes delivery durability over immediate consistency when disconnected.",
                "Queued writes may require conflict/manual-review flows before final success.",
                "Longer replay windows can increase local storage footprint."
            ]
        )
    }
}

public extension NetworkClient {
    func applyRuntimePolicy(from preset: NetworkClientPreset, scope: RuntimePolicyScope = .global) async {
        await updateRuntimePolicy(preset.runtimePolicy, scope: scope)
    }
}
