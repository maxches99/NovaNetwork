import Foundation

actor NetworkClientEventHub {
    private var continuations: [UUID: AsyncStream<NetworkClientEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<NetworkClientEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ event: NetworkClientEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}

actor OfflineQueueEventHub {
    private var continuations: [UUID: AsyncStream<OfflineQueueEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<OfflineQueueEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ event: OfflineQueueEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations[id] = nil
    }
}
