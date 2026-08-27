import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Publishes a staged file over its destination, atomically, on every platform.
///
/// `FileManager.replaceItemAt` is the obvious call and is not dependable on
/// swift-corelibs-foundation: it can remove the destination and leave nothing in its place. That is
/// how an offline queue holding one entry came back holding none — the entry file was published
/// with `replaceItemAt`, and after it the directory was empty. `moveItem` is not an alternative
/// either, since it refuses to overwrite.
///
/// `rename(2)` does exactly what is wanted and is atomic on both platforms: a reader sees either
/// the old file or the new one, never a partial write and never nothing.
enum AtomicFileReplacement {
    /// Moves `source` onto `destination`, replacing whatever is there.
    ///
    /// - Parameters:
    ///   - destination: Where the file should end up. It may or may not already exist.
    ///   - source: The staged file. It no longer exists afterwards, whichever path was taken.
    ///   - fileManager: Used only by the cross-device fallback.
    /// - Throws: An `NSPOSIXErrorDomain` error carrying the `errno` that stopped it.
    static func replaceItem(
        at destination: URL,
        with source: URL,
        fileManager: FileManager = .default
    ) throws {
        if rename(source.path, destination.path) == 0 { return }

        let code = errno
        // rename cannot cross filesystems. Everything else is a real failure.
        guard code == EXDEV else { throw failure(code, source: source, destination: destination) }

        try replaceAcrossDevices(at: destination, with: source, fileManager: fileManager)
    }

    /// The staged file is on another filesystem, so it has to be copied next to the destination
    /// first. The copy is what gets renamed into place, which keeps the publish itself atomic.
    private static func replaceAcrossDevices(
        at destination: URL,
        with source: URL,
        fileManager: FileManager
    ) throws {
        let staged = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).staging-\(UUID().uuidString)")

        try fileManager.copyItem(at: source, to: staged)
        guard rename(staged.path, destination.path) == 0 else {
            let code = errno
            try? fileManager.removeItem(at: staged)
            throw failure(code, source: source, destination: destination)
        }
        try? fileManager.removeItem(at: source)
    }

    private static func failure(_ code: Int32, source: URL, destination: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "Could not publish \(source.lastPathComponent) as \(destination.lastPathComponent): \(String(cString: strerror(code))).",
                NSFilePathErrorKey: destination.path,
            ]
        )
    }
}
