import Foundation
import Testing
@testable import NovaNetworkClient

private final class OpenTelemetryExporterSpy: OpenTelemetryExporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [TelemetryEventPayload] = []
    private(set) var metrics: [TelemetryMetricPayload] = []

    func export(event: TelemetryEventPayload) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func export(metric: TelemetryMetricPayload) {
        lock.lock()
        metrics.append(metric)
        lock.unlock()
    }

    func eventsSnapshot() -> [TelemetryEventPayload] {
        lock.lock()
        let snapshot = events
        lock.unlock()
        return snapshot
    }

    func metricsSnapshot() -> [TelemetryMetricPayload] {
        lock.lock()
        let snapshot = metrics
        lock.unlock()
        return snapshot
    }
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

extension NetworkingCoverageTests {
    @Test
    func observabilityContractV2GoldenRetryExhaustedPayloadSchema() throws {
        let adapter = OpenTelemetryAdapter()
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry")!)
        let payload = adapter.retryExhaustedPayload(
            context: .init(
                key: "fingerprint-1",
                attempts: 3,
                reason: "http_status_503",
                coalescingMode: .default,
                request: request
            )
        )

        let json = try encodedJSON(payload)
        let expected = #"{"attributes":{"attempts":3,"coalescing_mode":"default","key":"fingerprint-1","method":"GET","reason":"http_status_503","url":"https:\/\/example.com\/retry"},"contract_version":"2.0","event_name":"network.retry_exhausted","event_version":2}"#
        #expect(json == expected)
    }

    @Test
    func observabilityContractV2GoldenReconnectSuccessPayloadSchema() throws {
        let adapter = OpenTelemetryAdapter()
        let payload = adapter.webSocketPayload(
            context: .init(
                type: .reconnectSuccess,
                connectionID: "conn-42",
                attempt: 2,
                reconnectPhase: "connected",
                lastTransitionReason: "reconnect_success"
            )
        )

        let json = try encodedJSON(payload)
        let expected = #"{"attributes":{"attempt":2,"connection_id":"conn-42","last_transition_reason":"reconnect_success","reconnect_phase":"connected","type":"reconnect_success"},"contract_version":"2.0","event_name":"websocket.reconnect_success","event_version":2}"#
        #expect(json == expected)
    }

    @Test
    func observabilityContractV2GoldenReplaySuccessPayloadSchema() throws {
        let adapter = OpenTelemetryAdapter()
        let payload = adapter.offlineQueuePayload(
            context: .init(
                type: .replaySucceeded,
                queueID: "q-1",
                requestKey: "k-1",
                attempt: 1,
                ageMilliseconds: 250,
                resultType: "executed",
                priority: .critical
            )
        )

        let json = try encodedJSON(payload)
        let expected = #"{"attributes":{"age_milliseconds":250,"attempt":1,"priority":"critical","queue_id":"q-1","request_key":"k-1","result_type":"executed","type":"replaySucceeded"},"contract_version":"2.0","event_name":"offline_queue.replaySucceeded","event_version":2}"#
        #expect(json == expected)
    }

    @Test
    func observabilityContractV2GoldenQueueAgeP95MetricSchema() throws {
        let payload = TelemetryMetricPayload(
            metricName: TelemetrySLOMetricName.queueAgeP95Milliseconds,
            kind: .gauge,
            value: 1450,
            attributes: [
                "queue_depth": .int(7),
                "scope": .string("global")
            ]
        )

        let json = try encodedJSON(payload)
        let expected = #"{"attributes":{"queue_depth":7,"scope":"global"},"contract_version":"2.0","event_version":2,"kind":"gauge","metric_name":"sdk.queue.age.p95.ms","value":1450}"#
        #expect(json == expected)
    }

    @Test
    func openTelemetryAdapterEmitsSLOMetricsFromHooksAndPipeline() {
        let adapter = OpenTelemetryAdapter()
        let exporter = OpenTelemetryExporterSpy()
        let hooks = adapter.makeHooks(exporter: exporter)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/slo")!)

        hooks.onRetryExhausted?(
            .init(
                key: "k",
                attempts: 2,
                reason: "http_status_503",
                coalescingMode: .default,
                request: request
            )
        )
        hooks.onWebSocketEvent?(
            .init(
                type: .reconnectSuccess,
                connectionID: "conn",
                attempt: 1
            )
        )
        hooks.onOfflineQueueEvent?(
            .init(
                type: .replaySucceeded,
                queueID: "q",
                requestKey: "rk",
                priority: .normal
            )
        )

        let pipeline = OfflineQueuePipelineMetrics(
            queueDepth: 4,
            ageDistribution: .init(p50Seconds: 0.1, p90Seconds: 0.8, p95Seconds: 1.3, maxSeconds: 2),
            replayThroughput: .init(replayedCount: 3, windowSeconds: 10, replaysPerSecond: 0.3),
            terminalOutcomes: [.succeeded: 3]
        )
        adapter.emitPipelineMetrics(pipeline, exporter: exporter, attributes: ["scope": .string("global")])

        let metrics = exporter.metricsSnapshot()
        #expect(metrics.contains(where: { $0.metricName == TelemetrySLOMetricName.retryExhausted && $0.value == 1 }))
        #expect(metrics.contains(where: { $0.metricName == TelemetrySLOMetricName.reconnectSuccess && $0.value == 1 }))
        #expect(metrics.contains(where: { $0.metricName == TelemetrySLOMetricName.replaySuccess && $0.value == 1 }))
        #expect(metrics.contains(where: { $0.metricName == TelemetrySLOMetricName.queueAgeP95Milliseconds && $0.value == 1300 }))

        let events = exporter.eventsSnapshot()
        #expect(events.contains(where: { $0.eventName == "network.retry_exhausted" }))
        #expect(events.contains(where: { $0.eventName == "websocket.reconnect_success" }))
        #expect(events.contains(where: { $0.eventName == "offline_queue.replaySucceeded" }))
    }
}
