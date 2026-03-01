import Foundation

public struct OfflineQueuePolicy: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case disabled
        case enqueueWhenOffline
        case alwaysEnqueue
    }

    public let mode: Mode
    public let maxEntries: Int?
    public let ttlSeconds: TimeInterval?
    public let maxReplayAttempts: Int
    public let replayConflictPolicy: OfflineReplayConflictPolicy
    public let replayDedupeWindowSeconds: TimeInterval

    public init(
        mode: Mode = .disabled,
        maxEntries: Int? = nil,
        ttlSeconds: TimeInterval? = nil,
        maxReplayAttempts: Int = 5,
        replayConflictPolicy: OfflineReplayConflictPolicy = .retry,
        replayDedupeWindowSeconds: TimeInterval = 24 * 60 * 60
    ) {
        self.mode = mode
        self.maxEntries = maxEntries.map { max(1, $0) }
        self.ttlSeconds = ttlSeconds.map { max(0, $0) }
        self.maxReplayAttempts = max(1, maxReplayAttempts)
        self.replayConflictPolicy = replayConflictPolicy
        self.replayDedupeWindowSeconds = max(0, replayDedupeWindowSeconds)
    }

    public static let disabled = OfflineQueuePolicy(mode: .disabled)
}
