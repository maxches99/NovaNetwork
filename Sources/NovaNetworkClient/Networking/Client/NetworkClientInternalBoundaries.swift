import Foundation

struct NetworkClientHTTPExecutionContext: Sendable {
    let key: String
    let request: APIRequest
    let authScope: String?
    let retryPolicy: RetryPolicy
    let deadline: NetworkClient.RequestDeadline?
    let coalescingMode: TelemetryCoalescingMode
    let policyScope: String
}

protocol NetworkClientHTTPExecutionPipeline {
    func execute(_ context: NetworkClientHTTPExecutionContext) async -> Result<NetworkResponse, NetworkError>
}

struct DefaultNetworkClientHTTPExecutionPipeline: NetworkClientHTTPExecutionPipeline {
    typealias Executor = @Sendable (
        _ key: String,
        _ request: APIRequest,
        _ authScope: String?,
        _ transport: any NetworkTransport,
        _ retryPolicy: RetryPolicy,
        _ retryClock: any RetryClock,
        _ retryRandomGenerator: any RetryRandomGenerator,
        _ middlewares: [NetworkMiddleware],
        _ telemetryHooks: NetworkTelemetryHooks?,
        _ observer: (@Sendable (NetworkClientEvent) -> Void)?,
        _ deadline: NetworkClient.RequestDeadline?,
        _ coalescingMode: TelemetryCoalescingMode,
        _ policyScope: String
    ) async -> Result<NetworkResponse, NetworkError>

    private let transport: any NetworkTransport
    private let defaultRetryPolicy: RetryPolicy
    private let retryClock: any RetryClock
    private let retryRandomGenerator: any RetryRandomGenerator
    private let middlewares: [NetworkMiddleware]
    private let telemetryHooks: NetworkTelemetryHooks?
    private let observer: (@Sendable (NetworkClientEvent) -> Void)?
    private let executor: Executor

    init(
        transport: any NetworkTransport,
        retryPolicy: RetryPolicy,
        retryClock: any RetryClock,
        retryRandomGenerator: any RetryRandomGenerator,
        middlewares: [NetworkMiddleware],
        telemetryHooks: NetworkTelemetryHooks?,
        observer: (@Sendable (NetworkClientEvent) -> Void)?,
        executor: @escaping Executor
    ) {
        self.transport = transport
        self.defaultRetryPolicy = retryPolicy
        self.retryClock = retryClock
        self.retryRandomGenerator = retryRandomGenerator
        self.middlewares = middlewares
        self.telemetryHooks = telemetryHooks
        self.observer = observer
        self.executor = executor
    }

    func execute(_ context: NetworkClientHTTPExecutionContext) async -> Result<NetworkResponse, NetworkError> {
        await executor(
            context.key,
            context.request,
            context.authScope,
            transport,
            context.retryPolicy,
            retryClock,
            retryRandomGenerator,
            middlewares,
            telemetryHooks,
            observer,
            context.deadline,
            context.coalescingMode,
            context.policyScope
        )
    }
}

protocol NetworkClientOfflineReplayCoordinating: Actor {
    func beginFlush() -> Bool
    func endFlush()
    func markReplay()
    func markOutcome(_ status: OfflineQueueTerminalStatus)
    func snapshotMetrics(now: Date) -> (startedAt: Date?, replayedCount: Int, terminalOutcomes: [OfflineQueueTerminalStatus: Int])
    func readyForReplay(entries: [OfflineWriteStoreEntry], now: Date) -> [OfflineWriteStoreEntry]
    func scheduleReplayBatch(
        entries: [OfflineWriteStoreEntry],
        limit: Int,
        policy: OfflineReplaySchedulerPolicy,
        now: Date
    ) -> [OfflineWriteStoreEntry]
}

