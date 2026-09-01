import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

// Requirements: FR-BG-1...3, FR-INT-1, FR-POL-1, EC-5...6, EC-9.

private final class BackgroundCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class BackgroundDelegateEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BackgroundDelegateEvent] = []
    func append(_ event: BackgroundDelegateEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
    func values() -> [BackgroundDelegateEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

@Suite(.serialized)
struct BackgroundTransferCoordinatorTests {
    @Test
    func hostCompletionRunsOnceAfterSessionEventsDrain() async {
        let coordinator = BackgroundTransferCoordinator()
        let probe = BackgroundCompletionProbe()

        await coordinator.handleEvents(forSessionIdentifier: "session") {
            probe.increment()
        }
        await coordinator.sessionDidFinishEvents(identifier: "session")
        await coordinator.sessionDidFinishEvents(identifier: "session")
        #expect(probe.value() == 1)
    }

    @Test
    func hostCompletionRegisteredAfterDrainRunsImmediatelyOnce() async {
        let coordinator = BackgroundTransferCoordinator()
        let probe = BackgroundCompletionProbe()
        await coordinator.sessionDidFinishEvents(identifier: "late")

        await coordinator.handleEvents(forSessionIdentifier: "late") {
            probe.increment()
        }

        #expect(probe.value() == 1)
    }

    @Test
    func restoredBackgroundDownloadFinalizesAndValidatesIntegrity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("staged")
        let destination = root.appendingPathComponent("destination")
        let data = Data("background-data".utf8)
        try data.write(to: staged)
        let coordinator = BackgroundTransferCoordinator(stagingDirectoryURL: root)
        let snapshot = ManagedTransferSnapshot(
            id: .init(rawValue: "background-success"),
            kind: .download,
            state: .restoring,
            requestURL: URL(string: "https://example.com/background")!,
            method: "GET",
            options: .init(
                execution: .background(sessionIdentifier: "session"),
                integrity: .expectedSHA256(SHA256Util.hex(data))
            ),
            destinationURL: destination,
            destinationPolicy: .replace,
            sessionIdentifier: "session"
        )
        try await coordinator.transfers.register(snapshot)

        await coordinator.finalizeSuccessfulTransfer(id: snapshot.id, stagedFileURL: staged)

        #expect(await coordinator.transfers.snapshot(id: snapshot.id)?.state == .completed)
        #expect(try Data(contentsOf: destination) == data)
    }

    @Test
    func backgroundIntegrityMismatchFailsWithoutPublishingFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staged = root.appendingPathComponent("staged")
        let destination = root.appendingPathComponent("destination")
        try Data("wrong".utf8).write(to: staged)
        let coordinator = BackgroundTransferCoordinator(stagingDirectoryURL: root)
        let snapshot = ManagedTransferSnapshot(
            id: .init(rawValue: "background-integrity"),
            kind: .download,
            state: .transferring,
            requestURL: URL(string: "https://example.com/background")!,
            method: "GET",
            options: .init(
                execution: .background(sessionIdentifier: "session"),
                integrity: .expectedSHA256("deadbeef")
            ),
            destinationURL: destination,
            sessionIdentifier: "session"
        )
        try await coordinator.transfers.register(snapshot)

        await coordinator.finalizeSuccessfulTransfer(id: snapshot.id, stagedFileURL: staged)

        let terminal = await coordinator.transfers.snapshot(id: snapshot.id)
        #expect(terminal?.state == .failed)
        #expect(terminal?.lastErrorReason == "checksum_mismatch")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func networkPolicyMapsToRequestAndBackgroundConfiguration() async throws {
        let policy = TransferNetworkPolicy(
            allowsCellularAccess: false,
            allowsExpensiveNetworkAccess: false,
            allowsConstrainedNetworkAccess: false,
            isDiscretionary: true,
            priority: 0.8
        )
        var request = URLRequest(url: URL(string: "https://example.com")!)
        BackgroundTransferCoordinator.applyNetworkPolicy(policy, to: &request)

        #expect(!request.allowsCellularAccess)
#if canImport(Darwin)
        // These two are Apple-only properties of URLRequest; swift-corelibs-foundation has neither.
        #expect(!request.allowsExpensiveNetworkAccess)
        #expect(!request.allowsConstrainedNetworkAccess)
#endif

#if os(iOS) || os(macOS)
        let coordinator = BackgroundTransferCoordinator()
        let session = try await coordinator.backgroundSession(
            identifier: "com.novanetwork.tests.\(UUID().uuidString)",
            policy: policy
        )
        defer { session.invalidateAndCancel() }
        #expect(session.configuration.isDiscretionary)
        #expect(!session.configuration.allowsCellularAccess)
#endif
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func scheduleDownloadRegistersJournalTaskAndReconciles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiskTransferJournal(directoryURL: root.appendingPathComponent("journal"))
        let coordinator = BackgroundTransferCoordinator(journal: journal, stagingDirectoryURL: root)
        let identifier = "com.novanetwork.tests.schedule-download.\(UUID().uuidString)"
        let id = TransferID(rawValue: "scheduled-download")

        let handle = try await coordinator.scheduleDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: root.appendingPathComponent("destination.bin"),
            options: .init(execution: .background(sessionIdentifier: identifier)),
            id: id
        )

        #expect(handle.id == id)
        let snapshot = await coordinator.transfers.snapshot(id: id)
        #expect(snapshot?.state == .transferring)
        #expect(snapshot?.sessionIdentifier == identifier)
        #expect(snapshot?.taskIdentifier != nil)

        let reconciliation = try await coordinator.reconcile(sessionIdentifier: identifier)
        #expect(reconciliation.reconciledTransferIDs == [id])
        #expect(reconciliation.orphanedSnapshotIDs.isEmpty)
        #expect(reconciliation.conflictingTransferIDs.isEmpty)

        await handle.cancel()
        #expect(await coordinator.transfers.snapshot(id: id)?.state == .cancelled)

        let restored = try await BackgroundTransferCoordinator(
            journal: journal,
            stagingDirectoryURL: root
        ).restore()
        #expect(restored.snapshots.map(\.id) == [id])
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func scheduleUploadRegistersJournalAndAttachesTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("upload.bin")
        try Data("upload-body".utf8).write(to: source)
        let coordinator = BackgroundTransferCoordinator(stagingDirectoryURL: root)
        let identifier = "com.novanetwork.tests.schedule-upload.\(UUID().uuidString)"
        let id = TransferID(rawValue: "scheduled-upload")

        let handle = try await coordinator.scheduleUpload(
            request: APIRequest(method: .post, url: URL(string: "https://example.com/upload")!),
            sourceURL: source,
            options: .init(execution: .background(sessionIdentifier: identifier)),
            id: id
        )

        let snapshot = await coordinator.transfers.snapshot(id: id)
        #expect(snapshot?.state == .transferring)
        #expect(snapshot?.kind == .upload)
        #expect(snapshot?.totalBytes == Int64("upload-body".utf8.count))
        #expect(snapshot?.taskIdentifier != nil)
        await handle.cancel()

        await #expect(throws: ManagedTransferError.invalidResumeCheckpoint) {
            _ = try await coordinator.scheduleUpload(
                request: APIRequest(method: .post, url: URL(string: "https://example.com/upload")!),
                sourceURL: root.appendingPathComponent("missing.bin"),
                options: .init(execution: .background(sessionIdentifier: identifier)),
                id: .init(rawValue: "missing-source")
            )
        }
    }

    @Test
    func foregroundOptionsAreRejectedByBackgroundScheduler() async {
        let coordinator = BackgroundTransferCoordinator()

        await #expect(throws: ManagedTransferError.backgroundTransfersUnavailable) {
            _ = try await coordinator.scheduleDownload(
                request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
                to: URL(fileURLWithPath: "/tmp/unreachable"),
                options: .init(execution: .foreground)
            )
        }
    }

    @Test
    func delegateStagesDownloadsAndMapsProgressCancellationAndDrain() async throws {
#if os(iOS) || os(macOS)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = BackgroundDelegateEventProbe()
        let delegate = BackgroundTransferSessionDelegate(
            sessionIdentifier: "delegate-session",
            stagingDirectoryURL: root
        ) { event in
            probe.append(event)
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let upload = session.uploadTask(
            with: URLRequest(url: URL(string: "https://example.com/upload")!),
            from: Data("body".utf8)
        )
        upload.taskDescription = "upload-id"
        delegate.urlSession(
            session,
            task: upload,
            didSendBodyData: 2,
            totalBytesSent: 2,
            totalBytesExpectedToSend: 4
        )

        let download = session.downloadTask(with: URL(string: "https://example.com/download")!)
        download.taskDescription = "download-id"
        delegate.urlSession(
            session,
            downloadTask: download,
            didWriteData: 3,
            totalBytesWritten: 3,
            totalBytesExpectedToWrite: 6
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("temporary")
        try Data("download".utf8).write(to: temporary)
        delegate.urlSession(session, downloadTask: download, didFinishDownloadingTo: temporary)
        delegate.urlSession(session, task: download, didCompleteWithError: nil)
        delegate.urlSession(
            session,
            task: upload,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        )
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        let events = probe.values()
        #expect(events.count == 5)
        #expect(BackgroundTransferSessionDelegate.transferIdentity(from: download.taskDescription)?.rawValue == "download-id")
        #expect(events.contains { event in
            if case .progress(let id, 2, 4) = event { return id.rawValue == "upload-id" }
            return false
        })
        #expect(events.contains { event in
            if case .completed(let id, let staged, _, false, nil) = event {
                return id.rawValue == "download-id"
                    && staged.map { FileManager.default.fileExists(atPath: $0.path) } == true
            }
            return false
        })
        #expect(events.contains { event in
            if case .completed(let id, _, _, true, _) = event { return id.rawValue == "upload-id" }
            return false
        })
        #expect(events.contains { event in
            if case .sessionFinished(let identifier) = event { return identifier == "delegate-session" }
            return false
        })
