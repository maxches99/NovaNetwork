import Foundation
import NovaNetworkDiagnostics
import Observation

/// One opened trace.
///
/// The recorder is the same actor a live app installs; loading a file into it is what lets the
/// panel read a file with no idea that is what it is doing.
@Observable
@MainActor
final class InspectorModel {
    /// The recorder the panel reads.
    let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 10_000))

    /// The name of the open file, or `nil` when nothing is open yet.
    private(set) var fileName: String?
    /// How many requests the file held.
    private(set) var requestCount = 0
    /// What went wrong with the last attempt to open something.
    private(set) var failure: String?

    /// Reads a HAR file into the recorder.
    ///
    /// - Parameter url: The file to read. A security-scoped resource is opened and closed around
    ///   the read, so a file chosen through the open panel works in a sandboxed build too.
    func open(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let records = try HARImporter().import(try Data(contentsOf: url))
            guard !records.isEmpty else {
                failure = "\(url.lastPathComponent) is a HAR log with no entries in it."
                return
            }
            await recorder.load(records)
            fileName = url.lastPathComponent
            requestCount = records.count
            failure = nil
        } catch let error as HARImporter.Failure {
            failure = "\(url.lastPathComponent): \(error.description)"
        } catch {
            failure = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Dismisses the current error without closing the trace behind it.
    func clearFailure() {
        failure = nil
    }
}
