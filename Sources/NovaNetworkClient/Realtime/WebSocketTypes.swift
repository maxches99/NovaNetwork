import Foundation

public enum WebSocketConnectionState: Sendable, Equatable {
    case disconnected
    case connecting(attempt: Int)
    case connected(since: Date)
    case reconnecting(attempt: Int, nextDelayMilliseconds: Double)
    case failed(WebSocketError)
}

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

public enum WebSocketError: Error, Sendable, Equatable {
    case disconnected
    case cancelled
    case timeout
    case auth(description: String)
    case protocolViolation(description: String)
    case transport(description: String)
    case reconnectExhausted
}

public protocol WebSocketClientProtocol: Actor, Sendable {
    func connectionStates() -> AsyncStream<WebSocketConnectionState>
    func messages() -> AsyncThrowingStream<WebSocketMessage, Error>
    func connect() async throws
    func send(_ message: WebSocketMessage) async throws
    func disconnect(reason: String?) async
}
