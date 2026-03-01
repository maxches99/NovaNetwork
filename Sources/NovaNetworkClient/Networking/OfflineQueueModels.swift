import Foundation

public enum OfflineReplayConflictPolicy: String, Sendable, Equatable, Codable {
    case retry
    case drop
    case manualReview
}

public enum OfflineQueuePriority: String, Sendable, Equatable, Codable, CaseIterable {
    case critical
    case normal
    case background
}

public enum OfflineQueueTerminalStatus: String, Sendable, Equatable, Codable {
    case succeeded
    case dedupeSuppressed
    case droppedConflict
    case manualReview
    case failed
}

public struct OfflineReplayWindowPolicy: Sendable, Equatable, Codable {
    public let maxContinuousReplaySeconds: TimeInterval
    public let coolDownSeconds: TimeInterval
    public let maxReplaysPerSecond: Double

    public init(
        maxContinuousReplaySeconds: TimeInterval = 30,
        coolDownSeconds: TimeInterval = 1,
        maxReplaysPerSecond: Double = 20
    ) {
        self.maxContinuousReplaySeconds = max(1, maxContinuousReplaySeconds)
        self.coolDownSeconds = max(0, coolDownSeconds)
        self.maxReplaysPerSecond = max(0.1, maxReplaysPerSecond)
    }
}

public struct OfflineReplayPriorityBandLimit: Sendable, Equatable, Codable {
    public let priority: OfflineQueuePriority
    public let maxConsecutiveReplays: Int

    public init(priority: OfflineQueuePriority, maxConsecutiveReplays: Int) {
        self.priority = priority
        self.maxConsecutiveReplays = max(1, maxConsecutiveReplays)
    }
}

public struct OfflineReplaySchedulerPolicy: Sendable, Equatable, Codable {
    public let fairReplayWeights: [OfflineQueuePriority: Int]
    public let starvationProtectionAgeSeconds: TimeInterval
    public let priorityBandLimits: [OfflineReplayPriorityBandLimit]
    public let replayWindow: OfflineReplayWindowPolicy

    public init(
        fairReplayWeights: [OfflineQueuePriority: Int] = [
            .critical: 4,
            .normal: 2,
            .background: 1
        ],
        starvationProtectionAgeSeconds: TimeInterval = 90,
        priorityBandLimits: [OfflineReplayPriorityBandLimit] = [
            .init(priority: .critical, maxConsecutiveReplays: 8),
            .init(priority: .normal, maxConsecutiveReplays: 4),
            .init(priority: .background, maxConsecutiveReplays: 2)
        ],
        replayWindow: OfflineReplayWindowPolicy = .init()
    ) {
        var normalizedWeights: [OfflineQueuePriority: Int] = [:]
        for priority in OfflineQueuePriority.allCases {
            normalizedWeights[priority] = max(1, fairReplayWeights[priority] ?? 1)
        }
        self.fairReplayWeights = normalizedWeights
        self.starvationProtectionAgeSeconds = max(1, starvationProtectionAgeSeconds)
        self.priorityBandLimits = priorityBandLimits
        self.replayWindow = replayWindow
    }
}

public struct OfflineQueueConflictMetadata: Sendable, Equatable, Codable {
    public let queueID: String
    public let requestKey: String
    public let replayIdentity: String
    public let attempt: Int
    public let maxReplayAttempts: Int
    public let failureReason: String
    public let statusCode: Int?
    public let priority: OfflineQueuePriority
    public let enqueuedAt: Date
    public let occurredAt: Date

    public init(
        queueID: String,
        requestKey: String,
        replayIdentity: String,
        attempt: Int,
        maxReplayAttempts: Int,
        failureReason: String,
        statusCode: Int?,
        priority: OfflineQueuePriority,
        enqueuedAt: Date,
        occurredAt: Date = Date()
    ) {
        self.queueID = queueID
        self.requestKey = requestKey
        self.replayIdentity = replayIdentity
        self.attempt = max(1, attempt)
        self.maxReplayAttempts = max(1, maxReplayAttempts)
        self.failureReason = failureReason
        self.statusCode = statusCode
        self.priority = priority
        self.enqueuedAt = enqueuedAt
        self.occurredAt = occurredAt
    }
}

public enum OfflineConflictResolutionDecision: Sendable, Equatable, Codable {
    case retry(afterSeconds: TimeInterval?)
    case drop(reason: String?)
    case manualReview(reason: String?)
}

public struct OfflineReplayMetadata: Sendable, Equatable, Codable {
    public let replayIdentity: String
    public let maxReplayAttempts: Int
    public let dedupeWindowSeconds: TimeInterval
    public let conflictPolicy: OfflineReplayConflictPolicy
    public let priority: OfflineQueuePriority
    public let schedulerPolicy: OfflineReplaySchedulerPolicy

    public init(
        replayIdentity: String,
        maxReplayAttempts: Int = 5,
        dedupeWindowSeconds: TimeInterval = 24 * 60 * 60,
        conflictPolicy: OfflineReplayConflictPolicy = .retry,
        priority: OfflineQueuePriority = .normal,
        schedulerPolicy: OfflineReplaySchedulerPolicy = .init()
    ) {
        self.replayIdentity = replayIdentity
        self.maxReplayAttempts = max(1, maxReplayAttempts)
        self.dedupeWindowSeconds = max(0, dedupeWindowSeconds)
        self.conflictPolicy = conflictPolicy
        self.priority = priority
        self.schedulerPolicy = schedulerPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case replayIdentity
        case maxReplayAttempts
        case dedupeWindowSeconds
        case conflictPolicy
        case priority
        case schedulerPolicy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        replayIdentity = try container.decode(String.self, forKey: .replayIdentity)
        maxReplayAttempts = max(1, try container.decodeIfPresent(Int.self, forKey: .maxReplayAttempts) ?? 5)
        dedupeWindowSeconds = max(0, try container.decodeIfPresent(TimeInterval.self, forKey: .dedupeWindowSeconds) ?? 24 * 60 * 60)
        conflictPolicy = try container.decodeIfPresent(OfflineReplayConflictPolicy.self, forKey: .conflictPolicy) ?? .retry
        priority = try container.decodeIfPresent(OfflineQueuePriority.self, forKey: .priority) ?? .normal
        schedulerPolicy = try container.decodeIfPresent(OfflineReplaySchedulerPolicy.self, forKey: .schedulerPolicy) ?? .init()
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
    public let priority: OfflineQueuePriority

    public init(
        receipt: QueuedWriteReceipt,
        method: URLMethod,
        url: URL,
        attempt: Int,
        state: OfflineQueueEntryState,
        priority: OfflineQueuePriority
    ) {
        self.receipt = receipt
        self.method = method
        self.url = url
        self.attempt = max(0, attempt)
        self.state = state
        self.priority = priority
    }
}