actor DefaultNetworkClientOfflineReplayCoordinator: NetworkClientOfflineReplayCoordinating {
    private var isFlushRunning = false
    private var replayStartedAt: Date?
    private var replayedCount: Int = 0
    private var terminalOutcomes: [OfflineQueueTerminalStatus: Int] = [:]

    func beginFlush() -> Bool {
        guard !isFlushRunning else { return false }
        isFlushRunning = true
        return true
    }

    func endFlush() {
        isFlushRunning = false
    }

    func markReplay() {
        if replayStartedAt == nil {
            replayStartedAt = Date()
        }
        replayedCount += 1
    }

    func markOutcome(_ status: OfflineQueueTerminalStatus) {
        terminalOutcomes[status, default: 0] += 1
    }

    func snapshotMetrics(now: Date) -> (startedAt: Date?, replayedCount: Int, terminalOutcomes: [OfflineQueueTerminalStatus: Int]) {
        (replayStartedAt, replayedCount, terminalOutcomes)
    }

    func readyForReplay(entries: [OfflineWriteStoreEntry], now: Date) -> [OfflineWriteStoreEntry] {
        entries.filter { entry in
            switch entry.state {
            case .queued, .replayScheduled:
                return true
            case .retryWaiting:
                guard let nextRetryAt = entry.nextRetryAt else { return true }
                return nextRetryAt <= now
            case .replaying, .deadLetter, .manualReview:
                return false
            }
        }
    }

    func scheduleReplayBatch(
        entries: [OfflineWriteStoreEntry],
        limit: Int,
        policy: OfflineReplaySchedulerPolicy,
        now: Date
    ) -> [OfflineWriteStoreEntry] {
        guard limit > 0 else { return [] }
        guard !entries.isEmpty else { return [] }
        let sorted = entries.sorted { lhs, rhs in
            lhs.receipt.position < rhs.receipt.position
        }

        let starvationCutoff = now.addingTimeInterval(-policy.starvationProtectionAgeSeconds)
        let starved = sorted.filter { $0.receipt.enqueuedAt <= starvationCutoff }
        var scheduled: [OfflineWriteStoreEntry] = Array(starved.prefix(limit))
        if scheduled.count >= limit {
            return scheduled
        }

        var usedIDs = Set(scheduled.map { $0.receipt.queueID })
        var remaining = sorted.filter { !usedIDs.contains($0.receipt.queueID) }
        if remaining.isEmpty {
            return scheduled
        }

        var perPriorityBuckets: [OfflineQueuePriority: [OfflineWriteStoreEntry]] = [:]
        for entry in remaining {
            perPriorityBuckets[entry.replayMetadata.priority, default: []].append(entry)
        }

        var cycle: [OfflineQueuePriority] = []
        for priority in OfflineQueuePriority.allCases {
            let weight = max(1, policy.fairReplayWeights[priority] ?? 1)
            cycle.append(contentsOf: Array(repeating: priority, count: weight))
        }
        if cycle.isEmpty {
            cycle = OfflineQueuePriority.allCases
        }

        var perBandRemaining: [OfflineQueuePriority: Int] = [:]
        for priority in OfflineQueuePriority.allCases {
            perBandRemaining[priority] = Int.max
        }
        for limitRule in policy.priorityBandLimits {
            perBandRemaining[limitRule.priority] = min(
                perBandRemaining[limitRule.priority] ?? Int.max,
                max(1, limitRule.maxConsecutiveReplays)
            )
        }

        var cycleIndex = 0
        while scheduled.count < limit {
            if remaining.isEmpty {
                break
            }
            let priority = cycle[cycleIndex % cycle.count]
            cycleIndex += 1
            guard (perBandRemaining[priority] ?? 0) > 0 else { continue }
            guard var bucket = perPriorityBuckets[priority], !bucket.isEmpty else { continue }

            let next = bucket.removeFirst()
            perPriorityBuckets[priority] = bucket
            scheduled.append(next)
            usedIDs.insert(next.receipt.queueID)
            perBandRemaining[priority] = (perBandRemaining[priority] ?? 1) - 1
            remaining.removeAll { $0.receipt.queueID == next.receipt.queueID }
        }

        return scheduled
    }
}
