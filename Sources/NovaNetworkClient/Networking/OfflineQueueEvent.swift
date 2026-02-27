import Foundation

public enum OfflineQueueEvent: Sendable, Equatable {
    case enqueued(receipt: QueuedWriteReceipt)
    case replayStarted(queueID: String, requestKey: String, attempt: Int)
    case replaySucceeded(queueID: String, requestKey: String, statusCode: Int)
    case replayFailed(queueID: String, requestKey: String, attempt: Int, reason: String, willRetry: Bool)
    case deadLettered(queueID: String, requestKey: String, reason: String)
    case dropped(queueID: String, requestKey: String, reason: String)
}
