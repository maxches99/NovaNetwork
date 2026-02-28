import Foundation

public enum WebSocketOutboundQueueOverflowPolicy: Sendable, Equatable {
    case dropOldest
    case dropNewest
    case failFast
}

public struct WebSocketOutboundQueuePolicy: Sendable, Equatable {
    public let maxQueuedMessages: Int
    public let overflowPolicy: WebSocketOutboundQueueOverflowPolicy

    public init(
        maxQueuedMessages: Int = 0,
        overflowPolicy: WebSocketOutboundQueueOverflowPolicy = .failFast
    ) {
        self.maxQueuedMessages = max(0, maxQueuedMessages)
        self.overflowPolicy = overflowPolicy
    }

    public static let disabled = WebSocketOutboundQueuePolicy()
}

public struct WebSocketReconnectPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelayNanoseconds: UInt64
    public let maxDelayNanoseconds: UInt64
    public let jitterRange: ClosedRange<Double>?

    public init(
        maxAttempts: Int = 3,
        baseDelayNanoseconds: UInt64 = 300_000_000,
        maxDelayNanoseconds: UInt64 = 3_000_000_000,
        jitterRange: ClosedRange<Double>? = 0.8...1.2
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maxDelayNanoseconds = max(baseDelayNanoseconds, maxDelayNanoseconds)
        self.jitterRange = jitterRange
    }

    public static let disabled = WebSocketReconnectPolicy(maxAttempts: 0, jitterRange: nil)
}

public struct WebSocketHeartbeatPolicy: Sendable, Equatable {
    public let intervalNanoseconds: UInt64
    public let timeoutNanoseconds: UInt64

    public init(
        intervalNanoseconds: UInt64 = 20_000_000_000,
        timeoutNanoseconds: UInt64 = 8_000_000_000
    ) {
        self.intervalNanoseconds = intervalNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public static let disabled = WebSocketHeartbeatPolicy(
        intervalNanoseconds: 0,
        timeoutNanoseconds: 0
    )
}

public struct WebSocketConfiguration: Sendable, Equatable {
    public let url: URL
    public let headers: [String: String]
    public let reconnectPolicy: WebSocketReconnectPolicy
    public let heartbeatPolicy: WebSocketHeartbeatPolicy
    public let outboundQueuePolicy: WebSocketOutboundQueuePolicy

    public init(
        url: URL,
        headers: [String: String] = [:],
        reconnectPolicy: WebSocketReconnectPolicy = .init(),
        heartbeatPolicy: WebSocketHeartbeatPolicy = .init(),
        outboundQueuePolicy: WebSocketOutboundQueuePolicy = .disabled
    ) {
        self.url = url
        self.headers = headers
        self.reconnectPolicy = reconnectPolicy
        self.heartbeatPolicy = heartbeatPolicy
        self.outboundQueuePolicy = outboundQueuePolicy
    }
}
