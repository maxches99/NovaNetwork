import Foundation
import NovaNetworkClient

/// A deterministic ``RetryClock`` whose time only moves when explicitly advanced, for testing
/// timed sequences (retry backoff, reconnect delays, offline queue scheduling) without real
/// delays or timing-dependent flakiness.
///
/// Unlike `TestRetryRandom`-paired clocks that never block, `VirtualClock` genuinely suspends
/// callers of ``sleep(nanoseconds:)`` until virtual time reaches their deadline, so a test can
/// assert on state *between* two scheduled events by advancing only partway.
///
/// ```swift
/// let clock = VirtualClock()
/// let task = Task { try await clock.sleep(nanoseconds: 5_000_000_000) }
/// await clock.advance(by: 3_000_000_000)
/// // task is still suspended here
/// await clock.advance(by: 2_000_000_000)
/// try await task.value // resumes
/// ```
public actor VirtualClock: RetryClock {
    private final class Waiter {
        let id: UUID
        let deadline: UInt64
        var continuation: CheckedContinuation<Void, any Error>?

        init(id: UUID, deadline: UInt64, continuation: CheckedContinuation<Void, any Error>) {
            self.id = id
            self.deadline = deadline
            self.continuation = continuation
        }
    }

    private var now: UInt64 = 0
    private var waiters: [Waiter] = []

    /// Creates a virtual clock starting at time zero.
    public init() {}

    /// The clock's current virtual time, in nanoseconds since creation.
    public func currentTime() -> UInt64 {
        now
    }

    /// Number of callers currently suspended in ``sleep(nanoseconds:)``.
    public func pendingSleepCount() -> Int {
        waiters.count
    }

    public func sleep(nanoseconds: UInt64) async throws {
        let deadline = now &+ nanoseconds
        guard deadline > now else {
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiters.append(Waiter(id: id, deadline: deadline, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    /// Advances virtual time by `nanoseconds`, resuming any sleepers whose deadline has now
    /// elapsed, in deadline order.
    public func advance(by nanoseconds: UInt64) {
        now &+= nanoseconds
        resolveElapsedWaiters()
    }

    /// Advances directly to the earliest pending deadline, resuming it (and any others sharing
    /// that same deadline).
    ///
    /// - Returns: The amount of virtual time advanced, or `nil` if nothing is pending.
    @discardableResult
    public func advanceToNextDeadline() -> UInt64? {
        guard let nextDeadline = waiters.map(\.deadline).min() else { return nil }
        let delta = nextDeadline - now
        advance(by: delta)
        return delta
    }

    private func resolveElapsedWaiters() {
        let elapsed = waiters.filter { $0.deadline <= now }
        guard !elapsed.isEmpty else { return }
        waiters.removeAll { $0.deadline <= now }
        for waiter in elapsed.sorted(by: { $0.deadline < $1.deadline }) {
            waiter.continuation?.resume()
            waiter.continuation = nil
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation?.resume(throwing: CancellationError())
        waiter.continuation = nil
    }
}
