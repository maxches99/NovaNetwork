import Foundation

/// Admits requests up to a limit that moves with what the server can take.
///
/// Callers that arrive while every slot is busy wait in arrival order rather than being refused —
/// this is a limiter, not a rate limiter. `RateLimitPolicy` answers "too many, come back later";
/// this answers "not yet, you are next".
public actor AdaptiveConcurrencyLimiter {
    /// Permission to run, which must be handed back exactly once.
    public struct Permit: Sendable {
        let id: UUID
        /// Whether every slot was busy when this permit was issued.
        ///
        /// Carried on the permit because it is only true at the moment of admission, and by the time
        /// the request finishes the answer has usually changed.
        let wasSaturated: Bool
    }

    /// What the limiter is doing right now.
    public struct Snapshot: Sendable, Equatable {
        /// How many requests may be in flight.
        public let limit: Int
        /// How many are.
        public let inFlight: Int
        /// How many callers are waiting for a slot.
        public let waiting: Int
        /// The fastest response seen so far.
        public let bestLatencyMilliseconds: Double?
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
        let wasSaturated: Bool
    }

    private var state: AdaptiveConcurrencyState
    private var inFlight = 0
    private var waiters: [Waiter] = []
    private let onChange: (@Sendable (AdaptiveConcurrencyState.Change) -> Void)?

    /// Creates a limiter.
    ///
    /// - Parameters:
    ///   - policy: The limits and how they move.
    ///   - onChange: Called whenever the limit moves, for telemetry.
    public init(
        policy: AdaptiveConcurrencyPolicy,
        onChange: (@Sendable (AdaptiveConcurrencyState.Change) -> Void)? = nil
    ) {
        state = AdaptiveConcurrencyState(policy: policy)
        self.onChange = onChange
    }

    /// What the limiter is doing right now.
    public func snapshot() -> Snapshot {
        Snapshot(
            limit: state.limit,
            inFlight: inFlight,
            waiting: waiters.count,
            bestLatencyMilliseconds: state.bestLatencyMilliseconds
        )
    }

    /// Waits for a slot.
    ///
    /// - Throws: `CancellationError` if the calling task is cancelled while waiting, or
    ///   `NetworkError.timeoutBudgetExceeded` if the policy sets a queue timeout and it elapses
    ///   first.
    public func acquire() async throws -> Permit {
        let saturated = inFlight >= state.limit
        if !saturated {
            inFlight += 1
            return Permit(id: UUID(), wasSaturated: false)
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }

        // Resumed by `admitNext`, which already counted this permit against the limit.
        return Permit(id: id, wasSaturated: true)
    }

    /// Hands a permit back and folds what the request reported into the limit.
    public func release(_ permit: Permit, signal: ConcurrencySignal) {
        inFlight = max(0, inFlight - 1)
        if let change = state.record(signal, wasSaturated: permit.wasSaturated) {
            onChange?(change)
        }
        admitNext()
    }

    // MARK: - Waiting

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        // Both this and `cancelWaiter` run on the actor, so they cannot interleave. That is what
        // makes the ordering safe without tracking cancellations that arrived early: either the
        // cancellation landed before this runs, and the check below sees it, or it lands after, and
        // finds the waiter to cancel.
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        // A slot may have opened while this caller was on its way here.
        if inFlight < state.limit {
            inFlight += 1
            continuation.resume()
            return
        }
        waiters.append(Waiter(id: id, continuation: continuation, wasSaturated: true))
        startTimeoutIfNeeded(for: id)
    }

    private func cancelWaiter(_ id: UUID) {
        // Not waiting means it was already admitted, already cancelled, or never enqueued because
        // `enqueue` saw the cancellation first. All three are done.
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func startTimeoutIfNeeded(for id: UUID) {
        guard let timeout = state.policy.queueTimeoutSeconds else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.expire(id)
        }
    }

    private func expire(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: NetworkError.timeoutBudgetExceeded)
    }

    /// Wakes as many waiters as there is now room for, oldest first.
    ///
    /// Called after every release and after every limit change, because a limit that grew is exactly
    /// as much of an opening as a request that finished.
    private func admitNext() {
        while inFlight < state.limit, !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            inFlight += 1
            waiter.continuation.resume()
        }
    }
}
