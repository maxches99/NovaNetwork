import Foundation

public enum OfflineQueueEvent: Sendable, Equatable {
    case enqueued(receipt: QueuedWriteReceipt)
    case replayStarted(queueID: String, requestKey: String, attempt: Int)
    case replaySuppressed(queueID: String, requestKey: String, replayIdentity: String, reason: String)
    case replaySucceeded(queueID: String, requestKey: String, statusCode: Int)
    case manualReviewRequired(queueID: String, requestKey: String, attempt: Int, reason: String)
    case manualReviewRequeued(queueID: String, requestKey: String, reason: String?)
    case replayFailed(queueID: String, requestKey: String, attempt: Int, reason: String, willRetry: Bool)
    case deadLettered(queueID: String, requestKey: String, reason: String)
    case dropped(queueID: String, requestKey: String, reason: String)
    case recoveryLossDetected(scannedRecords: Int, skippedRecords: Int, reason: String)
}
