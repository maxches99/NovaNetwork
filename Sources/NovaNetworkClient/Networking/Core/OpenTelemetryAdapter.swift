import NovaNetworkCore
import Foundation

/// Export surface for bridging NovaNetworkClient telemetry to OpenTelemetry SDKs.
///
/// The core package does not depend on OpenTelemetry directly. Implement this
/// protocol in an app target that imports OpenTelemetry and forward payloads
/// to the concrete meter/tracer implementation.
public protocol OpenTelemetryExporting: Sendable {
    func export(event: TelemetryEventPayload)
    func export(metric: TelemetryMetricPayload)
}

/// Adapter that maps `NetworkTelemetryHooks` callbacks to versioned
/// observability payloads compatible with OpenTelemetry integrations.
public struct OpenTelemetryAdapter: Sendable {
    public let eventVersion: Int
    public let contractVersion: String

    public init(
        eventVersion: Int = TelemetryContractVersion.eventVersion,
        contractVersion: String = TelemetryContractVersion.contractVersion
    ) {
        self.eventVersion = eventVersion
        self.contractVersion = contractVersion
    }

    /// Builds telemetry hooks that emit Contract v2 payloads and SLO metrics.
    public func makeHooks(exporter: any OpenTelemetryExporting) -> NetworkTelemetryHooks {
        NetworkTelemetryHooks(
            onRetryExhausted: { context in
                exporter.export(event: retryExhaustedPayload(context: context))
                exporter.export(metric: retryExhaustedMetric(context: context))
            },
            onOfflineQueueEvent: { context in
                exporter.export(event: offlineQueuePayload(context: context))
                if context.type == .replaySucceeded {
                    exporter.export(metric: replaySuccessMetric(context: context))
                }
            },
            onWebSocketEvent: { context in
                exporter.export(event: webSocketPayload(context: context))
                if context.type == .reconnectSuccess {
                    exporter.export(metric: reconnectSuccessMetric(context: context))
                }
            }
        )
    }

    /// Emits pipeline SLO metric payloads (currently queue age p95).
    public func emitPipelineMetrics(
        _ metrics: OfflineQueuePipelineMetrics,
        exporter: any OpenTelemetryExporting,
        attributes: [String: TelemetryAttributeValue] = [:]
    ) {
        var metricAttributes = attributes
        metricAttributes["queue_depth"] = .int(metrics.queueDepth)
        exporter.export(
            metric: TelemetryMetricPayload(
                metricName: TelemetrySLOMetricName.queueAgeP95Milliseconds,
                kind: .gauge,
                value: metrics.ageDistribution.p95Seconds * 1_000,
                eventVersion: eventVersion,
                contractVersion: contractVersion,
                attributes: metricAttributes
            )
        )
    }

    func retryExhaustedPayload(context: TelemetryRetryExhaustedContext) -> TelemetryEventPayload {
        TelemetryEventPayload(
            eventName: "network.retry_exhausted",
            eventVersion: eventVersion,
            contractVersion: contractVersion,
            attributes: [
                "key": .string(context.key),
                "attempts": .int(context.attempts),
                "reason": .string(context.reason),
                "coalescing_mode": .string(context.coalescingMode.rawValue),
                "method": .string(context.request.method.rawValue),
                "url": .string(context.request.url.absoluteString)
            ]
        )
    }

    func retryExhaustedMetric(context: TelemetryRetryExhaustedContext) -> TelemetryMetricPayload {
        TelemetryMetricPayload(
            metricName: TelemetrySLOMetricName.retryExhausted,
            kind: .counter,
            value: 1,
            eventVersion: eventVersion,
            contractVersion: contractVersion,
            attributes: [
                "reason": .string(context.reason),
                "coalescing_mode": .string(context.coalescingMode.rawValue)
            ]
        )
    }

    func replaySuccessMetric(context: TelemetryOfflineQueueContext) -> TelemetryMetricPayload {
        var attributes: [String: TelemetryAttributeValue] = [
            "queue_id": .string(context.queueID),
            "request_key": .string(context.requestKey)
        ]
        if let priority = context.priority?.rawValue {
            attributes["priority"] = .string(priority)
        }
        return TelemetryMetricPayload(
            metricName: TelemetrySLOMetricName.replaySuccess,
            kind: .counter,
            value: 1,
            eventVersion: eventVersion,
            contractVersion: contractVersion,
            attributes: attributes
        )
    }

