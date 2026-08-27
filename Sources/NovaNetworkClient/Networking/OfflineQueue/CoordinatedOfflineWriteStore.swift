import Foundation
import NovaNetworkCore

/// An offline write store that takes a cross-process lock around every operation.
///
/// The queue's own store is an actor, which is enough while one process owns it. An app and its
/// share extension are two processes: both can read the same directory, both can decide the queue
/// has three entries, and both can write a fourth over the top of the other's. Wrapping the store
/// rather than rewriting it keeps the queue's behaviour exactly as it was and adds the one thing it
/// was missing.
///
/// The lock is advisory and per-directory, so every process that touches the queue must go through
/// a store wrapped like this one. One that writes the directory directly is not stopped.
///
/// ```swift
/// let directory = try AppGroupContainer.directory(forAppGroup: "group.com.example.app", subdirectory: "offline-queue")
/// let store = CoordinatedOfflineWriteStore(
///     wrapping: DiskOfflineWriteStore(directoryURL: directory),
///     lock: CrossProcessFileLock(url: directory.appendingPathComponent(".lock"))
/// )
/// ```
public actor CoordinatedOfflineWriteStore: OfflineWriteStore {
    private let wrapped: any OfflineWriteStore
    private let lock: CrossProcessFileLock

    /// Wraps a store in a lock.
    ///
    /// - Parameters:
    ///   - wrapped: The store doing the actual work, usually a `DiskOfflineWriteStore` pointed at a
    ///     shared container.
    ///   - lock: The lock every process sharing that directory agrees on. Its file belongs inside
    ///     the directory being protected.
    public init(wrapping wrapped: any OfflineWriteStore, lock: CrossProcessFileLock) {
        self.wrapped = wrapped
        self.lock = lock
    }

    // MARK: - Writing

    public func enqueue(request: APIRequest, requestKey: String, now: Date) async throws -> QueuedWriteReceipt {
        try await lock.withLock {
            try await wrapped.enqueue(request: request, requestKey: requestKey, now: now)
        }
    }

    public func markReplaying(queueID: String, attempt: Int, now: Date) async {
        await withLockIgnoringContention {
            await wrapped.markReplaying(queueID: queueID, attempt: attempt, now: now)
        }
    }

    public func markRetryWaiting(
        queueID: String,
        attempt: Int,
        reason: String,
        nextRetryAt: Date,
        now: Date
    ) async {
        await withLockIgnoringContention {
            await wrapped.markRetryWaiting(
                queueID: queueID,
                attempt: attempt,
                reason: reason,
                nextRetryAt: nextRetryAt,
                now: now
            )
        }
    }

    public func markSucceeded(queueID: String) async {
        await withLockIgnoringContention {
            await wrapped.markSucceeded(queueID: queueID)
        }
    }

    public func markDeadLetter(queueID: String, reason: String, now: Date) async {
        await withLockIgnoringContention {
            await wrapped.markDeadLetter(queueID: queueID, reason: reason, now: now)
        }
    }

    public func drop(queueID: String) async -> Bool {
        await withLockIgnoringContention(default: false) {
            await wrapped.drop(queueID: queueID)
        }
    }

    public func dropAll() async -> Int {
        await withLockIgnoringContention(default: 0) {
            await wrapped.dropAll()
        }
    }

    // MARK: - Reading

    public func nextBatch(limit: Int, now: Date) async -> [OfflineWriteStoreEntry] {
        await withLockIgnoringContention(default: []) {
            await wrapped.nextBatch(limit: limit, now: now)
        }
    }

    public func depth(now: Date) async -> Int {
        await withLockIgnoringContention(default: 0) {
            await wrapped.depth(now: now)
        }
    }

    public func snapshot(now: Date) async -> [OfflineWriteStoreEntry] {
        await withLockIgnoringContention(default: []) {
            await wrapped.snapshot(now: now)
        }
    }

    // MARK: - Plumbing

    /// Most of `OfflineWriteStore` cannot report a failure: the protocol's methods do not throw,
    /// because the queue is meant to degrade rather than break. Losing the lock is therefore
    /// reported the same way the underlying store reports a missing file — by doing nothing and
    /// answering with the empty result — rather than by crashing a share extension.
    private func withLockIgnoringContention(_ work: sending () async -> Void) async {
        _ = try? await lock.withLock { await work() }
    }

    private func withLockIgnoringContention<T: Sendable>(
        default fallback: T,
        _ work: sending () async -> T
    ) async -> T {
        (try? await lock.withLock { await work() }) ?? fallback
    }
}
