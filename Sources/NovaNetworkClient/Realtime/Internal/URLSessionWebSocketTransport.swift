import Foundation

protocol WebSocketTransport: Sendable {
    func connect(url: URL, headers: [String: String]) async throws
    func receive() async throws -> WebSocketMessage
    func send(_ message: WebSocketMessage) async throws
    func ping() async throws
    func disconnect(reason: String?) async
}

protocol URLSessionWebSocketTasking: Sendable {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: URLSessionWebSocketTasking {}

actor URLSessionWebSocketTransport: WebSocketTransport {
    private let taskFactory: @Sendable (URLRequest) -> any URLSessionWebSocketTasking
    private var task: (any URLSessionWebSocketTasking)?

    init(session: URLSession = .shared) {
        self.taskFactory = { request in
            session.webSocketTask(with: request)
        }
    }

    init(taskFactory: @escaping @Sendable (URLRequest) -> any URLSessionWebSocketTasking) {
        self.taskFactory = taskFactory
    }

    func connect(url: URL, headers: [String: String]) async throws {
        await disconnect(reason: nil)

        var request = URLRequest(url: url)
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        let task = taskFactory(request)
        self.task = task
        task.resume()
    }

    func receive() async throws -> WebSocketMessage {
        guard let task else {
            throw WebSocketError.disconnected
        }

        let message = try await task.receive()
        switch message {
        case .string(let value):
            return .text(value)
        case .data(let data):
            return .binary(data)
        @unknown default:
            throw WebSocketError.protocolViolation(description: "Unknown WebSocket frame")
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        guard let task else {
            throw WebSocketError.disconnected
        }

        switch message {
        case .text(let value):
            try await task.send(.string(value))
        case .binary(let data):
            try await task.send(.data(data))
        }
    }

    func ping() async throws {
        guard let task else {
            throw WebSocketError.disconnected
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing(pongReceiveHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func disconnect(reason: String?) async {
        let payload = reason.map { Data($0.utf8) }
        task?.cancel(with: .normalClosure, reason: payload)
        task = nil
    }
}