    func reconnectSuccessMetric(context: TelemetryWebSocketContext) -> TelemetryMetricPayload {
        var attributes: [String: TelemetryAttributeValue] = [
            "connection_id": .string(context.connectionID)
        ]
        if let attempt = context.attempt {
            attributes["attempt"] = .int(attempt)
        }
        return TelemetryMetricPayload(
            metricName: TelemetrySLOMetricName.reconnectSuccess,
            kind: .counter,
            value: 1,
            eventVersion: eventVersion,
            contractVersion: contractVersion,
            attributes: attributes
        )
    }

    func offlineQueuePayload(context: TelemetryOfflineQueueContext) -> TelemetryEventPayload {
        var attributes: [String: TelemetryAttributeValue] = [
            "type": .string(context.type.rawValue),
            "queue_id": .string(context.queueID),
            "request_key": .string(context.requestKey)
        ]
        if let attempt = context.attempt {
            attributes["attempt"] = .int(attempt)
        }
        if let ageMilliseconds = context.ageMilliseconds {
            attributes["age_milliseconds"] = .double(ageMilliseconds)
        }
        if let reason = context.reason {
            attributes["reason"] = .string(reason)
        }
        if let willRetry = context.willRetry {
            attributes["will_retry"] = .bool(willRetry)
        }
        if let resultType = context.resultType {
            attributes["result_type"] = .string(resultType)
        }
        if let priority = context.priority?.rawValue {
            attributes["priority"] = .string(priority)
        }
        if let skippedRecords = context.skippedRecords {
            attributes["skipped_records"] = .int(skippedRecords)
        }
        return TelemetryEventPayload(
            eventName: "offline_queue.\(context.type.rawValue)",
            eventVersion: eventVersion,
            contractVersion: contractVersion,
            attributes: attributes
        )
    }

    func webSocketPayload(context: TelemetryWebSocketContext) -> TelemetryEventPayload {
        var attributes: [String: TelemetryAttributeValue] = [
            "type": .string(context.type.rawValue),
            "connection_id": .string(context.connectionID)
        ]
        if let attempt = context.attempt {
            attributes["attempt"] = .int(attempt)
        }
        if let reason = context.reason {
            attributes["reason"] = .string(reason)
        }
        if let error = context.error {
            attributes["error"] = .string(error)
        }
        if let messageKind = context.messageKind {
            attributes["message_kind"] = .string(messageKind)
        }
        if let queueSize = context.queueSize {
            attributes["queue_size"] = .int(queueSize)
        }
        if let queuePolicy = context.queuePolicy {
            attributes["queue_policy"] = .string(queuePolicy)
        }
        if let messageID = context.messageID {
            attributes["message_id"] = .string(messageID)
        }
        if let total = context.subscriptionRestoreTotalCount {
            attributes["subscription_restore_total_count"] = .int(total)
        }
        if let failed = context.subscriptionRestoreFailedCount {
            attributes["subscription_restore_failed_count"] = .int(failed)
        }
        if let correlationID = context.correlationID {
            attributes["correlation_id"] = .string(correlationID)
        }
        if let ackTimeoutClass = context.ackTimeoutClass {
            attributes["ack_timeout_class"] = .string(ackTimeoutClass)
        }
        if let ackAttempt = context.ackAttempt {
            attributes["ack_attempt"] = .int(ackAttempt)
        }
        if let recoverability = context.recoverability {
            attributes["recoverability"] = .string(recoverability)
        }
        if let reconnectPhase = context.reconnectPhase {
            attributes["reconnect_phase"] = .string(reconnectPhase)
        }
        if let lastTransitionReason = context.lastTransitionReason {
            attributes["last_transition_reason"] = .string(lastTransitionReason)
        }
        return TelemetryEventPayload(
            eventName: "websocket.\(context.type.rawValue)",
            eventVersion: eventVersion,
            contractVersion: contractVersion,
            attributes: attributes
        )
    }
}
