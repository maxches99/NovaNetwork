import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-DL-1...3, FR-UP-1...2, FR-BG-1, FR-INT-1, NFR-6.

private func e2eManagedTerminal(
    _ handle: ManagedTransferHandle,
    timeoutNanoseconds: UInt64 = 30_000_000_000
) async throws -> ManagedTransferSnapshot {
    try await withThrowingTaskGroup(of: ManagedTransferSnapshot.self) { group in
        group.addTask {
            for await event in handle.events {
                switch event {
                case .completed(let snapshot), .failed(let snapshot), .cancelled(let snapshot):
                    return snapshot
                default:
                    continue
                }
            }
            throw ManagedTransferError.transferNotFound(handle.id)
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

extension E2ECoverageTests {
    @Test
    func e2eV21ResumesRangeDownloadAgainstHTTPBingo() async throws {
        guard e2eEnabled() else { return }

        let endpoint = URL(string: "https://httpbingo.org/range/1024")!
        let (expected, response) = try await URLSession.shared.data(from: endpoint)
        let eTag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
        #expect(expected.count == 1_024)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-v21-range-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appendingPathComponent("partial.bin")
        let destination = root.appendingPathComponent("complete.bin")
        try expected.prefix(128).write(to: partial)
        let journal = DiskTransferJournal(directoryURL: root.appendingPathComponent("journal"))
        let snapshot = ManagedTransferSnapshot(
            id: .init(rawValue: "e2e-range"),
            kind: .download,
            state: .suspended,
            completedBytes: 128,
            totalBytes: 1_024,
            requestURL: endpoint,
            method: "GET",
            options: .init(integrity: .expectedSHA256(SHA256Util.hex(expected))),
            destinationURL: destination,
            destinationPolicy: .failIfExists,
            partialFileURL: partial,
            validator: .init(eTag: eTag)
        )
        try await journal.upsert(snapshot)
        let manager = ManagedTransferManager(
            journal: journal,
            partialDirectoryURL: root.appendingPathComponent("partials")
        )
        try await manager.restore()

        let handle = try await manager.resumeDownload(
            id: snapshot.id,
            request: APIRequest(method: .get, url: endpoint)
        )
        let terminal = try await e2eManagedTerminal(handle)

        #expect(terminal.state == .completed)
        #expect(terminal.completedBytes == 1_024)
        #expect(try Data(contentsOf: destination) == expected)
    }

    @Test
    func e2eV21ResumesTUSUploadAgainstOfficialDemo() async throws {
        guard e2eEnabled() else { return }

        let endpoint = URL(string: "https://tusd.tusdemo.net/files/")!
        let request = APIRequest(method: .post, url: endpoint)
        let strategy = TUSResumableUploadStrategy()
        let payload = Data("nova-v21-tus-e2e".utf8)
        let uploadURL = try await strategy.createUpload(for: request, totalBytes: Int64(payload.count))
        let firstChunk = payload.prefix(5)
        let firstOffset = try await strategy.append(
            Data(firstChunk),
            to: uploadURL,
            at: 0,
            request: request
        )
        #expect(firstOffset == 5)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-v21-tus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("upload.bin")
        try payload.write(to: source)
        let journal = DiskTransferJournal(directoryURL: root.appendingPathComponent("journal"))
        let snapshot = ManagedTransferSnapshot(
            id: .init(rawValue: "e2e-tus"),
            kind: .upload,
            state: .suspended,
            completedBytes: firstOffset,
            totalBytes: Int64(payload.count),
            requestURL: endpoint,
            method: "POST",
            uploadURL: uploadURL,
            uploadOffset: firstOffset
        )
        try await journal.upsert(snapshot)
        let manager = ManagedTransferManager(
            journal: journal,
            uploadStrategy: strategy,
            uploadChunkSize: 4
        )
        try await manager.restore()

        let handle = try await manager.resumeUpload(
            id: snapshot.id,
            request: request,
            sourceURL: source
        )
        let terminal = try await e2eManagedTerminal(handle)

        #expect(terminal.state == .completed)
        #expect(terminal.uploadOffset == Int64(payload.count))
        #expect(try await strategy.offset(for: uploadURL, request: request) == Int64(payload.count))

        var cleanup = URLRequest(url: uploadURL)
        cleanup.httpMethod = "DELETE"
        cleanup.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        _ = try? await URLSession.shared.data(for: cleanup)
    }

#if os(macOS)
    @Test
    func e2eV21BackgroundDownloadCompletesAgainstHTTPBingo() async throws {
        guard e2eEnabled() else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-v21-background-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("background.bin")
        let coordinator = BackgroundTransferCoordinator(
            journal: DiskTransferJournal(directoryURL: root.appendingPathComponent("journal")),
            stagingDirectoryURL: root.appendingPathComponent("staging")
        )
        let options = ManagedTransferOptions(
            execution: .background(
                sessionIdentifier: "com.novanetwork.e2e.\(UUID().uuidString)"
            ),
            integrity: .expectedByteCount(256),
            networkPolicy: .init(isDiscretionary: false, priority: 1)
        )

        let handle = try await coordinator.scheduleDownload(
            request: APIRequest(
                method: .get,
                url: URL(string: "https://httpbingo.org/range/256")!
            ),
            to: destination,
            options: options,
            id: .init(rawValue: "e2e-background")
        )
        let terminal = try await e2eManagedTerminal(handle, timeoutNanoseconds: 45_000_000_000)

        #expect(terminal.state == .completed)
        #expect(try Data(contentsOf: destination).count == 256)
    }
#endif
}
