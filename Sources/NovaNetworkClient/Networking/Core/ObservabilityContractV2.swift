import NovaNetworkCore
import Foundation

/// Version constants for the NovaNetworkClient observability contract.
public enum TelemetryContractVersion {
    /// Monotonic version for individual telemetry event/metric payload schema.
    public static let eventVersion: Int = 2

    /// Version of the cross-event contract package.
    public static let contractVersion: String = "2.0"
}

/// Scalar attribute value that can be exported to telemetry backends.
public enum TelemetryAttributeValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }
        if let int = try? container.decode(Int.self) {
            self = .int(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            self = .double(double)
            return
        }
        self = .string(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        }
    }
}

/// Event payload schema for Observability Contract v2.
public struct TelemetryEventPayload: Sendable, Equatable, Codable {
    public let eventName: String
    public let eventVersion: Int
    public let contractVersion: String
    public let attributes: [String: TelemetryAttributeValue]

    public init(
        eventName: String,
        eventVersion: Int = TelemetryContractVersion.eventVersion,
        contractVersion: String = TelemetryContractVersion.contractVersion,
        attributes: [String: TelemetryAttributeValue]
    ) {
        self.eventName = eventName
        self.eventVersion = eventVersion
        self.contractVersion = contractVersion
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case eventName = "event_name"
        case eventVersion = "event_version"
        case contractVersion = "contract_version"
        case attributes
    }
}

/// Metric kind emitted by the OpenTelemetry adapter contract.
public enum TelemetryMetricKind: String, Sendable, Codable {
    case counter
    case gauge
}

/// Metric payload schema for Observability Contract v2.
public struct TelemetryMetricPayload: Sendable, Equatable, Codable {
    public let metricName: String
    public let kind: TelemetryMetricKind
    public let value: Double
    public let eventVersion: Int
    public let contractVersion: String
    public let attributes: [String: TelemetryAttributeValue]

    public init(
        metricName: String,
        kind: TelemetryMetricKind,
        value: Double,
        eventVersion: Int = TelemetryContractVersion.eventVersion,
        contractVersion: String = TelemetryContractVersion.contractVersion,
        attributes: [String: TelemetryAttributeValue] = [:]
    ) {
        self.metricName = metricName
        self.kind = kind
        self.value = value
        self.eventVersion = eventVersion
        self.contractVersion = contractVersion
        self.attributes = attributes
    }

    enum CodingKeys: String, CodingKey {
        case metricName = "metric_name"
        case kind
        case value
        case eventVersion = "event_version"
        case contractVersion = "contract_version"
        case attributes
    }
}

/// Stable metric names for SDK SLO instrumentation.
public enum TelemetrySLOMetricName {
    /// Counter incremented once for each terminal retry exhaustion.
    public static let retryExhausted = "sdk.retry.exhausted"

    /// Counter incremented when websocket reconnect recovers successfully.
    public static let reconnectSuccess = "sdk.reconnect.success"

    /// Counter incremented when an offline queue replay succeeds.
    public static let replaySuccess = "sdk.replay.success"

    /// Gauge in milliseconds for p95 offline queue age.
    public static let queueAgeP95Milliseconds = "sdk.queue.age.p95.ms"
}
