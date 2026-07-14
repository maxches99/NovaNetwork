import NovaNetworkCore
import Foundation

public enum WebSocketConnectionState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case unhealthy(WebSocketError)
    case reconnectingWaitingForConnectivity(attempt: Int)
    case reconnecting(attempt: Int, nextDelayMilliseconds: Double)
    case failed(WebSocketError)
}

public enum WebSocketConnectionHealth: Sendable, Equatable {
    case disconnected
    case healthy
    case unhealthy(reason: String)
}

public enum WebSocketRecoverability: String, Sendable, Equatable, Codable {
    case recoverable
    case nonRecoverable
    case manualInterventionRequired
}

public enum WebSocketReconnectPhase: String, Sendable, Equatable, Codable {
    case disconnected
    case connecting
    case connected
    case waitingForConnectivity
    case backoff
    case recovering
    case failed
}

public enum WebSocketQueuePressureLevel: String, Sendable, Equatable, Codable {
    case nominal
    case elevated
    case high
    case critical
}

public enum WebSocketAckTimeoutClass: String, Sendable, Equatable, Codable {
    case fast
    case slow
    case stalled
}

public enum WebSocketMessage: Sendable, Equatable, Codable {
    case text(String)
    case binary(Data)
}

public struct WebSocketSendOptions: Sendable, Equatable, Codable {
    public let requiresAck: Bool
    public let messageID: String?
    public let ackTimeoutNanoseconds: UInt64

    public init(
        requiresAck: Bool = false,
        messageID: String? = nil,
        ackTimeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.requiresAck = requiresAck
        self.messageID = messageID
        self.ackTimeoutNanoseconds = ackTimeoutNanoseconds
    }
}

public struct WebSocketAckMatcher: Sendable {
    public let match: @Sendable (WebSocketMessage) -> String?

    public init(match: @escaping @Sendable (WebSocketMessage) -> String?) {
        self.match = match
    }

    public static let `default` = WebSocketAckMatcher { message in
        guard case .text(let value) = message else { return nil }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = object["type"] as? String,
           type == "ack",
           let messageID = object["messageId"] as? String {
            return messageID
        }

        let prefix = "ack:"
        if value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return nil
    }
}

public struct WebSocketAuthRefreshProvider: Sendable {
    public let refreshHeaders: @Sendable () async throws -> [String: String]

    public init(refreshHeaders: @escaping @Sendable () async throws -> [String: String]) {
        self.refreshHeaders = refreshHeaders
    }
}

public enum WebSocketError: Error, Sendable, Equatable {
    case disconnected
    case cancelled
    case timeout
    case ackTimeout(messageID: String)
    case auth(description: String)
    case protocolViolation(description: String)
    case transport(description: String)
    case reconnectExhausted
}

public struct WebSocketAckPendingAgeBuckets: Sendable, Equatable, Codable {
    public let underOneSecond: Int
    public let oneToFiveSeconds: Int
    public let overFiveSeconds: Int

    public init(
        underOneSecond: Int = 0,
        oneToFiveSeconds: Int = 0,
        overFiveSeconds: Int = 0
    ) {
        self.underOneSecond = max(0, underOneSecond)
        self.oneToFiveSeconds = max(0, oneToFiveSeconds)
        self.overFiveSeconds = max(0, overFiveSeconds)
    }
}

public struct WebSocketDiagnostics: Sendable, Equatable {
    public let connectionID: String
    public let state: WebSocketConnectionState
    public let health: WebSocketConnectionHealth
    public let reconnectAttempt: Int
    public let queuedOutboundMessages: Int
    public let queueCapacity: Int
    public let queuePressureLevel: WebSocketQueuePressureLevel
    public let pendingAckCount: Int
    public let ackPendingAgeBuckets: WebSocketAckPendingAgeBuckets
    public let trackedAckMessageIDs: Int
    public let reconnectPhase: WebSocketReconnectPhase
    public let lastTransitionReason: String?
    public let recoverability: WebSocketRecoverability?
    public let lastError: WebSocketError?

    public init(
        connectionID: String,
        state: WebSocketConnectionState,
        health: WebSocketConnectionHealth,
        reconnectAttempt: Int,
        queuedOutboundMessages: Int,
        queueCapacity: Int = 0,
        queuePressureLevel: WebSocketQueuePressureLevel = .nominal,
        pendingAckCount: Int,
        ackPendingAgeBuckets: WebSocketAckPendingAgeBuckets = .init(),
        trackedAckMessageIDs: Int,
        reconnectPhase: WebSocketReconnectPhase = .disconnected,
        lastTransitionReason: String? = nil,
        recoverability: WebSocketRecoverability? = nil,
        lastError: WebSocketError?
    ) {
        self.connectionID = connectionID
        self.state = state
        self.health = health
        self.reconnectAttempt = reconnectAttempt
        self.queuedOutboundMessages = queuedOutboundMessages
        self.queueCapacity = max(0, queueCapacity)
        self.queuePressureLevel = queuePressureLevel
        self.pendingAckCount = pendingAckCount
        self.ackPendingAgeBuckets = ackPendingAgeBuckets
        self.trackedAckMessageIDs = trackedAckMessageIDs
        self.reconnectPhase = reconnectPhase
        self.lastTransitionReason = lastTransitionReason
        self.recoverability = recoverability
        self.lastError = lastError
    }
}

public protocol WebSocketClientProtocol: Actor, Sendable {
    func connectionStates() -> AsyncStream<WebSocketConnectionState>
    func connectionHealth() -> WebSocketConnectionHealth
    func messages() -> AsyncThrowingStream<WebSocketMessage, Error>
    func webSocketDiagnostics() -> WebSocketDiagnostics
    func registerSubscription(id: String, message: WebSocketMessage, options: WebSocketSendOptions) async
    func unregisterSubscription(id: String) async
    func clearSubscriptions() async
    func connect() async throws
    func forceReconnect(reason: String?) async
    func send(_ message: WebSocketMessage, options: WebSocketSendOptions) async throws
    func send(_ message: WebSocketMessage) async throws
    func disconnect(reason: String?) async
}
