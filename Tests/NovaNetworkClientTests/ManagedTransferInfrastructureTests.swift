import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-TR-2...4, DR-1...4, EC-6...8, AR-4.

private func makeManagedSnapshot(
    id: String,
    kind: ManagedTransferKind = .download,
    state: ManagedTransferState = .queued,
    execution: TransferExecutionMode = .foreground,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ManagedTransferSnapshot {
    ManagedTransferSnapshot(
        id: TransferID(rawValue: id),
        kind: kind,
        state: state,
        createdAt: createdAt,
        updatedAt: createdAt,
        requestURL: URL(string: "https://example.com/\(id)")!,
        method: kind == .download ? "GET" : "POST",
        options: .init(execution: execution)
    )
}

private final class ManagedTelemetryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var contexts: [TelemetryManagedTransferContext] = []
    func append(_ context: TelemetryManagedTransferContext) {
        lock.lock()
        contexts.append(context)
        lock.unlock()
    }
    func values() -> [TelemetryManagedTransferContext] {
        lock.lock()
        defer { lock.unlock() }
        return contexts
    }
}

@Suite(.serialized)
struct ManagedTransferInfrastructureTests {
    @Test
    func diskJournalRoundTripsCheckpointAndNeverSerializesHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        let snapshot = ManagedTransferSnapshot(
            id: TransferID(rawValue: "checkpoint"),
            kind: .download,
            state: .suspended,
            completedBytes: 99,
            totalBytes: 200,
            requestURL: URL(string: "https://example.com/file")!,
            method: "GET",
            destinationURL: URL(fileURLWithPath: "/tmp/file"),
            partialFileURL: URL(fileURLWithPath: "/tmp/file.partial"),
            validator: .init(eTag: "secret-looking-etag"),
            sessionIdentifier: "com.example.background",
            taskIdentifier: 11
        )

        try await journal.upsert(snapshot)
        let loaded = try await journal.load()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let serialized = try String(decoding: Data(contentsOf: #require(files.first)), as: UTF8.self)

        #expect(loaded.snapshots == [snapshot])
        #expect(loaded.recoveryReport.recoveredRecords == 1)
        #expect(!serialized.localizedCaseInsensitiveContains("Authorization"))
        #expect(!serialized.localizedCaseInsensitiveContains("Cookie"))
    }

    @Test
    func diskJournalIsolatesCorruptAndIncompatibleRecordsAndCleansTemporaryFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        try await journal.upsert(makeManagedSnapshot(id: "valid"))
        try Data("not-json".utf8).write(to: directory.appendingPathComponent("corrupt.transfer.json"))
        try Data("{\"schemaVersion\":99,\"snapshot\":{}}".utf8)
            .write(to: directory.appendingPathComponent("future.transfer.json"))
        try Data().write(to: directory.appendingPathComponent("abandoned.transfer.json.partial"))

        let loaded = try await journal.load()

        #expect(loaded.snapshots.map(\.id.rawValue) == ["valid"])
        #expect(loaded.recoveryReport.scannedRecords == 3)
        #expect(loaded.recoveryReport.skippedCorruptedRecords == 1)
        #expect(loaded.recoveryReport.skippedIncompatibleRecords == 1)
        #expect(loaded.recoveryReport.orphanedTemporaryRecords == 1)
        #expect(loaded.recoveryReport.skippedTotal == 3)
    }

    @Test
    func diskJournalRecoversFromWriteInterruptedBetweenStagingAndPublish() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-interrupted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        try await journal.upsert(makeManagedSnapshot(id: "already-published"))

        // Simulate the process dying after `upsert` stages its `.partial` file but before the
        // final atomic publish -- the exact filename `upsert` itself would have staged.
        let interruptedID = TransferID(rawValue: "crashed-mid-upsert")
        let stagedURL = directory.appendingPathComponent("\(SHA256Util.hex(interruptedID.rawValue)).transfer.json.partial")
        try Data("{\"schemaVersion\":1,\"snapshot\":{}}".utf8).write(to: stagedURL)

        let loaded = try await journal.load()

        #expect(loaded.snapshots.map(\.id.rawValue) == ["already-published"])
        #expect(loaded.recoveryReport.orphanedTemporaryRecords == 1)
        #expect(!FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @Test
    func diskJournalUpsertLeavesNoStagingFileOnSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-no-leak-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        let snapshot = makeManagedSnapshot(id: "clean")

