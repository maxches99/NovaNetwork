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

    public struct Limits: Sendable {
        public let maxInFlightKeys: Int?
        public let maxWaitersPerKey: Int?
        public let inFlightTimeout: TimeInterval?

        public init(
            maxInFlightKeys: Int? = nil,
            maxWaitersPerKey: Int? = nil,
            inFlightTimeout: TimeInterval? = nil
        ) {
            self.maxInFlightKeys = maxInFlightKeys.map { max(1, $0) }
            self.maxWaitersPerKey = maxWaitersPerKey.map { max(1, $0) }
            self.inFlightTimeout = inFlightTimeout.map { max(0, $0) }
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

    public enum Event: Sendable {
        case started(key: String)
        case coalesced(key: String, waiterCount: Int)
        case bypassed(key: String, reason: BypassReason)
        case waiterCancelled(key: String, remainingWaiters: Int)
        case timedOut(key: String, durationMilliseconds: Double, waiterCount: Int)
        case finished(key: String, durationMilliseconds: Double, waiterCount: Int, wasCancelled: Bool)
    }

    public typealias Observer = @Sendable (Event) -> Void

    private struct Entry {
        let task: Task<Result<Output, Failure>, Never>
        let startedAtNanoseconds: UInt64
        var waiters: Set<UUID>
        var peakWaiters: Int
    }

    private struct CapacityWaiter {
        let priority: RequestPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private var entries: [String: Entry] = [:]
    private let policy: CancellationPolicy
    private let limits: Limits
    private let observer: Observer?
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

    private enum Acquisition {
        case shared(task: Task<Result<Output, Failure>, Never>, waiterID: UUID)
        case standalone(task: Task<Result<Output, Failure>, Never>)
    }

    public init(
        policy: CancellationPolicy = .keepRunning,
        limits: Limits = Limits(),
        observer: Observer? = nil
    ) {
        self.policy = policy
        self.limits = limits
        self.observer = observer
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
                bypassedDueToWaiterLimit += 1
                observer?(.bypassed(key: key, reason: .maxWaitersPerKeyReached))
                return .standalone(task: Task { await operation() })
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
            let waiter = CapacityWaiter(
                priority: options.priority,
                sequence: capacityWaiterSequence,
                continuation: continuation
            )
            capacityWaiterSequence += 1
            capacityWaiters.append(waiter)
        }
    }

    private func resumeNextCapacityWaiterIfNeeded() {
        guard !capacityWaiters.isEmpty else { return }
        // Highest priority first; FIFO order for waiters with the same priority.
        let bestIndex = capacityWaiters.indices.max { lhs, rhs in
            let left = capacityWaiters[lhs]
            let right = capacityWaiters[rhs]

            if left.priority.rawValue == right.priority.rawValue {
                return left.sequence > right.sequence
            }
            return left.priority.rawValue < right.priority.rawValue
        }

        guard let index = bestIndex else { return }
        let waiter = capacityWaiters.remove(at: index)
        waiter.continuation.resume()
    }

    private func resumeAllCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}
