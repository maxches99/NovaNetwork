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

    public init(
        mode: Mode = .disabled,
        maxEntries: Int? = nil,
        ttlSeconds: TimeInterval? = nil,
        maxReplayAttempts: Int = 5
    ) {
        self.mode = mode
        self.maxEntries = maxEntries.map { max(1, $0) }
        self.ttlSeconds = ttlSeconds.map { max(0, $0) }
        self.maxReplayAttempts = max(1, maxReplayAttempts)
    }

    public static let disabled = OfflineQueuePolicy(mode: .disabled)
}
