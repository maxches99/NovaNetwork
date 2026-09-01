import Foundation
import Testing

/// What the host platform's Foundation can actually do, for tests that depend on it.
///
/// These are not features the package chose to make Apple-only. They are places where
/// swift-corelibs-foundation is a different implementation of `URLSession`, and a test written
/// against Apple's behaviour cannot be run there and cannot be rewritten into something meaningful
/// either. Tests that need them are skipped with a reason rather than deleted, so the gap shows up
/// in the test output instead of quietly not existing.
enum PlatformSupport {
    /// Whether `URLSession` behaves the way these tests' `URLProtocol` doubles assume: ranged and
    /// resumed requests reaching the protocol, responses delivered in more than one chunk, and
    /// background sessions existing at all.
    static let hasAppleURLSessionBehaviour: Bool = {
        #if canImport(Darwin)
        return true
        #else
        return false
        #endif
    }()

    /// The reason attached to anything skipped because of the above. Typed as `Comment` because
    /// that is what the trait takes; a `String` does not convert.
    static let urlSessionReason: Comment = "Depends on Apple's URLSession behaviour; swift-corelibs-foundation's differs."

    /// The reason for the one skip that is not about a difference in behaviour but about a
    /// deadlock. Cancelling a `URLSessionTask` from Swift concurrency while its `URLProtocol` is
    /// still inside `startLoading` deadlocks swift-corelibs-foundation, two locks taken in opposite
    /// orders:
    ///
    /// - the session's work queue, completing the task, enqueues the awaiting `AsyncTask` and
    ///   blocks on that task's status-record lock;
    /// - `swift_task_cancel` holds the status-record lock and, from inside it, calls
    ///   `URLSessionTask.cancel()`, which blocks on the work queue with `DispatchQueue.sync`.
    ///
    /// Neither side can give way, and the process stops rather than the test failing. Apple's
    /// URLSession does not take the work queue synchronously from the cancellation path, so the
    /// same test finishes there in milliseconds.
    static let urlSessionCancellationDeadlockReason: Comment = "Cancelling a URLSession task mid-`startLoading` deadlocks swift-corelibs-foundation."
}
