import Foundation

/// A failure raised while recording or replaying a cassette.
public enum CassetteError: Error, Equatable, Sendable {
    /// No cassette exists at the path.
    case fileNotFound(path: String)
    /// The file could not be decoded as a cassette.
    case malformedFile(path: String, reason: String)
    /// The file was written by a newer format than this build understands.
    case unsupportedFormatVersion(found: Int, supported: Int, path: String?)
    /// Replay found no recording for a request.
    case noRecordingMatched(method: String, url: String, unconsumedInteractions: Int, totalInteractions: Int)
    /// Every matching recording was already replayed, and the repeat policy forbids reuse.
    case recordingsExhausted(method: String, url: String, matches: Int)
    /// A recording mode was selected without an upstream transport to record from.
    case recordingRequiresUpstream(mode: String)
}

extension CassetteError: LocalizedError {
    /// A human-readable description of the failure, naming what to do next.
    public var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            "No cassette at \(path). Record one first, or use .recordMissing to create it."
        case let .malformedFile(path, reason):
            "The cassette at \(path) could not be read: \(reason)"
        case let .unsupportedFormatVersion(found, supported, path):
            """
            The cassette\(path.map { " at \($0)" } ?? "") uses format version \(found), but this \
            build understands up to \(supported). Update the package, or re-record the cassette.
            """
        case let .noRecordingMatched(method, url, unconsumed, total):
            """
            No recording matched \(method) \(url). The cassette holds \(total) interaction\(total == 1 ? "" : "s"), \
            \(unconsumed) still unplayed. Re-record the scenario, or relax the match rule.
            """
        case let .recordingsExhausted(method, url, matches):
            """
            All \(matches) recording\(matches == 1 ? "" : "s") for \(method) \(url) were already replayed. \
            Record the extra exchange, or use .repeatLast to reuse the final one.
            """
        case let .recordingRequiresUpstream(mode):
            "Mode .\(mode) needs an upstream transport to record from; none was supplied."
        }
    }
}
