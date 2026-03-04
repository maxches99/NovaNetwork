import Foundation

public struct OfflineStoreRecoveryReport: Sendable, Equatable {
    public let scannedRecords: Int
    public let recoveredRecords: Int
    public let skippedCorruptedRecords: Int
    public let skippedIncompatibleRecords: Int

    public init(
        scannedRecords: Int,
        recoveredRecords: Int,
        skippedCorruptedRecords: Int,
        skippedIncompatibleRecords: Int
    ) {
        self.scannedRecords = max(0, scannedRecords)
        self.recoveredRecords = max(0, recoveredRecords)
        self.skippedCorruptedRecords = max(0, skippedCorruptedRecords)
        self.skippedIncompatibleRecords = max(0, skippedIncompatibleRecords)
    }

    public var skippedTotal: Int {
        skippedCorruptedRecords + skippedIncompatibleRecords
    }
}

public enum OfflineWriteStoreOverflowPolicy: Sendable, Equatable {
    case evictOldest
    case rejectNew
}

public enum OfflineWriteStoreError: Error, Equatable {
    case queueCapacityExceeded(limit: Int)
    case encryptionKeyUnavailable
    case unsupportedEncryptionVersion(Int)
    case encryptionFailure
}

public struct OfflineWriteStoreEntry: Sendable {
    public let receipt: QueuedWriteReceipt
    public let request: APIRequest
    public let attempt: Int
    public let nextRetryAt: Date?
    public let lastFailureReason: String?
    public let state: OfflineQueueEntryState
    public let updatedAt: Date
    public let replayMetadata: OfflineReplayMetadata
    public let lastTerminalStatus: OfflineQueueTerminalStatus?
    public let lastTerminalAt: Date?

    public init(
        receipt: QueuedWriteReceipt,
        request: APIRequest,
        attempt: Int,
        nextRetryAt: Date?,
        lastFailureReason: String?,
        state: OfflineQueueEntryState,
        updatedAt: Date,
        replayMetadata: OfflineReplayMetadata,
        lastTerminalStatus: OfflineQueueTerminalStatus? = nil,
        lastTerminalAt: Date? = nil
    ) {
        self.receipt = receipt
        self.request = request
        self.attempt = max(0, attempt)
        self.nextRetryAt = nextRetryAt
        self.lastFailureReason = lastFailureReason
        self.state = state
        self.updatedAt = updatedAt
        self.replayMetadata = replayMetadata
        self.lastTerminalStatus = lastTerminalStatus
        self.lastTerminalAt = lastTerminalAt
    }
}

public protocol OfflineWriteStore: Sendable {
    @discardableResult
    func enqueue(request: APIRequest, requestKey: String, now: Date) async throws -> QueuedWriteReceipt
    @discardableResult
    func enqueue(
        request: APIRequest,
        requestKey: String,
        replayMetadata: OfflineReplayMetadata,
        now: Date
    ) async throws -> QueuedWriteReceipt
    func nextBatch(limit: Int, now: Date) async -> [OfflineWriteStoreEntry]
    func markReplaying(queueID: String, attempt: Int, now: Date) async
    func markRetryWaiting(queueID: String, attempt: Int, reason: String, nextRetryAt: Date, now: Date) async
    func markSucceeded(queueID: String) async
    func markDeadLetter(queueID: String, reason: String, now: Date) async
    func markManualReview(queueID: String, reason: String, now: Date) async
    func requeueManualReview(queueID: String, reason: String?, now: Date) async -> Bool
    func hasReplayTerminalSuccess(replayIdentity: String, within: TimeInterval, now: Date) async -> Bool
    func recordReplayTerminalSuccess(replayIdentity: String, now: Date) async
    func rotateEncryption(now: Date) async -> Int
    func consumeRecoveryReport() async -> OfflineStoreRecoveryReport?
    func depth(now: Date) async -> Int
    func snapshot(now: Date) async -> [OfflineWriteStoreEntry]
    @discardableResult
    func drop(queueID: String) async -> Bool
    @discardableResult
    func dropAll() async -> Int
}

public extension OfflineWriteStore {
    @discardableResult
    func enqueue(
        request: APIRequest,
        requestKey: String,
        replayMetadata: OfflineReplayMetadata,
        now: Date
    ) async throws -> QueuedWriteReceipt {
        try await enqueue(request: request, requestKey: requestKey, now: now)
    }

    func markManualReview(queueID: String, reason: String, now: Date) async {
        await markDeadLetter(queueID: queueID, reason: reason, now: now)
    }

    func requeueManualReview(queueID: String, reason: String?, now: Date) async -> Bool {
        _ = queueID
        _ = reason
        _ = now
        return false
    }

    func hasReplayTerminalSuccess(replayIdentity: String, within: TimeInterval, now: Date) async -> Bool {
        false
    }

    func recordReplayTerminalSuccess(replayIdentity: String, now: Date) async {}

    func rotateEncryption(now: Date) async -> Int {
        _ = now
        return 0
    }

    func consumeRecoveryReport() async -> OfflineStoreRecoveryReport? { nil }
}
