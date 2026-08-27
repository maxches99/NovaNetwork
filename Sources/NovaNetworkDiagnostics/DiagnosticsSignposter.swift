import Foundation

#if canImport(os)
import os
#endif

/// Marks request intervals for Instruments.
///
/// Where `os` is unavailable — Linux, or a build that opts out — every method is a no-op, so the
/// recorder can call it unconditionally and nothing else has to care which platform it is on.
struct DiagnosticsSignposter: Sendable {
    /// Whether signposts are emitted at all.
    let isEnabled: Bool

    #if canImport(os)
    private let log = OSLog(subsystem: "com.novanetwork.diagnostics", category: "requests")
    #endif

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    /// Opens an interval for a request, returning the identifier that closes it.
    func begin(key: String, method: String, url: String) -> UInt64? {
        guard isEnabled else { return nil }

        #if canImport(os)
        let id = UInt64.random(in: 1...UInt64.max)
        if #available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *) {
            os_signpost(
                .begin,
                log: log,
                name: "request",
                signpostID: OSSignpostID(id),
                "%{public}@ %{public}@ key=%{public}@",
                method,
                url,
                key
            )
        }
        return id
        #else
        return nil
        #endif
    }

    /// Closes the interval opened by ``begin(key:method:url:)``.
    func end(_ id: UInt64?, outcome: String, durationMilliseconds: Double?) {
        guard isEnabled, let id else { return }

        #if canImport(os)
        if #available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *) {
            os_signpost(
                .end,
                log: log,
                name: "request",
                signpostID: OSSignpostID(id),
                "%{public}@ %{public}.2f ms",
                outcome,
                durationMilliseconds ?? 0
            )
        }
        #endif
    }

    /// Marks a retry as a point event inside the enclosing interval.
    func emitRetry(_ id: UInt64?, attempt: Int, delayMilliseconds: Double, reason: String) {
        guard isEnabled, let id else { return }

        #if canImport(os)
        if #available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *) {
            os_signpost(
                .event,
                log: log,
                name: "request",
                signpostID: OSSignpostID(id),
                "retry attempt=%{public}d delay=%{public}.0fms reason=%{public}@",
                attempt,
                delayMilliseconds,
                reason
            )
        }
        #endif
    }
}
