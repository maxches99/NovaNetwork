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
}
