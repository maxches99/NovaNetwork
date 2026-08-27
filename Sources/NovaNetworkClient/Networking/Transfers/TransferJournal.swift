import NovaNetworkCore
import Foundation

/// Summary of a transfer journal recovery scan.
public struct TransferJournalRecoveryReport: Sendable, Equatable {
    /// Number of durable records inspected.
    public let scannedRecords: Int
    /// Number of compatible snapshots restored.
    public let recoveredRecords: Int
    /// Number of malformed records skipped.
    public let skippedCorruptedRecords: Int
    /// Number of records using an unsupported schema skipped.
    public let skippedIncompatibleRecords: Int
    /// Number of abandoned temporary records removed.
    public let orphanedTemporaryRecords: Int

    /// Creates a transfer journal recovery report.
    public init(
        scannedRecords: Int,
        recoveredRecords: Int,
        skippedCorruptedRecords: Int,
        skippedIncompatibleRecords: Int,
        orphanedTemporaryRecords: Int
    ) {
        self.scannedRecords = max(0, scannedRecords)
        self.recoveredRecords = max(0, recoveredRecords)
        self.skippedCorruptedRecords = max(0, skippedCorruptedRecords)
        self.skippedIncompatibleRecords = max(0, skippedIncompatibleRecords)
        self.orphanedTemporaryRecords = max(0, orphanedTemporaryRecords)
    }

    /// Total count of records that could not be restored.
    public var skippedTotal: Int {
        skippedCorruptedRecords + skippedIncompatibleRecords + orphanedTemporaryRecords
    }
}

/// Snapshots and recovery diagnostics returned by a transfer journal load.
public struct TransferJournalLoadResult: Sendable, Equatable {
    /// Compatible snapshots sorted by creation time and identity.
    public let snapshots: [ManagedTransferSnapshot]
    /// Diagnostics for malformed, incompatible, or temporary records.
    public let recoveryReport: TransferJournalRecoveryReport

    /// Creates a journal load result.
    public init(snapshots: [ManagedTransferSnapshot], recoveryReport: TransferJournalRecoveryReport) {
        self.snapshots = snapshots
        self.recoveryReport = recoveryReport
    }
}

/// Durable storage contract for managed transfer snapshots.
public protocol TransferJournal: Sendable {
    /// Atomically inserts or replaces one snapshot.
    func upsert(_ snapshot: ManagedTransferSnapshot) async throws

    /// Removes a snapshot by identity.
    func remove(id: TransferID) async throws

    /// Loads every compatible snapshot while isolating malformed records.
    func load() async throws -> TransferJournalLoadResult
}

/// Failures produced by a transfer journal implementation.
public enum TransferJournalError: Error, Sendable, Equatable {
    /// Journal directory or file I/O failed.
    case persistenceFailure
}

/// Versioned, per-record JSON transfer journal using atomic filesystem replacement.
public actor DiskTransferJournal: TransferJournal {
    private struct RecordEnvelope: Codable {
        let schemaVersion: Int
        let snapshot: ManagedTransferSnapshot
    }

    private struct RecordHeader: Decodable {
        let schemaVersion: Int
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let schemaVersion: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a disk-backed transfer journal.
    ///
    /// The journal never persists request headers or credentials because snapshots contain only
    /// credential-free request metadata.
    ///
    /// - Parameters:
    ///   - directoryURL: Private directory containing one record per transfer.
    ///   - fileManager: Filesystem implementation used by the journal.
    ///   - schemaVersion: Record schema version. Values below one are clamped to one.
    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        schemaVersion: Int = 1
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.schemaVersion = max(1, schemaVersion)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    /// Atomically inserts or replaces one snapshot.
    public func upsert(_ snapshot: ManagedTransferSnapshot) async throws {
        try ensureDirectory()
        do {
            let envelope = RecordEnvelope(schemaVersion: schemaVersion, snapshot: snapshot)
            let data = try encoder.encode(envelope)
            let finalURL = recordURL(for: snapshot.id)
            let temporaryURL = finalURL.appendingPathExtension("partial")
            // Stage through an explicitly named `.partial` file rather than
            // `Data.write(options: .atomic)`'s own hidden temp file, whose name Foundation picks
            // unpredictably (e.g. `.dat.nosync<hex>.<random>`) and which `load()`'s orphan cleanup
            // would never recognize. Publishing this known path with `AtomicFileReplacement`
            // keeps the final write atomic while ensuring a crash between staging and publish
            // leaves a `<record>.transfer.json.partial` file the next `load()` will find and remove.
            try data.write(to: temporaryURL)
            try AtomicFileReplacement.replaceItem(at: finalURL, with: temporaryURL, fileManager: fileManager)
        } catch {
            throw TransferJournalError.persistenceFailure
        }
    }

    /// Removes a snapshot by identity.
    public func remove(id: TransferID) async throws {
        let url = recordURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw TransferJournalError.persistenceFailure
        }
    }

    /// Loads every compatible snapshot while isolating malformed records.
    public func load() async throws -> TransferJournalLoadResult {
        try ensureDirectory()
        let orphanedTemporaryRecords = cleanupOrphanedTemporaryRecords()
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            .filter { $0.lastPathComponent.hasSuffix(".transfer.json") }
        } catch {
            throw TransferJournalError.persistenceFailure
        }

        var snapshots: [ManagedTransferSnapshot] = []
        var corrupted = 0
        var incompatible = 0

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let header = try decoder.decode(RecordHeader.self, from: data)
                guard header.schemaVersion == schemaVersion else {
                    incompatible += 1
                    continue
                }
                let envelope = try decoder.decode(RecordEnvelope.self, from: data)
                snapshots.append(envelope.snapshot)
            } catch {
                corrupted += 1
            }
        }

        snapshots.sort {
            if $0.createdAt == $1.createdAt {
                return $0.id.rawValue < $1.id.rawValue
            }
            return $0.createdAt < $1.createdAt
        }

        return TransferJournalLoadResult(
            snapshots: snapshots,
            recoveryReport: .init(
                scannedRecords: files.count,
                recoveredRecords: snapshots.count,
                skippedCorruptedRecords: corrupted,
                skippedIncompatibleRecords: incompatible,
                orphanedTemporaryRecords: orphanedTemporaryRecords
            )
        )
    }

    private func ensureDirectory() throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw TransferJournalError.persistenceFailure
        }
    }

    private func recordURL(for id: TransferID) -> URL {
        directoryURL.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).transfer.json")
    }

    private func cleanupOrphanedTemporaryRecords() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        let temporaryFiles = files.filter { $0.lastPathComponent.hasSuffix(".transfer.json.partial") }
        for file in temporaryFiles {
            try? fileManager.removeItem(at: file)
        }
        return temporaryFiles.count
    }
}