#endif
    }

    @Test
    func delegateEventsDriveUploadCompletionFailureAndCancellationStates() async throws {
        let coordinator = BackgroundTransferCoordinator()
        func snapshot(_ id: String) -> ManagedTransferSnapshot {
            ManagedTransferSnapshot(
                id: .init(rawValue: id),
                kind: .upload,
                state: .transferring,
                totalBytes: 10,
                requestURL: URL(string: "https://example.com/upload")!,
                method: "POST",
                options: .init(execution: .background(sessionIdentifier: "session")),
                sessionIdentifier: "session"
            )
        }
        for id in ["success", "http-failure", "transport-failure", "cancelled"] {
            try await coordinator.transfers.register(snapshot(id))
        }

        await coordinator.receive(
            .progress(transferID: .init(rawValue: "success"), completedBytes: 5, totalBytes: 10)
        )
        await coordinator.receive(
            .completed(
                transferID: .init(rawValue: "success"),
                stagedFileURL: nil,
                statusCode: 204,
                cancelled: false,
                errorReason: nil
            )
        )
        await coordinator.receive(
            .completed(
                transferID: .init(rawValue: "http-failure"),
                stagedFileURL: nil,
                statusCode: 503,
                cancelled: false,
                errorReason: nil
            )
        )
        await coordinator.receive(
            .completed(
                transferID: .init(rawValue: "transport-failure"),
                stagedFileURL: nil,
                statusCode: nil,
                cancelled: false,
                errorReason: "url_session_-1009"
            )
        )
        await coordinator.receive(
            .completed(
                transferID: .init(rawValue: "cancelled"),
                stagedFileURL: nil,
                statusCode: nil,
                cancelled: true,
                errorReason: "url_session_-999"
            )
        )

        #expect(await coordinator.transfers.snapshot(id: .init(rawValue: "success"))?.state == .completed)
        #expect(await coordinator.transfers.snapshot(id: .init(rawValue: "success"))?.completedBytes == 10)
        #expect(await coordinator.transfers.snapshot(id: .init(rawValue: "http-failure"))?.lastErrorReason == "http_503")
        #expect(
            await coordinator.transfers.snapshot(id: .init(rawValue: "transport-failure"))?.lastErrorReason
                == "url_session_-1009"
        )
        #expect(await coordinator.transfers.snapshot(id: .init(rawValue: "cancelled"))?.state == .cancelled)
    }
}
