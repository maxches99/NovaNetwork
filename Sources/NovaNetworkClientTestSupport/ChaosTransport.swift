import Foundation
import NovaNetworkClient

/// Configures the failure and latency behavior injected by ``ChaosTransport``.
public struct ChaosPolicy: Sendable {
    /// Fraction of requests that fail with `failureFactory`'s error, clamped to `0...1`.
    public var failureRate: Double
    /// Produces the error thrown for an injected failure.
    public var failureFactory: @Sendable () -> NetworkError
    /// Range of extra delay (nanoseconds) applied before every request, or `nil` for none.
    public var delayRange: ClosedRange<UInt64>?

    /// Creates a chaos injection policy.
    public init(
        failureRate: Double = 0,
        failureFactory: @escaping @Sendable () -> NetworkError = {
            .transport(underlying: URLError(.networkConnectionLost))
        },
        delayRange: ClosedRange<UInt64>? = nil
    ) {
        self.failureRate = min(max(failureRate, 0), 1)
        self.failureFactory = failureFactory
        self.delayRange = delayRange
    }
}

/// Wraps another transport, injecting configurable random failures and latency, for exercising
/// retry, circuit breaker, offline queue, and other resilience code paths under unreliable
/// network conditions.
///
/// Use a seeded ``TestRetryRandom`` (or any deterministic `RetryRandomGenerator`) for
/// reproducible test runs instead of the default system randomness.
public actor ChaosTransport: NetworkTransport {
    private let wrapped: any NetworkTransport
    private let policy: ChaosPolicy
    private let randomGenerator: any RetryRandomGenerator
    private var executedCount = 0
    private var injectedFailureCount = 0

    /// Creates a chaos-injecting wrapper around `transport`.
    public init(
        wrapping transport: any NetworkTransport,
        policy: ChaosPolicy,
        randomGenerator: any RetryRandomGenerator = SystemRetryRandomGenerator()
    ) {
        self.wrapped = transport
        self.policy = policy
        self.randomGenerator = randomGenerator
    }

    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        executedCount += 1
        if let delayRange = policy.delayRange, delayRange.upperBound > delayRange.lowerBound {
            let fraction = randomGenerator.nextDouble(in: 0...1)
            let span = Double(delayRange.upperBound - delayRange.lowerBound)
            let delay = delayRange.lowerBound + UInt64(fraction * span)
            try? await Task.sleep(nanoseconds: delay)
        }
        if policy.failureRate > 0, randomGenerator.nextDouble(in: 0...1) < policy.failureRate {
            injectedFailureCount += 1
            throw policy.failureFactory()
        }
        return try await wrapped.execute(request)
    }

    /// Total number of requests passed through this transport, whether they failed, were
    /// delayed, or succeeded.
    public func callCount() -> Int {
        executedCount
    }

    /// Number of requests that failed with an injected chaos error, rather than reaching the
    /// wrapped transport.
    public func failureCount() -> Int {
        injectedFailureCount
    }
}
