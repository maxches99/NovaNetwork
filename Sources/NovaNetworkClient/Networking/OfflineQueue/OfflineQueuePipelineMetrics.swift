import NovaNetworkCore
import Foundation

public struct OfflineQueueAgeDistribution: Sendable, Equatable {
    public let p50Seconds: TimeInterval
    public let p90Seconds: TimeInterval
    public let p95Seconds: TimeInterval
    public let maxSeconds: TimeInterval

    public init(
        p50Seconds: TimeInterval,
        p90Seconds: TimeInterval,
        p95Seconds: TimeInterval? = nil,
        maxSeconds: TimeInterval
    ) {
        self.p50Seconds = max(0, p50Seconds)
        self.p90Seconds = max(0, p90Seconds)
        self.p95Seconds = max(0, p95Seconds ?? p90Seconds)
        self.maxSeconds = max(0, maxSeconds)
    }
}

public struct OfflineQueueReplayThroughput: Sendable, Equatable {
    public let replayedCount: Int
    public let windowSeconds: TimeInterval
    public let replaysPerSecond: Double

    public init(replayedCount: Int, windowSeconds: TimeInterval, replaysPerSecond: Double) {
        self.replayedCount = max(0, replayedCount)
        self.windowSeconds = max(0, windowSeconds)
        self.replaysPerSecond = max(0, replaysPerSecond)
    }
}

public struct OfflineQueuePipelineMetrics: Sendable, Equatable {
    public let queueDepth: Int
    public let ageDistribution: OfflineQueueAgeDistribution
    public let replayThroughput: OfflineQueueReplayThroughput
    public let terminalOutcomes: [OfflineQueueTerminalStatus: Int]

    public init(
        queueDepth: Int,
        ageDistribution: OfflineQueueAgeDistribution,
        replayThroughput: OfflineQueueReplayThroughput,
        terminalOutcomes: [OfflineQueueTerminalStatus: Int]
    ) {
        self.queueDepth = max(0, queueDepth)
        self.ageDistribution = ageDistribution
        self.replayThroughput = replayThroughput
        self.terminalOutcomes = terminalOutcomes
    }
}
