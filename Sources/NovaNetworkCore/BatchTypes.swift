import Foundation

/// Configuration for bounded concurrent batch execution.
public struct BatchExecutionOptions: Sendable, Equatable {
    /// Maximum number of child requests that may execute at the same time.
    public let maxConcurrentRequests: Int

    /// Creates batch execution options.
    ///
    /// - Parameter maxConcurrentRequests: Positive concurrency bound. Values below one
    ///   are rejected before any request starts.
    public init(maxConcurrentRequests: Int = 6) {
        self.maxConcurrentRequests = maxConcurrentRequests
    }
}

/// Configuration errors detected before a batch starts.
public enum BatchExecutionError: Error, Sendable, Equatable {
    /// The concurrency limit was less than one.
    case invalidMaxConcurrentRequests(Int)
}

/// The result of one request in a collecting batch.
public struct BatchItemResult: Sendable {
    /// Original position of the request in the batch input.
    public let index: Int

    /// Request associated with this result.
    public let request: APIRequest

    /// Request body on success or the mapped network error on failure.
    public let result: Result<Data, NetworkError>

    /// Creates an indexed batch result.
    public init(index: Int, request: APIRequest, result: Result<Data, NetworkError>) {
        self.index = index
        self.request = request
        self.result = result
    }
}

/// Aggregate batch telemetry emitted once when a batch reaches a terminal state.
public struct TelemetryBatchContext: Sendable {
    /// Number of requests supplied by the caller.
    public let total: Int

    /// Number of observed successful results.
    public let succeeded: Int

    /// Number of observed failed results.
    public let failed: Int

    /// Number of requests cancelled or not started.
    public let cancelled: Int

    /// Configured concurrency bound.
    public let maxConcurrentRequests: Int

    /// Total batch duration in milliseconds.
    public let durationMilliseconds: Double

    /// `true` for collecting execution and `false` for fail-fast execution.
    public let collectedFailures: Bool

    /// Creates aggregate batch telemetry.
    public init(
        total: Int,
        succeeded: Int,
        failed: Int,
        cancelled: Int,
        maxConcurrentRequests: Int,
        durationMilliseconds: Double,
        collectedFailures: Bool
    ) {
        self.total = total
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
        self.maxConcurrentRequests = maxConcurrentRequests
        self.durationMilliseconds = durationMilliseconds
        self.collectedFailures = collectedFailures
    }
}