        try await journal.upsert(snapshot)
        try await journal.upsert(makeManagedSnapshot(id: "clean", state: .completed)) // exercise the replace path too

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent) == ["\(SHA256Util.hex(snapshot.id.rawValue)).transfer.json"])
    }

    @Test
    func diskJournalRemovesPersistedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        let snapshot = makeManagedSnapshot(id: "remove")

        try await journal.upsert(snapshot)
        try await journal.remove(id: snapshot.id)

        #expect(try await journal.load().snapshots.isEmpty)
    }

    @Test
    func coordinatorEmitsExactlyOneTerminalEventAndRejectsFurtherTransition() async throws {
        let coordinator = ManagedTransferCoordinator()
        let snapshot = makeManagedSnapshot(id: "terminal")
        try await coordinator.register(snapshot)
        let handle = try await coordinator.handle(for: snapshot.id)
        try await coordinator.transition(id: snapshot.id, to: .preparing)
        try await coordinator.transition(id: snapshot.id, to: .transferring)
        try await coordinator.transition(id: snapshot.id, to: .finalizing)
        try await coordinator.transition(id: snapshot.id, to: .completed, completedBytes: 10, totalBytes: 10)

        var terminalEvents = 0
        for await event in handle.events {
            if case .completed = event { terminalEvents += 1 }
            if case .failed = event { terminalEvents += 1 }
            if case .cancelled = event { terminalEvents += 1 }
        }

        #expect(terminalEvents == 1)
        await #expect(throws: ManagedTransferError.terminalStateAlreadyReached(snapshot.id)) {
            try await coordinator.transition(id: snapshot.id, to: .failed)
        }
    }

    @Test
    func coordinatorCancellationIsIdempotentAndUpdatesHandleSnapshot() async throws {
        let coordinator = ManagedTransferCoordinator()
        let snapshot = makeManagedSnapshot(id: "cancel")
        try await coordinator.register(snapshot)
        let handle = try await coordinator.handle(for: snapshot.id)

        await handle.cancel()
        await handle.cancel()

        #expect(await handle.snapshot()?.state == .cancelled)
    }

    @Test
    func coordinatorRestoresNonterminalSnapshotsIntoRestoringState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        try await journal.upsert(makeManagedSnapshot(id: "active", state: .transferring))
        try await journal.upsert(makeManagedSnapshot(id: "done", state: .completed))
        let coordinator = ManagedTransferCoordinator(journal: journal)

        let restored = try await coordinator.restore()

        #expect(restored.snapshots.first(where: { $0.id.rawValue == "active" })?.state == .restoring)
        #expect(restored.snapshots.first(where: { $0.id.rawValue == "done" })?.state == .completed)
    }

    @Test
    func removePersistsOnlyForTerminalSnapshotsAndClearsTheJournal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-journal-coordinator-remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = DiskTransferJournal(directoryURL: directory)
        let coordinator = ManagedTransferCoordinator(journal: journal)
        let snapshot = makeManagedSnapshot(id: "removable")
        try await coordinator.register(snapshot)
        try await coordinator.transition(id: snapshot.id, to: .preparing)
        try await coordinator.transition(id: snapshot.id, to: .transferring)
        try await coordinator.transition(id: snapshot.id, to: .finalizing)
        try await coordinator.transition(id: snapshot.id, to: .completed, completedBytes: 1, totalBytes: 1)

        let removed = try await coordinator.remove(id: snapshot.id)

        #expect(removed)
        #expect(await coordinator.snapshot(id: snapshot.id) == nil)
        #expect(try await journal.load().snapshots.isEmpty)
    }

    @Test
    func restoreWithoutAJournalReturnsInMemorySnapshotsUnchanged() async throws {
        let coordinator = ManagedTransferCoordinator()
        let snapshot = makeManagedSnapshot(id: "memory-only", state: .transferring)
        try await coordinator.register(snapshot)

        let restored = try await coordinator.restore()

        #expect(restored.snapshots.map(\.id.rawValue) == ["memory-only"])
        #expect(restored.snapshots.first?.state == .transferring)
        #expect(restored.recoveryReport.scannedRecords == 0)
        #expect(restored.recoveryReport.recoveredRecords == 1)
    }

    @Test
    func handleFinishesImmediatelyForTerminalSnapshotAndAutoCancelsOnDrop() async throws {
        let coordinator = ManagedTransferCoordinator()
        let terminal = makeManagedSnapshot(id: "already-terminal", state: .queued)
        try await coordinator.register(terminal)
        try await coordinator.transition(id: terminal.id, to: .cancelled)

        let terminalHandle = try await coordinator.handle(for: terminal.id)
        var terminalEventCount = 0
        for await _ in terminalHandle.events { terminalEventCount += 1 }
        #expect(terminalEventCount == 1)

        let autoCancel = ManagedTransferSnapshot(
            id: TransferID(rawValue: "auto-cancel"),
            kind: .download,
            state: .queued,
            requestURL: URL(string: "https://example.com/auto-cancel")!,
            method: "GET",
            options: .init(consumerTerminationPolicy: .cancelTransfer)
        )
        try await coordinator.register(autoCancel)
        do {
            let handle = try await coordinator.handle(for: autoCancel.id)
            for await _ in handle.events { break }
        }
        // Consuming the handle's stream is what triggers `onTermination`, which runs the
        // auto-cancel policy asynchronously; give that detached Task a turn to run.
        for _ in 0..<50 where await coordinator.snapshot(id: autoCancel.id)?.state != .cancelled {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await coordinator.snapshot(id: autoCancel.id)?.state == .cancelled)
    }

    @Test
    func reconciliationReportsMatchesOrphansAndDuplicateConflicts() async throws {
        let coordinator = ManagedTransferCoordinator()
        let execution = TransferExecutionMode.background(sessionIdentifier: "session")
        for id in ["match", "missing", "duplicate"] {
            try await coordinator.register(makeManagedSnapshot(id: id, execution: execution))
        }
        let tasks = [
            BackgroundTransferTaskDescriptor(
                transferID: .init(rawValue: "match"), sessionIdentifier: "session", taskIdentifier: 1
            ),
            BackgroundTransferTaskDescriptor(
                transferID: .init(rawValue: "duplicate"), sessionIdentifier: "session", taskIdentifier: 2
            ),
            BackgroundTransferTaskDescriptor(
                transferID: .init(rawValue: "duplicate"), sessionIdentifier: "session", taskIdentifier: 3
            ),
            BackgroundTransferTaskDescriptor(
                transferID: .init(rawValue: "orphan-task"), sessionIdentifier: "session", taskIdentifier: 4
            )
        ]

        let report = try await coordinator.reconcile(liveTasks: tasks)

        #expect(report.reconciledTransferIDs.map(\.rawValue) == ["match"])
        #expect(report.orphanedSnapshotIDs.map(\.rawValue) == ["missing"])
        #expect(report.conflictingTransferIDs.map(\.rawValue) == ["duplicate"])
        #expect(report.orphanedTasks.map(\.transferID.rawValue) == ["orphan-task"])
    }

    @Test
    func invalidTransitionAndCheckpointKindReturnTypedErrors() async throws {
        let coordinator = ManagedTransferCoordinator()
        let download = makeManagedSnapshot(id: "invalid")
        try await coordinator.register(download)

        await #expect(throws: ManagedTransferError.invalidStateTransition(from: .queued, to: .completed)) {
            try await coordinator.transition(id: download.id, to: .completed)
        }
        await #expect(throws: ManagedTransferError.invalidResumeCheckpoint) {
            try await coordinator.updateUploadCheckpoint(
                id: download.id,
                uploadURL: URL(string: "https://example.com/upload/1")!,
                uploadOffset: 1,
                totalBytes: 10
            )
        }
    }

    @Test
    func managedTelemetryReportsSanitizedLifecycleWithoutFalseSuccess() async throws {
        let probe = ManagedTelemetryProbe()
        let coordinator = ManagedTransferCoordinator(telemetry: { context in
            probe.append(context)
        })
        let snapshot = makeManagedSnapshot(id: "telemetry")
        try await coordinator.register(snapshot)
        try await coordinator.transition(id: snapshot.id, to: .preparing)
        try await coordinator.transition(id: snapshot.id, to: .transferring)
        try await coordinator.updateProgress(id: snapshot.id, completedBytes: 4, totalBytes: 10)
        await coordinator.recordTelemetry(
            id: snapshot.id,
            event: .resumeRestarted,
            offset: 4,
            reason: "validator_changed"
        )
        try await coordinator.transition(
            id: snapshot.id,
            to: .failed,
            reason: "checksum_mismatch"
        )
        let contexts = probe.values()

        #expect(contexts.map(\.event).contains(.started))
        #expect(contexts.map(\.event).contains(.progress))
        #expect(contexts.map(\.event).contains(.resumeRestarted))
        #expect(contexts.map(\.event).contains(.failed))
        #expect(!contexts.map(\.event).contains(.completed))
        #expect(contexts.first(where: { $0.event == .failed })?.reason == "checksum_mismatch")
        #expect(contexts.first(where: { $0.event == .resumeRestarted })?.offset == 4)
    }

    @Test
    func openTelemetryAdapterMapsManagedTransferWithoutRequestSecrets() {
        let context = TelemetryManagedTransferContext(
            transferID: .init(rawValue: "transfer-id"),
            kind: .upload,
            event: .resumeAccepted,
            completedBytes: 8,
            totalBytes: 10,
            offset: 8,
            sessionIdentifier: "background-session",
            taskIdentifier: 9,
            reason: "server_offset"
        )

        let payload = OpenTelemetryAdapter().managedTransferPayload(context: context)

        #expect(payload.eventName == "managed_transfer.resumeAccepted")
        #expect(payload.attributes["transfer_id"] == .string("transfer-id"))
        #expect(payload.attributes["offset"] == .int(8))
        #expect(payload.attributes["authorization"] == nil)
    }
}
