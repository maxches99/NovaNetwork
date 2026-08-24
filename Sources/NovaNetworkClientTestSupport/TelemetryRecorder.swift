import Foundation
import NovaNetworkClient

/// Records every event delivered to a ``NetworkTelemetryHooks`` set built by
/// ``makeHooks()``, so tests can assert on what telemetry a client actually emitted instead of
/// re-deriving it from side effects.
///
/// `NetworkTelemetryHooks` closures are synchronous, so recording hops onto this actor
/// asynchronously; a test that asserts immediately after an operation completes may need to
/// poll briefly first — see ``waitUntil(timeoutNanoseconds:_:)``.
public actor TelemetryRecorder {
    private(set) var requestStarts: [TelemetryRequestContext] = []
    private(set) var requestEnds: [TelemetryResponseContext] = []
    private(set) var coalescerEvents: [TelemetryCoalescerContext] = []
    private(set) var retryScheduled: [TelemetryRetryContext] = []
    private(set) var retryExhausted: [TelemetryRetryExhaustedContext] = []
    private(set) var retrySkipped: [TelemetryRetrySkippedContext] = []
    private(set) var cancellations: [TelemetryCancellationContext] = []
    private(set) var queueMetrics: [TelemetryQueueContext] = []
    private(set) var offlineQueueEvents: [TelemetryOfflineQueueContext] = []
    private(set) var webSocketEvents: [TelemetryWebSocketContext] = []
    private(set) var circuitBreakerTransitions: [TelemetryCircuitBreakerTransitionContext] = []
    private(set) var policyUpdates: [TelemetryPolicyUpdateContext] = []
    private(set) var batchCompletions: [TelemetryBatchContext] = []
    private(set) var transferEvents: [TelemetryTransferContext] = []
    private(set) var httpAuthRefreshEvents: [TelemetryHTTPAuthRefreshContext] = []

    /// Creates an empty recorder; wire it to a client with ``makeHooks()``.
    public init() {}

    /// Builds telemetry hooks that record every event onto this recorder.
    public func makeHooks() -> NetworkTelemetryHooks {
        NetworkTelemetryHooks(
            onRequestStart: { [weak self] context in Task { await self?.recordRequestStart(context) } },
            onRequestEnd: { [weak self] context in Task { await self?.recordRequestEnd(context) } },
            onCoalescerEvent: { [weak self] context in Task { await self?.recordCoalescerEvent(context) } },
            onRetryScheduled: { [weak self] context in Task { await self?.recordRetryScheduled(context) } },
            onRetryExhausted: { [weak self] context in Task { await self?.recordRetryExhausted(context) } },
            onRetrySkipped: { [weak self] context in Task { await self?.recordRetrySkipped(context) } },
            onRequestCancelled: { [weak self] context in Task { await self?.recordCancellation(context) } },
            onQueueMetrics: { [weak self] context in Task { await self?.recordQueueMetrics(context) } },
            onOfflineQueueEvent: { [weak self] context in Task { await self?.recordOfflineQueueEvent(context) } },
            onWebSocketEvent: { [weak self] context in Task { await self?.recordWebSocketEvent(context) } },
            onCircuitBreakerTransition: { [weak self] context in
                Task { await self?.recordCircuitBreakerTransition(context) }
            },
            onPolicyUpdated: { [weak self] context in Task { await self?.recordPolicyUpdate(context) } },
            onBatchCompleted: { [weak self] context in Task { await self?.recordBatchCompletion(context) } },
            onTransferEvent: { [weak self] context in Task { await self?.recordTransferEvent(context) } },
            onHTTPAuthRefresh: { [weak self] context in
                Task { await self?.recordHTTPAuthRefreshEvent(context) }
            }
        )
    }

    private func recordRequestStart(_ context: TelemetryRequestContext) { requestStarts.append(context) }
    private func recordRequestEnd(_ context: TelemetryResponseContext) { requestEnds.append(context) }
    private func recordCoalescerEvent(_ context: TelemetryCoalescerContext) { coalescerEvents.append(context) }
    private func recordRetryScheduled(_ context: TelemetryRetryContext) { retryScheduled.append(context) }
    private func recordRetryExhausted(_ context: TelemetryRetryExhaustedContext) { retryExhausted.append(context) }
    private func recordRetrySkipped(_ context: TelemetryRetrySkippedContext) { retrySkipped.append(context) }
    private func recordCancellation(_ context: TelemetryCancellationContext) { cancellations.append(context) }
    private func recordQueueMetrics(_ context: TelemetryQueueContext) { queueMetrics.append(context) }
    private func recordOfflineQueueEvent(_ context: TelemetryOfflineQueueContext) {
        offlineQueueEvents.append(context)
    }
    private func recordWebSocketEvent(_ context: TelemetryWebSocketContext) { webSocketEvents.append(context) }
    private func recordCircuitBreakerTransition(_ context: TelemetryCircuitBreakerTransitionContext) {
        circuitBreakerTransitions.append(context)
    }
    private func recordPolicyUpdate(_ context: TelemetryPolicyUpdateContext) { policyUpdates.append(context) }
    private func recordBatchCompletion(_ context: TelemetryBatchContext) { batchCompletions.append(context) }
    private func recordTransferEvent(_ context: TelemetryTransferContext) { transferEvents.append(context) }
    private func recordHTTPAuthRefreshEvent(_ context: TelemetryHTTPAuthRefreshContext) {
        httpAuthRefreshEvents.append(context)
    }

    public func requestStartCount() -> Int { requestStarts.count }
    public func requestEndCount() -> Int { requestEnds.count }
    public func coalescerEventCount() -> Int { coalescerEvents.count }
    public func coalescerEventTypes() -> [TelemetryCoalescerEventType] { coalescerEvents.map(\.type) }
    public func retryScheduledCount() -> Int { retryScheduled.count }
    public func retryExhaustedCount() -> Int { retryExhausted.count }
    public func retrySkippedCount() -> Int { retrySkipped.count }
    public func cancellationCount() -> Int { cancellations.count }
    public func queueMetricsSnapshots() -> [TelemetryQueueContext] { queueMetrics }
    public func offlineQueueEventTypes() -> [TelemetryOfflineQueueEventType] { offlineQueueEvents.map(\.type) }
    public func webSocketEventTypes() -> [TelemetryWebSocketEventType] { webSocketEvents.map(\.type) }
    public func circuitBreakerTransitionSnapshots() -> [TelemetryCircuitBreakerTransitionContext] {
        circuitBreakerTransitions
    }
    public func policyUpdateSnapshots() -> [TelemetryPolicyUpdateContext] { policyUpdates }
    public func batchCompletionSnapshots() -> [TelemetryBatchContext] { batchCompletions }
    public func transferEventSnapshots() -> [TelemetryTransferContext] { transferEvents }
    public func httpAuthRefreshEventSnapshots() -> [TelemetryHTTPAuthRefreshContext] { httpAuthRefreshEvents }
}

/// Polls `condition` until it returns `true` or `timeoutNanoseconds` elapses.
///
/// Telemetry recording (like other actor-hop-based async side effects) can lag slightly behind
/// the operation that triggered it; use this instead of a fixed `Task.sleep` to wait exactly as
/// long as needed, and no longer.
public func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ condition: @Sendable () async -> Bool
) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await condition() { return }
        await Task.yield()
    }
}
