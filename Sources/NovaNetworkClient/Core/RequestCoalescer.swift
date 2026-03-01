import Foundation

public actor RequestCoalescer<Output: Sendable, Failure: Error> {
    public enum RequestPriority: Int, Sendable {
        case low = 0
        case medium = 1
        case high = 2
    }

    public enum CapacityScheduling: Sendable {
        case bypassWhenAtCapacity
        case queueByPriority
    }

    public struct RunOptions: Sendable {
        public let limitsOverride: Limits?
        public let priority: RequestPriority
        public let capacityScheduling: CapacityScheduling

        public init(
            limitsOverride: Limits? = nil,
            priority: RequestPriority = .medium,
            capacityScheduling: CapacityScheduling = .bypassWhenAtCapacity
        ) {
            self.limitsOverride = limitsOverride
            self.priority = priority
            self.capacityScheduling = capacityScheduling
        }
    }

    public struct FairnessPolicy: Sendable, Equatable {
        public let highWeight: Int
        public let mediumWeight: Int
        public let lowWeight: Int

        public init(
            highWeight: Int = 4,
            mediumWeight: Int = 2,
            lowWeight: Int = 1
        ) {
            self.highWeight = max(1, highWeight)
            self.mediumWeight = max(1, mediumWeight)
            self.lowWeight = max(1, lowWeight)
        }
    }

    public struct Limits: Sendable {
        public enum WaiterOverflowBehavior: Sendable {
            case bypass
            case fail
        }

        public let maxInFlightKeys: Int?
        public let maxWaitersPerKey: Int?
        public let inFlightTimeout: TimeInterval?
        public let waiterOverflowBehavior: WaiterOverflowBehavior

        public init(
            maxInFlightKeys: Int? = nil,
            maxWaitersPerKey: Int? = nil,
            inFlightTimeout: TimeInterval? = nil,
            waiterOverflowBehavior: WaiterOverflowBehavior = .bypass
        ) {
            self.maxInFlightKeys = maxInFlightKeys.map { max(1, $0) }
            self.maxWaitersPerKey = maxWaitersPerKey.map { max(1, $0) }
            self.inFlightTimeout = inFlightTimeout.map { max(0, $0) }
            self.waiterOverflowBehavior = waiterOverflowBehavior
        }
    }

    public enum BypassReason: String, Sendable {
        case maxInFlightKeysReached
        case maxWaitersPerKeyReached
    }

    public struct Metrics: Sendable {
        public let coalescedHits: Int
        public let coalescedMisses: Int
        public let waiterCancellations: Int
        public let finishedOperations: Int
        public let bypassedDueToCapacity: Int
        public let bypassedDueToWaiterLimit: Int
        public let timedOutEntries: Int
        public let memoryPressureEvictions: Int

        public init(
            coalescedHits: Int,
            coalescedMisses: Int,
            waiterCancellations: Int,
            finishedOperations: Int,
            bypassedDueToCapacity: Int,
            bypassedDueToWaiterLimit: Int,
            timedOutEntries: Int,
            memoryPressureEvictions: Int
        ) {
            self.coalescedHits = coalescedHits
            self.coalescedMisses = coalescedMisses
            self.waiterCancellations = waiterCancellations
            self.finishedOperations = finishedOperations
            self.bypassedDueToCapacity = bypassedDueToCapacity
            self.bypassedDueToWaiterLimit = bypassedDueToWaiterLimit
            self.timedOutEntries = timedOutEntries
            self.memoryPressureEvictions = memoryPressureEvictions
        }
    }

    public struct InFlightEntry: Sendable {
        public let key: String
        public let waiterCount: Int
        public let durationMilliseconds: Double

        public init(key: String, waiterCount: Int, durationMilliseconds: Double) {
            self.key = key
            self.waiterCount = waiterCount
            self.durationMilliseconds = durationMilliseconds
        }
    }

    public enum Event: Sendable {
        case started(key: String)
        case coalesced(key: String, waiterCount: Int)
        case bypassed(key: String, reason: BypassReason)
        case waiterCancelled(key: String, remainingWaiters: Int)
        case timedOut(key: String, durationMilliseconds: Double, waiterCount: Int)
        case finished(key: String, durationMilliseconds: Double, waiterCount: Int, wasCancelled: Bool)
    }

    public typealias Observer = @Sendable (Event) -> Void
    public typealias QueueMetricsObserver = @Sendable (QueueMetrics) -> Void

    public struct QueueMetrics: Sendable {
        public let key: String
        public let queueDepth: Int
        public let waitMilliseconds: Double

        public init(key: String, queueDepth: Int, waitMilliseconds: Double) {
            self.key = key
            self.queueDepth = queueDepth
            self.waitMilliseconds = waitMilliseconds
        }
    }

    private struct Entry {
        let task: Task<Result<Output, Failure>, Never>
        let startedAtNanoseconds: UInt64
        var waiters: Set<UUID>
        var peakWaiters: Int
    }

    private struct CapacityWaiter {
        let key: String
        let priority: RequestPriority
        let sequence: UInt64
        let queuedAtNanoseconds: UInt64
        let queueDepthAtEnqueue: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var entries: [String: Entry] = [:]
    private let policy: CancellationPolicy
    private let limits: Limits
    private let overflowFailureFactory: (@Sendable () -> Failure)?
    private let observer: Observer?
    private let queueMetricsObserver: QueueMetricsObserver?
    private var coalescedHits = 0
    private var coalescedMisses = 0
    private var waiterCancellations = 0
    private var finishedOperations = 0
    private var bypassedDueToCapacity = 0
    private var bypassedDueToWaiterLimit = 0
    private var timedOutEntries = 0
    private var memoryPressureEvictions = 0
    private var capacityWaiters: [CapacityWaiter] = []
    private var capacityWaiterSequence: UInt64 = 0
    private var fairnessCycleIndex = 0
    private var fairnessPolicy: FairnessPolicy

    private enum Acquisition {
        case shared(task: Task<Result<Output, Failure>, Never>, waiterID: UUID)
        case standalone(task: Task<Result<Output, Failure>, Never>)
    }

    public init(
        policy: CancellationPolicy = .keepRunning,
        limits: Limits = Limits(),
        fairnessPolicy: FairnessPolicy = .init(),
        observer: Observer? = nil,
        queueMetricsObserver: QueueMetricsObserver? = nil,
        overflowFailureFactory: (@Sendable () -> Failure)? = nil
    ) {
        self.policy = policy
        self.limits = limits
        self.fairnessPolicy = fairnessPolicy
        self.observer = observer
        self.queueMetricsObserver = queueMetricsObserver
        self.overflowFailureFactory = overflowFailureFactory
    }

    public func updateFairnessPolicy(_ newPolicy: FairnessPolicy) {
        fairnessPolicy = newPolicy
        fairnessCycleIndex = 0
    }

    public func currentFairnessPolicy() -> FairnessPolicy {
        fairnessPolicy
    }

    public func run(
        key: String,
        options: RunOptions = .init(),
        operation: @Sendable @escaping () async -> Result<Output, Failure>
    ) async throws -> Output {
        evictTimedOutEntriesIfNeeded()
        await waitForCapacityIfNeeded(key: key, options: options)
        let acquisition = acquireTask(for: key, options: options, operation: operation)

        switch acquisition {
        case .shared(let task, let waiterID):
            return try await withTaskCancellationHandler {
                let result = await task.value
                waiterFinished(key: key, waiterID: waiterID)
                return try unwrap(result)
            } onCancel: {
                Task { await self.waiterCancelled(key: key, waiterID: waiterID) }
            }
        case .standalone(let task):
            return try await withTaskCancellationHandler {
                let result = await task.value
                return try unwrap(result)
            } onCancel: {
                task.cancel()
            }
        }
    }

    private func acquireTask(
        for key: String,
        options: RunOptions,
        operation: @Sendable @escaping () async -> Result<Output, Failure>
    ) -> Acquisition {
        let waiterID = UUID()
        let resolvedLimits = options.limitsOverride ?? limits

        if var existing = entries[key] {
            if let maxWaiters = resolvedLimits.maxWaitersPerKey, existing.waiters.count >= maxWaiters {
                if resolvedLimits.waiterOverflowBehavior == .fail,
                   let overflowFailureFactory {
                    return .standalone(task: Task { .failure(overflowFailureFactory()) })
                } else {
                    bypassedDueToWaiterLimit += 1
                    observer?(.bypassed(key: key, reason: .maxWaitersPerKeyReached))
                    return .standalone(task: Task { await operation() })
                }
            }

            existing.waiters.insert(waiterID)
            existing.peakWaiters = max(existing.peakWaiters, existing.waiters.count)
            entries[key] = existing
            coalescedHits += 1
            observer?(.coalesced(key: key, waiterCount: existing.waiters.count))
            return .shared(task: existing.task, waiterID: waiterID)
        }

        if let maxInFlight = resolvedLimits.maxInFlightKeys, entries.count >= maxInFlight {
            bypassedDueToCapacity += 1
            observer?(.bypassed(key: key, reason: .maxInFlightKeysReached))
            return .standalone(task: Task { await operation() })
        }

        let task = Task { await operation() }
        entries[key] = Entry(
            task: task,
            startedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            waiters: [waiterID],
            peakWaiters: 1
        )
        coalescedMisses += 1
        observer?(.started(key: key))
        return .shared(task: task, waiterID: waiterID)
    }

    private func waiterCancelled(key: String, waiterID: UUID) {
        guard var entry = entries[key] else { return }
        guard entry.waiters.remove(waiterID) != nil else { return }
        waiterCancellations += 1
        observer?(.waiterCancelled(key: key, remainingWaiters: entry.waiters.count))

        if entry.waiters.isEmpty {
            let wasCancelled: Bool
            if policy == .cancelWhenNoWaiters {
                entry.task.cancel()
                wasCancelled = true
            } else {
                wasCancelled = entry.task.isCancelled
            }
            entries[key] = nil
            finishedOperations += 1
            observer?(
                .finished(
                    key: key,
                    durationMilliseconds: milliseconds(since: entry.startedAtNanoseconds),
                    waiterCount: entry.peakWaiters,
                    wasCancelled: wasCancelled
                )
            )
            resumeNextCapacityWaiterIfNeeded()
        } else {
            entries[key] = entry
        }
    }

    private func waiterFinished(key: String, waiterID: UUID) {
        guard var entry = entries[key] else { return }
        _ = entry.waiters.remove(waiterID)

        if entry.waiters.isEmpty {
            entries[key] = nil
            finishedOperations += 1
            observer?(
                .finished(
                    key: key,
                    durationMilliseconds: milliseconds(since: entry.startedAtNanoseconds),
                    waiterCount: entry.peakWaiters,
                    wasCancelled: entry.task.isCancelled
                )
            )
            resumeNextCapacityWaiterIfNeeded()
        } else {
            entries[key] = entry
        }
    }

    public func snapshotMetrics() -> Metrics {
        evictTimedOutEntriesIfNeeded()

        return Metrics(
            coalescedHits: coalescedHits,
            coalescedMisses: coalescedMisses,
            waiterCancellations: waiterCancellations,
            finishedOperations: finishedOperations,
            bypassedDueToCapacity: bypassedDueToCapacity,
            bypassedDueToWaiterLimit: bypassedDueToWaiterLimit,
            timedOutEntries: timedOutEntries,
            memoryPressureEvictions: memoryPressureEvictions
        )
    }

    public func handleMemoryPressure(cancelInFlight: Bool = true) {
        guard cancelInFlight else { return }
        let allEntries = entries
        entries.removeAll(keepingCapacity: false)
        memoryPressureEvictions += allEntries.count
        for (_, entry) in allEntries {
            entry.task.cancel()
            finishedOperations += 1
        }
        resumeAllCapacityWaiters()
    }

    public func inFlightEntries() -> [InFlightEntry] {
        let now = DispatchTime.now().uptimeNanoseconds
        return entries.map { key, entry in
            let elapsed = now >= entry.startedAtNanoseconds ? (now - entry.startedAtNanoseconds) : 0
            return InFlightEntry(
                key: key,
                waiterCount: entry.waiters.count,
                durationMilliseconds: Double(elapsed) / 1_000_000
            )
        }
        .sorted { $0.key < $1.key }
    }

    private func unwrap(_ result: Result<Output, Failure>) throws -> Output {
        switch result {
        case .success(let output): return output
        case .failure(let failure): throw failure
        }
    }

    private func milliseconds(since startNanoseconds: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startNanoseconds ? (now - startNanoseconds) : 0
        return Double(elapsed) / 1_000_000.0
    }

    private func evictTimedOutEntriesIfNeeded() {
        guard let timeout = limits.inFlightTimeout else { return }
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let now = DispatchTime.now().uptimeNanoseconds
        let expired = entries.filter {
            now >= $0.value.startedAtNanoseconds &&
            (now - $0.value.startedAtNanoseconds) >= timeoutNanoseconds
        }

        guard !expired.isEmpty else { return }

        for (key, entry) in expired {
            entries[key] = nil
            timedOutEntries += 1
            finishedOperations += 1
            entry.task.cancel()
            let durationMilliseconds = milliseconds(since: entry.startedAtNanoseconds)
            observer?(.timedOut(key: key, durationMilliseconds: durationMilliseconds, waiterCount: entry.peakWaiters))
            observer?(
                .finished(
                    key: key,
                    durationMilliseconds: durationMilliseconds,
                    waiterCount: entry.peakWaiters,
                    wasCancelled: true
                )
            )
            resumeNextCapacityWaiterIfNeeded()
        }
    }

    private func waitForCapacityIfNeeded(key: String, options: RunOptions) async {
        guard entries[key] == nil else { return }
        let resolvedLimits = options.limitsOverride ?? limits
        guard let maxInFlight = resolvedLimits.maxInFlightKeys else { return }
        guard options.capacityScheduling == .queueByPriority else { return }
        guard entries.count >= maxInFlight else { return }

        // Queue new keys while capacity is saturated to avoid bypassing coalescing.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let enqueueDepth = capacityWaiters.count + 1
            let waiter = CapacityWaiter(
                key: key,
                priority: options.priority,
                sequence: capacityWaiterSequence,
                queuedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
                queueDepthAtEnqueue: enqueueDepth,
                continuation: continuation
            )
            capacityWaiterSequence += 1
            capacityWaiters.append(waiter)
        }
    }

    private func resumeNextCapacityWaiterIfNeeded() {
        guard !capacityWaiters.isEmpty else { return }
        let cycle = fairnessCycle()
        if !cycle.isEmpty {
            for offset in 0..<cycle.count {
                let cycleIndex = (fairnessCycleIndex + offset) % cycle.count
                let priority = cycle[cycleIndex]
                if let waiterIndex = oldestCapacityWaiterIndex(for: priority) {
                    let waiter = capacityWaiters.remove(at: waiterIndex)
                    fairnessCycleIndex = (cycleIndex + 1) % cycle.count
                    queueMetricsObserver?(
                        QueueMetrics(
                            key: waiter.key,
                            queueDepth: waiter.queueDepthAtEnqueue,
                            waitMilliseconds: milliseconds(since: waiter.queuedAtNanoseconds)
                        )
                    )
                    waiter.continuation.resume()
                    return
                }
            }
        }

        guard let waiter = capacityWaiters.min(by: { $0.sequence < $1.sequence }) else { return }
        capacityWaiters.removeAll { $0.sequence == waiter.sequence }
        queueMetricsObserver?(
            QueueMetrics(
                key: waiter.key,
                queueDepth: waiter.queueDepthAtEnqueue,
                waitMilliseconds: milliseconds(since: waiter.queuedAtNanoseconds)
            )
        )
        waiter.continuation.resume()
    }

    private func oldestCapacityWaiterIndex(for priority: RequestPriority) -> Int? {
        capacityWaiters.indices
            .filter { capacityWaiters[$0].priority == priority }
            .min { capacityWaiters[$0].sequence < capacityWaiters[$1].sequence }
    }

    private func fairnessCycle() -> [RequestPriority] {
        Array(repeating: .high, count: fairnessPolicy.highWeight) +
        Array(repeating: .medium, count: fairnessPolicy.mediumWeight) +
        Array(repeating: .low, count: fairnessPolicy.lowWeight)
    }

    private func resumeAllCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}
