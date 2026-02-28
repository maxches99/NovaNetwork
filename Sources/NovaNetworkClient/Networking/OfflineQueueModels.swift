import Foundation

public enum OfflineReplayConflictPolicy: String, Sendable, Equatable, Codable {
    case retry
    case drop
    case manualReview
}

public enum OfflineQueueTerminalStatus: String, Sendable, Equatable, Codable {
    case succeeded
    case dedupeSuppressed
    case droppedConflict
    case manualReview
    case failed
}

public struct OfflineReplayMetadata: Sendable, Equatable, Codable {
    public let replayIdentity: String
    public let maxReplayAttempts: Int
    public let dedupeWindowSeconds: TimeInterval
    public let conflictPolicy: OfflineReplayConflictPolicy

    public init(
        replayIdentity: String,
        maxReplayAttempts: Int = 5,
        dedupeWindowSeconds: TimeInterval = 24 * 60 * 60,
        conflictPolicy: OfflineReplayConflictPolicy = .retry
    ) {
        self.replayIdentity = replayIdentity
        self.maxReplayAttempts = max(1, maxReplayAttempts)
        self.dedupeWindowSeconds = max(0, dedupeWindowSeconds)
        self.conflictPolicy = conflictPolicy
    }
}

public struct QueuedWriteReceipt: Sendable, Equatable {
    public let queueID: String
    public let requestKey: String
    public let position: Int
    public let enqueuedAt: Date

    public init(queueID: String, requestKey: String, position: Int, enqueuedAt: Date = Date()) {
        self.queueID = queueID
        self.requestKey = requestKey
        self.position = max(1, position)
        self.enqueuedAt = enqueuedAt
    }
}

public enum QueuedWriteResult: Sendable, Equatable {
    case completed(Data)
    case queued(QueuedWriteReceipt)
}

public enum OfflineQueueEntryState: Sendable, Equatable {
    case queued
    case replayScheduled
    case replaying
    case retryWaiting
    case deadLetter
    case manualReview
}

public struct OfflineQueueSnapshotItem: Sendable, Equatable {
    public let receipt: QueuedWriteReceipt
    public let method: URLMethod
    public let url: URL
    public let attempt: Int
    public let state: OfflineQueueEntryState

    public init(
        receipt: QueuedWriteReceipt,
        method: URLMethod,
        url: URL,
        attempt: Int,
        state: OfflineQueueEntryState
    ) {
        self.receipt = receipt
        self.method = method
        self.url = url
        self.attempt = max(0, attempt)
        self.state = state
    }
}
