import Foundation

/// Where an app and its extensions can keep the same files.
///
/// An extension is a separate process with its own container. A queued write made in a share
/// extension is invisible to the app unless both are looking at the same directory, and the only
/// directory both can see is the App Group container.
///
/// This resolves it and says clearly when it cannot, because the failure — a missing entitlement —
/// looks exactly like an empty queue otherwise.
public enum AppGroupContainer {
    /// Why the container could not be resolved.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The system does not recognise the identifier for this process.
        ///
        /// Almost always the entitlement: every target that shares the data — the app *and* each
        /// extension — needs the App Group in its `com.apple.security.application-groups`.
        case unavailable(identifier: String)
        /// App Groups are an Apple platform feature.
        case unsupportedPlatform

        public var description: String {
            switch self {
            case let .unavailable(identifier):
                "The app group \(identifier) is not available to this process. Check that every target sharing the data lists it under com.apple.security.application-groups."
            case .unsupportedPlatform:
                "App groups are available on Apple platforms only."
            }
        }
    }

    /// The container shared by every target entitled to the group.
    ///
    /// Platforms disagree about the unentitled case, and the difference matters when adopting this:
    /// iOS returns `nil`, which becomes ``Failure/unavailable(identifier:)`` here. macOS returns a
    /// path under `~/Library/Group Containers` whether or not the process is entitled, so a missing
    /// entitlement is only discovered when something tries to write there. ``directory(forAppGroup:subdirectory:)``
    /// is the call that finds out, because creating the directory is what fails.
    ///
    /// - Parameter identifier: The App Group identifier, such as `group.com.example.app`.
    public static func url(forAppGroup identifier: String) throws -> URL {
        #if canImport(Darwin)
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw Failure.unavailable(identifier: identifier)
        }
        return url
        #else
        throw Failure.unsupportedPlatform
        #endif
    }

    /// A subdirectory of the shared container, created if it is not there yet.
    ///
    /// - Parameters:
    ///   - identifier: The App Group identifier.
    ///   - subdirectory: A path under the container, such as `"offline-queue"`. Keeping each kind of
    ///     shared data in its own subdirectory is what lets one lock protect one thing.
    public static func directory(forAppGroup identifier: String, subdirectory: String) throws -> URL {
        let directory = try url(forAppGroup: identifier).appendingPathComponent(subdirectory, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}
