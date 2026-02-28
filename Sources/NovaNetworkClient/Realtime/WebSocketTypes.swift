import Foundation

public enum WebSocketConnectionState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case unhealthy(WebSocketError)
    case reconnecting(attempt: Int, nextDelayMilliseconds: Double)
    case failed(WebSocketError)
}

public enum WebSocketConnectionHealth: Sendable, Equatable {
    case disconnected
    case healthy
    case unhealthy(reason: String)
}

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

public struct WebSocketSendOptions: Sendable, Equatable {
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

public protocol WebSocketClientProtocol: Actor, Sendable {
    func connectionStates() -> AsyncStream<WebSocketConnectionState>
    func connectionHealth() -> WebSocketConnectionHealth
    func messages() -> AsyncThrowingStream<WebSocketMessage, Error>
    func connect() async throws
    func forceReconnect(reason: String?) async
    func send(_ message: WebSocketMessage, options: WebSocketSendOptions) async throws
    func send(_ message: WebSocketMessage) async throws
    func disconnect(reason: String?) async
}
