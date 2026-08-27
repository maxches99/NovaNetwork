import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

// Requirements: FR-36 (publishing a staged file replaces the destination), FR-37 (it works whether
// or not the destination already exists), FR-38 (the staged file is gone afterwards),
// EC-31…EC-33 (a missing source, an unwritable destination, a name that needs no directory).
// Tests: T-15.1…T-15.7.

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func contents(of url: URL) -> String? {
    (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
}

@Suite
struct AtomicFileReplacementTests {
    @Test
    func itPublishesOverAnExistingDestination() throws {
        // This is the case that was broken: `replaceItemAt` could remove the destination and leave
        // nothing behind, which is how a queue holding one entry came back holding none.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("entry.json")
        let staged = directory.appendingPathComponent("entry.json.partial")
        try Data("old".utf8).write(to: destination)
        try Data("new".utf8).write(to: staged)

        try AtomicFileReplacement.replaceItem(at: destination, with: staged)

        #expect(contents(of: destination) == "new")
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test
    func itPublishesWhenThereIsNoDestinationYet() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("entry.json")
        let staged = directory.appendingPathComponent("entry.json.partial")
        try Data("first".utf8).write(to: staged)

        try AtomicFileReplacement.replaceItem(at: destination, with: staged)

        #expect(contents(of: destination) == "first")
        #expect(FileManager.default.fileExists(atPath: staged.path) == false)
    }

    @Test
    func repeatedPublishingKeepsTheLatestAndLeavesNothingBehind() throws {
        // The write path this replaced published on every mutation of an entry, so the interesting
        // property is that doing it many times leaves exactly one file.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("entry.json")

        for generation in 1...5 {
            let staged = directory.appendingPathComponent("entry.json.partial")
            try Data("generation \(generation)".utf8).write(to: staged)
            try AtomicFileReplacement.replaceItem(at: destination, with: staged)
        }

        #expect(contents(of: destination) == "generation 5")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining == ["entry.json"])
    }

    @Test
    func aMissingStagedFileIsReportedRatherThanIgnored() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("entry.json")
        let missing = directory.appendingPathComponent("nothing.partial")

        #expect(throws: (any Error).self) {
            try AtomicFileReplacement.replaceItem(at: destination, with: missing)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test
    func aFailureNamesTheFileAndTheReason() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        try? Data("x".utf8).write(to: staged)
        // A destination inside a directory that does not exist cannot be renamed into.
        let destination = directory.appendingPathComponent("missing-dir/entry.json")

        do {
            try AtomicFileReplacement.replaceItem(at: destination, with: staged)
            Issue.record("publishing into a missing directory should have failed")
        } catch let error as NSError {
            #expect(error.domain == NSPOSIXErrorDomain)
            #expect(error.localizedDescription.contains("entry.json"))
            #expect(error.userInfo[NSFilePathErrorKey] as? String == destination.path)
        }
    }

    @Test
    func theDestinationIsNeverMissingBetweenGenerations() async throws {
        // Atomicity is what this exists for. A reader interleaved with the publisher must always
        // see a whole file -- either the old one or the new one, never neither.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("entry.json")
        try Data("generation 0".utf8).write(to: destination)

        let observations = Observations()
        let reader = Task.detached {
            for _ in 0..<400 {
                observations.record(contents(of: destination))
            }
        }

        for generation in 1...40 {
            let staged = directory.appendingPathComponent("entry.json.partial")
            try Data("generation \(generation)".utf8).write(to: staged)
            try AtomicFileReplacement.replaceItem(at: destination, with: staged)
        }
        await reader.value

        let seen = observations.all()
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { $0?.hasPrefix("generation ") == true }, "a reader saw a missing or partial file")
    }
}

/// A thread-safe sink, because the reader runs on another task.
private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []

    func record(_ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    func all() -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
