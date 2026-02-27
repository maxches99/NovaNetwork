import Foundation

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
