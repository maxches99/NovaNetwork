import Foundation

public enum TelemetryCoalescingMode: String, Sendable {
    case `default`
    case custom
    case disabled
}

public struct TelemetryRequestContext: Sendable {
    public let key: String
    public let attempt: Int
    public let coalescingMode: TelemetryCoalescingMode
    public let request: APIRequest

    public init(
        key: String,
        attempt: Int,
        coalescingMode: TelemetryCoalescingMode = .default,
        request: APIRequest
    ) {
        self.key = key
        self.attempt = attempt
        self.coalescingMode = coalescingMode
        self.request = request
    }
}

public struct TelemetryResponseContext: Sendable {
    public let request: TelemetryRequestContext
    public let response: NetworkResponse?
    public let error: NetworkError?
    public let durationMilliseconds: Double

    public init(
        request: TelemetryRequestContext,
        response: NetworkResponse?,
        error: NetworkError?,
        durationMilliseconds: Double
    ) {
        self.request = request
        self.response = response
        self.error = error
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum TelemetryCoalescerEventType: String, Sendable {
    case started
    case coalesced
    case bypassed
    case waiterCancelled
    case timedOut
    case finished
}

public struct TelemetryCoalescerContext: Sendable {
    public let type: TelemetryCoalescerEventType
    public let key: String
    public let waiterCount: Int?
    public let reason: String?
    public let durationMilliseconds: Double?
    public let wasCancelled: Bool?

    public init(
        type: TelemetryCoalescerEventType,
        key: String,
        waiterCount: Int? = nil,
        reason: String? = nil,
        durationMilliseconds: Double? = nil,
        wasCancelled: Bool? = nil
    ) {
        self.type = type
        self.key = key
        self.waiterCount = waiterCount
        self.reason = reason
        self.durationMilliseconds = durationMilliseconds
        self.wasCancelled = wasCancelled
    }
}

public struct TelemetryRetryContext: Sendable {
    public let key: String
    public let attempt: Int
    public let nextAttempt: Int
    public let delayMilliseconds: Double
    public let reason: String
    public let coalescingMode: TelemetryCoalescingMode
    public let request: APIRequest

    public init(
        key: String,
        attempt: Int,
        nextAttempt: Int,
        delayMilliseconds: Double,
        reason: String,
        coalescingMode: TelemetryCoalescingMode = .default,
        request: APIRequest
    ) {
        self.key = key
        self.attempt = attempt
        self.nextAttempt = nextAttempt
        self.delayMilliseconds = delayMilliseconds
        self.reason = reason
        self.coalescingMode = coalescingMode
        self.request = request
    }
}

public struct TelemetryCancellationContext: Sendable {
    public let key: String
    public let attempt: Int
    public let reason: String
    public let coalescingMode: TelemetryCoalescingMode
    public let request: APIRequest

    public init(
        key: String,
        attempt: Int,
        reason: String,
        coalescingMode: TelemetryCoalescingMode = .default,
        request: APIRequest
    ) {
        self.key = key
        self.attempt = attempt
        self.reason = reason
        self.coalescingMode = coalescingMode
        self.request = request
    }
}

public struct TelemetryQueueContext: Sendable {
    public let key: String
    public let queueDepth: Int
    public let waitMilliseconds: Double

    public init(key: String, queueDepth: Int, waitMilliseconds: Double) {
        self.key = key
        self.queueDepth = queueDepth
        self.waitMilliseconds = waitMilliseconds
    }
}

public struct TelemetryRetryExhaustedContext: Sendable {
    public let key: String
    public let attempts: Int
    public let reason: String
    public let coalescingMode: TelemetryCoalescingMode
    public let request: APIRequest

    public init(
        key: String,
        attempts: Int,
        reason: String,
        coalescingMode: TelemetryCoalescingMode,
        request: APIRequest
    ) {
        self.key = key
        self.attempts = attempts
        self.reason = reason
        self.coalescingMode = coalescingMode
        self.request = request
    }
}

public struct TelemetryCircuitBreakerTransitionContext: Sendable {
    public let identifier: String
    public let fromState: String
    public let toState: String
    public let failureCount: Int
    public let openDurationMilliseconds: Double

    public init(
        identifier: String,
        fromState: String,
        toState: String,
        failureCount: Int,
        openDurationMilliseconds: Double
    ) {
        self.identifier = identifier
        self.fromState = fromState
        self.toState = toState
        self.failureCount = failureCount
        self.openDurationMilliseconds = openDurationMilliseconds
    }
}

public struct NetworkTelemetryHooks: Sendable {
    public typealias OnRequestStart = @Sendable (TelemetryRequestContext) -> Void
    public typealias OnRequestEnd = @Sendable (TelemetryResponseContext) -> Void
    public typealias OnCoalescerEvent = @Sendable (TelemetryCoalescerContext) -> Void
    public typealias OnRetryScheduled = @Sendable (TelemetryRetryContext) -> Void
    public typealias OnRetryExhausted = @Sendable (TelemetryRetryExhaustedContext) -> Void
    public typealias OnRequestCancelled = @Sendable (TelemetryCancellationContext) -> Void
    public typealias OnQueueMetrics = @Sendable (TelemetryQueueContext) -> Void
    public typealias OnCircuitBreakerTransition = @Sendable (TelemetryCircuitBreakerTransitionContext) -> Void

    public let onRequestStart: OnRequestStart?
    public let onRequestEnd: OnRequestEnd?
    public let onCoalescerEvent: OnCoalescerEvent?
    public let onRetryScheduled: OnRetryScheduled?
    public let onRetryExhausted: OnRetryExhausted?
    public let onRequestCancelled: OnRequestCancelled?
    public let onQueueMetrics: OnQueueMetrics?
    public let onCircuitBreakerTransition: OnCircuitBreakerTransition?

    public init(
        onRequestStart: OnRequestStart? = nil,
        onRequestEnd: OnRequestEnd? = nil,
        onCoalescerEvent: OnCoalescerEvent? = nil,
        onRetryScheduled: OnRetryScheduled? = nil,
        onRetryExhausted: OnRetryExhausted? = nil,
        onRequestCancelled: OnRequestCancelled? = nil,
        onQueueMetrics: OnQueueMetrics? = nil,
        onCircuitBreakerTransition: OnCircuitBreakerTransition? = nil
    ) {
        self.onRequestStart = onRequestStart
        self.onRequestEnd = onRequestEnd
        self.onCoalescerEvent = onCoalescerEvent
        self.onRetryScheduled = onRetryScheduled
        self.onRetryExhausted = onRetryExhausted
        self.onRequestCancelled = onRequestCancelled
        self.onQueueMetrics = onQueueMetrics
        self.onCircuitBreakerTransition = onCircuitBreakerTransition
    }
}
