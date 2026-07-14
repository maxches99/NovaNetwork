import NovaNetworkCore
import Foundation

public struct WebSocketQueuedMessage: Sendable, Codable, Equatable {
    public let message: WebSocketMessage
    public let options: WebSocketSendOptions
    public let resolvedMessageID: String?
    public let enqueuedAt: Date

    public init(
        message: WebSocketMessage,
        options: WebSocketSendOptions,
        resolvedMessageID: String?,
        enqueuedAt: Date
    ) {
        self.message = message
        self.options = options
        self.resolvedMessageID = resolvedMessageID
        self.enqueuedAt = enqueuedAt
    }
}

public enum WebSocketOutboundQueueStoreError: Error, Sendable, Equatable {
    case readFailed
    case decodeFailed
    case partiallyCorrupted(recovered: [WebSocketQueuedMessage], droppedCount: Int)
    case schemaMismatch(expected: Int, actual: Int)
    case writeFailed
    case encodeFailed
}

public protocol WebSocketOutboundQueueStore: Sendable {
    func loadQueuedMessages() async throws -> [WebSocketQueuedMessage]
    func persistQueuedMessages(_ messages: [WebSocketQueuedMessage]) async throws
}

public actor DiskWebSocketOutboundQueueStore: WebSocketOutboundQueueStore {
    private let fileURL: URL
    private let schemaVersion: Int
    private let fileManager: FileManager

    public init(
        fileURL: URL,
        schemaVersion: Int = 1,
        fileManager: FileManager = .default
    ) {
        self.fileURL = fileURL
        self.schemaVersion = max(1, schemaVersion)
        self.fileManager = fileManager
    }

    public func loadQueuedMessages() async throws -> [WebSocketQueuedMessage] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            throw WebSocketOutboundQueueStoreError.readFailed
        }
        let envelope = try decodeEnvelopeLossy(data: data)
        guard envelope.schemaVersion == schemaVersion else {
            throw WebSocketOutboundQueueStoreError.schemaMismatch(
                expected: schemaVersion,
                actual: envelope.schemaVersion
            )
        }
        if envelope.droppedCount > 0 {
            throw WebSocketOutboundQueueStoreError.partiallyCorrupted(
                recovered: envelope.messages,
                droppedCount: envelope.droppedCount
            )
        }
        return envelope.messages
    }

    public func persistQueuedMessages(_ messages: [WebSocketQueuedMessage]) async throws {
        if messages.isEmpty {
            try? fileManager.removeItem(at: fileURL)
            return
        }

        let parent = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw WebSocketOutboundQueueStoreError.writeFailed
        }
        let envelope = PersistedWebSocketOutboundQueueEnvelope(
            schemaVersion: schemaVersion,
            messages: messages
        )
        guard let data = try? JSONEncoder().encode(envelope) else {
            throw WebSocketOutboundQueueStoreError.encodeFailed
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw WebSocketOutboundQueueStoreError.writeFailed
        }
    }
}

private struct PersistedWebSocketOutboundQueueEnvelope: Codable, Equatable {
    let schemaVersion: Int
    let messages: [WebSocketQueuedMessage]
}

private struct LossyPersistedWebSocketOutboundQueueEnvelope: Equatable {
    let schemaVersion: Int
    let messages: [WebSocketQueuedMessage]
    let droppedCount: Int
}

private extension DiskWebSocketOutboundQueueStore {
    func decodeEnvelopeLossy(data: Data) throws -> LossyPersistedWebSocketOutboundQueueEnvelope {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schemaVersion = root["schemaVersion"] as? Int,
              let rawMessages = root["messages"] as? [Any] else {
            throw WebSocketOutboundQueueStoreError.decodeFailed
        }

        let decoder = JSONDecoder()
        var messages: [WebSocketQueuedMessage] = []
        var droppedCount = 0
        messages.reserveCapacity(rawMessages.count)

        for rawMessage in rawMessages {
            guard JSONSerialization.isValidJSONObject(rawMessage),
                  let messageData = try? JSONSerialization.data(withJSONObject: rawMessage),
                  let message = try? decoder.decode(WebSocketQueuedMessage.self, from: messageData) else {
                droppedCount += 1
                continue
            }
            messages.append(message)
        }

        return LossyPersistedWebSocketOutboundQueueEnvelope(
            schemaVersion: schemaVersion,
            messages: messages,
            droppedCount: droppedCount
        )
    }
}
