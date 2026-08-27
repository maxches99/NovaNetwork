import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An advisory lock two processes can agree on.
///
/// An actor serialises what happens inside one process. An app and its share extension are two
/// processes, and nothing in Swift's concurrency model spans them: both can be inside "read, modify,
/// write" on the same file at the same moment, and the second write wins. That is the failure this
/// exists to prevent.
///
/// It is `flock` on a lock file, taken without blocking and retried, so holding it never parks a
/// cooperative thread. Advisory means both sides have to ask: a process that writes the directory
/// without taking the lock is not stopped by it.
///
/// A value type rather than an actor: it holds no mutable state, because the mutual exclusion lives
/// in the filesystem. Making it an actor would add an isolation boundary for the work closure to
/// cross and protect nothing.
public struct CrossProcessFileLock: Sendable {
    /// What went wrong.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The lock file could not be created or opened.
        case cannotOpen(path: String)
        /// Another process held the lock for longer than the caller was willing to wait.
        case timedOut(path: String)

        public var description: String {
            switch self {
            case let .cannotOpen(path): "The lock file at \(path) could not be opened."
            case let .timedOut(path): "Timed out waiting for the lock at \(path)."
            }
        }
    }

    private let url: URL
    private let pollIntervalSeconds: TimeInterval
    private let timeoutSeconds: TimeInterval

    /// Creates a lock backed by a file.
    ///
    /// - Parameters:
    ///   - url: The lock file. It is created if missing and never written to; only its existence
    ///     and its descriptor matter. Put it inside the directory being protected, in the App Group
    ///     container, so every process that shares the data shares the lock.
    ///   - timeout: How long to wait for another holder before giving up.
    ///   - pollInterval: How often to retry while waiting.
    public init(
        url: URL,
        timeoutSeconds: TimeInterval = 5,
        pollIntervalSeconds: TimeInterval = 0.01
    ) {
        self.url = url
        self.timeoutSeconds = max(0, timeoutSeconds)
        self.pollIntervalSeconds = max(0.001, pollIntervalSeconds)
    }

    /// Runs the work holding the lock, and releases it however the work ends.
    ///
    /// - Throws: ``Failure/timedOut(path:)`` if the lock could not be taken in time, whatever the
    ///   work throws otherwise.
    public func withLock<T: Sendable>(_ work: sending () async throws -> T) async throws -> T {
        let descriptor = try await acquire()
        defer { release(descriptor) }
        return try await work()
    }

    /// Whether the lock is free right now.
    ///
    /// Only ever true in the past tense: another process may take it in the moment between the
    /// answer and the next line. Useful for diagnostics, not for deciding anything.
    public func isAvailable() -> Bool {
        guard let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644) as Int32?, descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(descriptor, LOCK_UN)
        return true
    }

    // MARK: - Taking it

    private func acquire() async throws -> Int32 {
        try createDirectoryIfNeeded()

        let descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw Failure.cannotOpen(path: url.path) }

        // Monotonic, so a clock change while waiting cannot turn a 5 second timeout into an hour.
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(timeoutSeconds * 1_000_000_000)
        while true {
            // Non-blocking, because the blocking form would park the thread this actor is running
            // on and stall every other request in the process while a different process works.
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return descriptor }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                close(descriptor)
                throw Failure.timedOut(path: url.path)
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
            } catch {
                close(descriptor)
                throw error
            }
        }
    }

    private func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func createDirectoryIfNeeded() throws {
        let directory = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
