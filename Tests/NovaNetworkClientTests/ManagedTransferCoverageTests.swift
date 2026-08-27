import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

// Requirements: FR-DL-2...3, FR-UP-1, FR-INT-1, UR-3, EC-1...5, EC-9...10.

private struct InvalidOffsetUploadStrategy: ResumableUploadStrategy {
    func createUpload(for request: APIRequest, totalBytes: Int64) async throws -> URL {
        URL(string: "https://upload.invalid/files/1")!
    }

    func offset(for uploadURL: URL, request: APIRequest) async throws -> Int64 { 0 }

    func append(
        _ chunk: Data,
        to uploadURL: URL,
        at offset: Int64,
        request: APIRequest
    ) async throws -> Int64 {
        offset + Int64(chunk.count) + 100
    }
}

private func coverageTerminal(_ handle: ManagedTransferHandle) async -> ManagedTransferSnapshot? {
    for await event in handle.events {
        switch event {
        case .completed(let snapshot), .failed(let snapshot), .cancelled(let snapshot):
            return snapshot
        default:
            continue
        }
    }
    return await handle.snapshot()
}

extension ManagedTransferProtocolTests {
    @Test
    func contentRangeParserAndDispositionCoverRestartAndValidationBranches() throws {
        #expect(ManagedTransferManager.parseContentRange("bytes 2-4/10") == .init(start: 2, end: 4, total: 10))
        #expect(ManagedTransferManager.parseContentRange("bytes 2-4/*") == .init(start: 2, end: 4, total: nil))
        #expect(ManagedTransferManager.parseContentRange("items 2-4/10") == nil)
        #expect(ManagedTransferManager.parseContentRange("bytes bad/10") == nil)
        #expect(ManagedTransferManager.parseContentRange("bytes 4-2/10") == nil)
        #expect(ManagedTransferManager.parseContentRange("bytes 2-10/10") == nil)
        #expect(
            try ManagedTransferManager.downloadDisposition(
                statusCode: 200, headers: [:], requestedOffset: 4, allowRestart: true
            ) == .replace
        )
        #expect(
            try ManagedTransferManager.downloadDisposition(
                statusCode: 206,
                headers: ["content-range": "bytes 0-9/10"],
                requestedOffset: 0,
                allowRestart: true
            ) == .replace
        )
        #expect(
            try ManagedTransferManager.downloadDisposition(
                statusCode: 412, headers: [:], requestedOffset: 4, allowRestart: true
            ) == .retryFromZero
        )
        #expect(
            try ManagedTransferManager.downloadDisposition(
                statusCode: 201, headers: [:], requestedOffset: 4, allowRestart: true
            ) == .retryFromZero
        )
        #expect(throws: ManagedTransferError.invalidResumeResponse) {
            _ = try ManagedTransferManager.downloadDisposition(
                statusCode: 412, headers: [:], requestedOffset: 4, allowRestart: false
            )
        }
        #expect(throws: ManagedTransferError.invalidResumeResponse) {
            _ = try ManagedTransferManager.downloadDisposition(
                statusCode: 206,
                headers: ["Content-Range": "bytes 3-9/10"],
                requestedOffset: 4,
                allowRestart: true
            )
        }
        #expect(throws: NetworkError.self) {
            _ = try ManagedTransferManager.downloadDisposition(
                statusCode: 500, headers: [:], requestedOffset: 0, allowRestart: true
            )
        }
    }

    @Test
    func fileUtilitiesCoverIntegrityMergeAndMetadataBranches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let partial = root.appendingPathComponent("partial")
        let first = root.appendingPathComponent("first")
        try Data("ab".utf8).write(to: partial)
        try Data("cd".utf8).write(to: first)
        try ManagedTransferManager.merge(stagingURL: first, partialURL: partial, append: true)
        #expect(try Data(contentsOf: partial) == Data("abcd".utf8))
        let replacement = root.appendingPathComponent("replacement")
        try Data("xyz".utf8).write(to: replacement)
        try ManagedTransferManager.merge(stagingURL: replacement, partialURL: partial, append: false)
        #expect(try Data(contentsOf: partial) == Data("xyz".utf8))

        let manager = ManagedTransferManager(partialDirectoryURL: root)
        try manager.verifyIntegrity(at: partial, policy: .none)
        try manager.verifyIntegrity(at: partial, policy: .expectedByteCount(3))
        try manager.verifyIntegrity(at: partial, policy: .expectedSHA256(SHA256Util.hex(Data("xyz".utf8))))
        try manager.verifyIntegrity(
            at: partial,
            policy: .expectedByteCountAndSHA256(
                byteCount: 3,
                sha256: SHA256Util.hex(Data("xyz".utf8)).uppercased()
            )
        )
        #expect(throws: ManagedTransferError.byteCountMismatch(expected: 4, actual: 3)) {
            try manager.verifyIntegrity(at: partial, policy: .expectedByteCount(4))
        }
        #expect(throws: ManagedTransferError.checksumMismatch) {
            try manager.verifyIntegrity(at: partial, policy: .expectedSHA256("bad"))
        }
        #expect(throws: ManagedTransferError.byteCountMismatch(expected: 4, actual: 3)) {
            try manager.verifyIntegrity(
                at: partial,
                policy: .expectedByteCountAndSHA256(byteCount: 4, sha256: "bad")
            )
        }
        #expect(ManagedTransferManager.fileSize(at: partial) == 3)
        #expect(try ManagedTransferManager.requiredFileSize(at: partial) == 3)
        #expect(throws: ManagedTransferError.invalidResumeCheckpoint) {
            _ = try ManagedTransferManager.requiredFileSize(at: root.appendingPathComponent("missing"))
        }

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: ["ETag": "v2", "Content-Range": "bytes 2-4/5"]
        )!
        let metadata = try ManagedTransferManager.metadata(from: response)
        #expect(metadata.statusCode == 206)
        #expect(ManagedTransferManager.totalBytes(metadata: metadata, headers: metadata.headers, startingOffset: 2) == 5)
        #expect(ManagedTransferManager.validator(headers: metadata.headers)?.eTag == "v2")
        #expect(ManagedTransferManager.validator(headers: [:]) == nil)
    }

    @Test
    func existingDestinationPoliciesCompleteOrFailWithoutNetwork() async throws {
        resetManagedProtocol(payload: Data("network-must-not-run".utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("existing")
        try Data("kept".utf8).write(to: destination)
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: root)

        let kept = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            destinationPolicy: .keepExisting,
            options: .init(integrity: .expectedByteCount(4)),
            id: .init(rawValue: "keep")
        )
        #expect(await coverageTerminal(kept)?.state == .completed)
        #expect(ManagedTransferURLProtocol.requests.isEmpty)

        let failed = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            destinationPolicy: .failIfExists,
            id: .init(rawValue: "fail")
        )
        #expect(await coverageTerminal(failed)?.state == .failed)
        #expect(ManagedTransferURLProtocol.requests.isEmpty)
    }

    @Test
    func managerRejectsBackgroundModeAndInvalidUploadAcknowledgement() async throws {
        let manager = ManagedTransferManager(uploadStrategy: InvalidOffsetUploadStrategy())
        let background = ManagedTransferOptions(
            execution: .background(sessionIdentifier: "session")
        )
        await #expect(throws: ManagedTransferError.backgroundTransfersUnavailable) {
            _ = try await manager.startDownload(
                request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
                to: URL(fileURLWithPath: "/tmp/background"),
                options: background
            )
        }
        await #expect(throws: ManagedTransferError.backgroundTransfersUnavailable) {
            _ = try await manager.startUpload(
                request: APIRequest(method: .post, url: URL(string: "https://example.com")!),
                sourceURL: URL(fileURLWithPath: "/tmp/missing"),
                options: background
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("upload")
        try Data("1234".utf8).write(to: source)
        let handle = try await manager.startUpload(
            request: APIRequest(method: .post, url: URL(string: "https://example.com")!),
            sourceURL: source,
            id: .init(rawValue: "invalid-offset")
        )
        let terminal = await coverageTerminal(handle)
        #expect(terminal?.state == .failed)
        #expect(terminal?.lastErrorReason == "invalid_upload_offset")
    }

    @Test
    func resumeDownloadRejectsWrongKindAndTerminalSnapshots() async throws {
        let manager = ManagedTransferManager()
        let upload = ManagedTransferSnapshot(
            id: .init(rawValue: "wrong-kind"),
            kind: .upload,
            state: .suspended,
            requestURL: URL(string: "https://example.com/upload")!,
            method: "POST"
        )
        try await manager.coordinator.register(upload)
        await #expect(throws: ManagedTransferError.invalidResumeCheckpoint) {
            _ = try await manager.resumeDownload(
                id: upload.id,
                request: APIRequest(method: .get, url: URL(string: "https://example.com")!)
            )
        }

        let terminal = ManagedTransferSnapshot(
            id: .init(rawValue: "terminal-download"),
            kind: .download,
            state: .queued,
            requestURL: URL(string: "https://example.com/download")!,
            method: "GET",
            destinationURL: URL(fileURLWithPath: "/tmp/terminal-download")
        )
        try await manager.coordinator.register(terminal)
        try await manager.coordinator.transition(id: terminal.id, to: .cancelled)
        await #expect(throws: ManagedTransferError.terminalStateAlreadyReached(terminal.id)) {
            _ = try await manager.resumeDownload(
                id: terminal.id,
                request: APIRequest(method: .get, url: URL(string: "https://example.com")!)
            )
        }
    }

    @Test
    func resumeUploadRejectsWrongKindAndTerminalSnapshots() async throws {
        let manager = ManagedTransferManager()
        let download = ManagedTransferSnapshot(
            id: .init(rawValue: "wrong-kind-upload"),
            kind: .download,
            state: .suspended,
            requestURL: URL(string: "https://example.com/download")!,
            method: "GET"
        )
        try await manager.coordinator.register(download)
        await #expect(throws: ManagedTransferError.invalidResumeCheckpoint) {
            _ = try await manager.resumeUpload(
                id: download.id,
                request: APIRequest(method: .post, url: URL(string: "https://example.com")!),
                sourceURL: URL(fileURLWithPath: "/tmp/missing")
            )
        }

        let terminal = ManagedTransferSnapshot(
            id: .init(rawValue: "terminal-upload"),
            kind: .upload,
            state: .queued,
            requestURL: URL(string: "https://example.com/upload")!,
            method: "POST"
        )
        try await manager.coordinator.register(terminal)
        try await manager.coordinator.transition(id: terminal.id, to: .cancelled)
        await #expect(throws: ManagedTransferError.terminalStateAlreadyReached(terminal.id)) {
            _ = try await manager.resumeUpload(
                id: terminal.id,
                request: APIRequest(method: .post, url: URL(string: "https://example.com")!),
                sourceURL: URL(fileURLWithPath: "/tmp/missing")
            )
        }
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func replacePolicyOverwritesExistingDestination() async throws {
        resetManagedProtocol(payload: Data("replacement-body".utf8))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("existing")
        try Data("stale".utf8).write(to: destination)
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: root)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            destinationPolicy: .replace,
            id: .init(rawValue: "replace")
        )

        #expect(await coverageTerminal(handle)?.state == .completed)
        #expect(try Data(contentsOf: destination) == ManagedTransferURLProtocol.payload)
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func disabledResumeDiscardsExistingPartialFile() async throws {
        resetManagedProtocol()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partialDirectory = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let id = TransferID(rawValue: "disabled-resume")
        let stalePartial = partialDirectory.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
        try Data("stale-partial-bytes".utf8).write(to: stalePartial)
        let destination = root.appendingPathComponent("output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: partialDirectory)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            options: .init(resume: .disabled),
            id: id
        )
        let terminal = await coverageTerminal(handle)

        #expect(terminal?.state == .completed)
        #expect(try Data(contentsOf: destination) == ManagedTransferURLProtocol.payload)
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func resumeDownloadFromSuspendedStateTransitionsThroughResuming() async throws {
        resetManagedProtocol()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: root)
        let id = TransferID(rawValue: "suspended-resume")
        let snapshot = ManagedTransferSnapshot(
            id: id,
            kind: .download,
            state: .queued,
            requestURL: URL(string: "https://example.com/download")!,
            method: "GET",
            destinationURL: destination
        )
        try await manager.coordinator.register(snapshot)
        try await manager.coordinator.transition(id: id, to: .preparing)
        try await manager.coordinator.transition(id: id, to: .transferring)
        try await manager.coordinator.transition(id: id, to: .suspended)

        let handle = try await manager.resumeDownload(
            id: id,
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!)
        )

        #expect(await coverageTerminal(handle)?.state == .completed)
        #expect(try Data(contentsOf: destination) == ManagedTransferURLProtocol.payload)
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func largePayloadDownloadFlushesCheckpointsAcrossMultipleBufferedWrites() async throws {
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        resetManagedProtocol(payload: payload)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("large-output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: root)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            id: .init(rawValue: "large-payload")
        )
        let terminal = await coverageTerminal(handle)

        #expect(terminal?.state == .completed)
        #expect(terminal?.completedBytes == Int64(payload.count))
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test
    func resumeAndCoordinatorControlErrorsAreTyped() async throws {
        let manager = ManagedTransferManager()
        let missing = TransferID(rawValue: "missing")
        await #expect(throws: ManagedTransferError.transferNotFound(missing)) {
            _ = try await manager.resumeDownload(
                id: missing,
                request: APIRequest(method: .get, url: URL(string: "https://example.com")!)
            )
        }
        await #expect(throws: ManagedTransferError.transferNotFound(missing)) {
            _ = try await manager.resumeUpload(
                id: missing,
                request: APIRequest(method: .post, url: URL(string: "https://example.com")!),
                sourceURL: URL(fileURLWithPath: "/tmp/missing")
            )
        }

        let snapshot = ManagedTransferSnapshot(
            id: .init(rawValue: "duplicate"),
            kind: .download,
            state: .queued,
            requestURL: URL(string: "https://example.com")!,
            method: "GET"
        )
        try await manager.coordinator.register(snapshot)
        await #expect(throws: ManagedTransferError.transferAlreadyExists(snapshot.id)) {
            try await manager.coordinator.register(snapshot)
        }
        #expect(try await manager.coordinator.remove(id: snapshot.id) == false)
        await #expect(throws: ManagedTransferError.transferNotFound(missing)) {
            _ = try await manager.coordinator.handle(for: missing)
        }
        #expect(ManagedTransferManager.sanitizedReason(for: ManagedTransferError.checksumMismatch) == "checksum_mismatch")
        #expect(ManagedTransferManager.sanitizedReason(for: NetworkError.invalidResponse) == "invalid_response")
        #expect(
            ManagedTransferManager.sanitizedReason(
                for: NetworkTransferError.destinationFinalizationFailed(URL(fileURLWithPath: "/tmp/file"))
            ) == "file_failure"
        )
    }
}
