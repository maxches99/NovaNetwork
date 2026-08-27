import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

// Requirements: FR-DL-1...3, FR-UP-1...2, FR-INT-1, EC-1...5, EC-10.

final class ManagedTransferURLProtocol: URLProtocol {
    enum DownloadBehavior {
        case range
        case ignoreRange
        case invalidRange
        case preconditionFailedOnce
    }

    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var downloadBehavior = DownloadBehavior.range
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var didFailPrecondition = false
    nonisolated(unsafe) static var tusOffset: Int64 = 0
    nonisolated(unsafe) static var tusInvalidAcknowledgement = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if request.url?.path.hasPrefix("/files/") == true {
            handleTUS()
        } else if request.httpMethod == "POST", request.value(forHTTPHeaderField: "Tus-Resumable") != nil {
            send(
                status: 201,
                headers: ["Tus-Resumable": "1.0.0", "Location": "/files/1"],
                body: Data()
            )
        } else {
            handleDownload()
        }
    }

    override func stopLoading() {}

    private func handleDownload() {
        let range = request.value(forHTTPHeaderField: "Range")
        let requestedOffset = range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
        if Self.downloadBehavior == .preconditionFailedOnce, range != nil, !Self.didFailPrecondition {
            Self.didFailPrecondition = true
            send(status: 412, headers: [:], body: Data())
            return
        }
        if range != nil, Self.downloadBehavior != .ignoreRange {
            let actualStart = Self.downloadBehavior == .invalidRange ? requestedOffset + 1 : requestedOffset
            let suffix = Self.payload.dropFirst(min(requestedOffset, Self.payload.count))
            send(
                status: 206,
                headers: [
                    "Content-Range": "bytes \(actualStart)-\(Self.payload.count - 1)/\(Self.payload.count)",
                    "Content-Length": "\(suffix.count)",
                    "ETag": "v1"
                ],
                body: Data(suffix)
            )
        } else {
            send(
                status: 200,
                headers: ["Content-Length": "\(Self.payload.count)", "ETag": "v1"],
                body: Self.payload
            )
        }
    }

    private func handleTUS() {
        switch request.httpMethod {
        case "HEAD":
            send(
                status: 200,
                headers: ["Tus-Resumable": "1.0.0", "Upload-Offset": "\(Self.tusOffset)"],
                body: Data()
            )
        case "PATCH":
            let suppliedOffset = Int64(request.value(forHTTPHeaderField: "Upload-Offset") ?? "")
            let bodyCount = Int64(request.httpBody?.count ?? 0)
                + (request.httpBody == nil ? Int64(request.value(forHTTPHeaderField: "Content-Length") ?? "0")! : 0)
            if suppliedOffset == Self.tusOffset {
                Self.tusOffset += bodyCount
            }
            let acknowledged = Self.tusInvalidAcknowledgement ? Self.tusOffset + 1 : Self.tusOffset
            send(
                status: 204,
                headers: ["Tus-Resumable": "1.0.0", "Upload-Offset": "\(acknowledged)"],
                body: Data()
            )
        default:
            send(status: 405, headers: [:], body: Data())
        }
    }

    private func send(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.httpMethod != "HEAD", !body.isEmpty {
            client?.urlProtocol(self, didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Responds after a short delay so a transfer stays genuinely in-flight long enough for a test to
/// cancel it before the mock response arrives.
final class DelayedURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data("delayed".utf8)
    nonisolated(unsafe) static var delaySeconds: Double = 0.3

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let payload = Self.payload
        let url = request.url!
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delaySeconds) { [self] in
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "\(payload.count)"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

func makeManagedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ManagedTransferURLProtocol.self]
    return URLSession(configuration: configuration)
}

func resetManagedProtocol(payload: Data = Data("0123456789".utf8)) {
    ManagedTransferURLProtocol.payload = payload
    ManagedTransferURLProtocol.downloadBehavior = .range
    ManagedTransferURLProtocol.requests = []
    ManagedTransferURLProtocol.didFailPrecondition = false
    ManagedTransferURLProtocol.tusOffset = 0
    ManagedTransferURLProtocol.tusInvalidAcknowledgement = false
}

private func terminalSnapshot(from handle: ManagedTransferHandle) async -> ManagedTransferSnapshot? {
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

@Suite(.serialized)
struct ManagedTransferProtocolTests {
    @Test
    func rangeDownloadAppendsPartialBytesAndUsesIfRange() async throws {
        resetManagedProtocol()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partialDirectory = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let id = TransferID(rawValue: "range")
        let partial = partialDirectory.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
        try Data("0123".utf8).write(to: partial)
        let destination = root.appendingPathComponent("output.bin")
        let journal = DiskTransferJournal(directoryURL: root.appendingPathComponent("journal"))
        try await journal.upsert(
            ManagedTransferSnapshot(
                id: id,
                kind: .download,
                state: .suspended,
                completedBytes: 4,
                totalBytes: 10,
                requestURL: URL(string: "https://example.com/download")!,
                method: "GET",
                destinationURL: destination,
                partialFileURL: partial,
                validator: .init(eTag: "v1")
            )
        )
        let manager = ManagedTransferManager(
            session: makeManagedSession(),
            journal: journal,
            partialDirectoryURL: partialDirectory
        )
        try await manager.restore()

        let handle = try await manager.resumeDownload(
            id: id,
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            destinationPolicy: .failIfExists
        )
        let terminal = await terminalSnapshot(from: handle)

        #expect(terminal?.state == .completed)
        #expect(try Data(contentsOf: destination) == ManagedTransferURLProtocol.payload)
        #expect(ManagedTransferURLProtocol.requests.first?.value(forHTTPHeaderField: "Range") == "bytes=4-")
        #expect(ManagedTransferURLProtocol.requests.first?.value(forHTTPHeaderField: "If-Range") == "v1")
    }

    @Test
    func serverIgnoringRangeReplacesPartialInsteadOfDuplicatingBytes() async throws {
        resetManagedProtocol()
        ManagedTransferURLProtocol.downloadBehavior = .ignoreRange
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partialDirectory = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let id = TransferID(rawValue: "ignore")
        try Data("0123".utf8).write(
            to: partialDirectory.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
        )
        let destination = root.appendingPathComponent("output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: partialDirectory)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            id: id
        )

        #expect(await terminalSnapshot(from: handle)?.state == .completed)
        #expect(try Data(contentsOf: destination) == ManagedTransferURLProtocol.payload)
    }

    @Test
    func invalidContentRangeFailsWithoutPublishingDestination() async throws {
        resetManagedProtocol()
        ManagedTransferURLProtocol.downloadBehavior = .invalidRange
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partialDirectory = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let id = TransferID(rawValue: "invalid-range")
        try Data("0123".utf8).write(
            to: partialDirectory.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
        )
        let destination = root.appendingPathComponent("output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: partialDirectory)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            id: id
        )
        let terminal = await terminalSnapshot(from: handle)

        #expect(terminal?.state == .failed)
        #expect(terminal?.lastErrorReason == "invalid_resume_response")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func preconditionFailureRetriesOnceFromZero() async throws {
        resetManagedProtocol()
        ManagedTransferURLProtocol.downloadBehavior = .preconditionFailedOnce
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partialDirectory = root.appendingPathComponent("partial")
        try FileManager.default.createDirectory(at: partialDirectory, withIntermediateDirectories: true)
        let id = TransferID(rawValue: "precondition")
        try Data("0123".utf8).write(
            to: partialDirectory.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
        )
        let destination = root.appendingPathComponent("output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: partialDirectory)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            id: id
        )

        #expect(await terminalSnapshot(from: handle)?.state == .completed)
        #expect(ManagedTransferURLProtocol.requests.count == 2)
        #expect(ManagedTransferURLProtocol.requests.last?.value(forHTTPHeaderField: "Range") == nil)
    }

    @Test
    func checksumMismatchRemovesPartialAndEmitsFailureOnly() async throws {
        resetManagedProtocol()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let partialDirectory = root.appendingPathComponent("partial")
        let id = TransferID(rawValue: "integrity")
        let partial = partialDirectory.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
        let destination = root.appendingPathComponent("output.bin")
        let manager = ManagedTransferManager(session: makeManagedSession(), partialDirectoryURL: partialDirectory)

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/download")!),
            to: destination,
            options: .init(integrity: .expectedSHA256("deadbeef")),
            id: id
        )
        let terminal = await terminalSnapshot(from: handle)

        #expect(terminal?.state == .failed)
        #expect(terminal?.lastErrorReason == "checksum_mismatch")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test
    func tusUploadUsesBoundedChunksAndPersistsConfirmedOffset() async throws {
        resetManagedProtocol(payload: Data())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("upload.bin")
        try Data("0123456789".utf8).write(to: source)
        let session = makeManagedSession()
        let manager = ManagedTransferManager(
            session: session,
            partialDirectoryURL: root,
            uploadStrategy: TUSResumableUploadStrategy(session: session),
            uploadChunkSize: 4
        )

        let handle = try await manager.startUpload(
            request: APIRequest(
                method: .post,
                url: URL(string: "https://example.com/uploads")!,
                headers: ["Authorization": "Bearer live-only"]
            ),
            sourceURL: source,
            id: .init(rawValue: "tus")
        )
        let terminal = await terminalSnapshot(from: handle)
        let patchRequests = ManagedTransferURLProtocol.requests.filter { $0.httpMethod == "PATCH" }

        #expect(terminal?.state == .completed)
        #expect(terminal?.uploadOffset == 10)
        #expect(patchRequests.count == 3)
        #expect(patchRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer live-only" })
    }

    @Test
    func cancelImmediatelyAfterStartActuallyStopsTheUnderlyingTask() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ManagedTransferManager(session: session, partialDirectoryURL: root.appendingPathComponent("partial"))
        let destination = root.appendingPathComponent("output.bin")

        let handle = try await manager.startDownload(
            request: APIRequest(method: .get, url: URL(string: "https://example.com/delayed")!),
            to: destination,
            id: .init(rawValue: "immediate-cancel")
        )
        // No sleep between start and cancel: exercises the handoff between starting the transfer
        // and the caller acting on the returned handle right away, with nothing artificially
        // giving cancellation-action registration extra time to complete first.
        await handle.cancel()

        // Give the mock response's delay time to land before asserting nothing was written. If
        // cancellation only flipped the coordinator's state flag without actually stopping the
        // background Task, the download would complete anyway and write `destination` despite the
        // snapshot already reporting `.cancelled`.
        try await Task.sleep(nanoseconds: UInt64(DelayedURLProtocol.delaySeconds * 2 * 1_000_000_000))

        #expect(await handle.snapshot()?.state == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func resumeUploadQueriesServerOffsetAndAppendsRemainingChunks() async throws {
        resetManagedProtocol(payload: Data())
        ManagedTransferURLProtocol.tusOffset = 5
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("upload.bin")
        try Data("0123456789".utf8).write(to: source)
        let session = makeManagedSession()
        let journal = DiskTransferJournal(directoryURL: root.appendingPathComponent("journal"))
        let id = TransferID(rawValue: "resume-upload")
        try await journal.upsert(
            ManagedTransferSnapshot(
                id: id,
                kind: .upload,
                state: .suspended,
                completedBytes: 5,
                totalBytes: 10,
                requestURL: URL(string: "https://example.com/uploads")!,
                method: "POST",
                uploadURL: URL(string: "https://example.com/files/1")!,
                uploadOffset: 5
            )
        )
        let manager = ManagedTransferManager(
            session: session,
            journal: journal,
            partialDirectoryURL: root,
            uploadStrategy: TUSResumableUploadStrategy(session: session),
            uploadChunkSize: 4
        )
        try await manager.restore()

        let handle = try await manager.resumeUpload(
            id: id,
            request: APIRequest(method: .post, url: URL(string: "https://example.com/uploads")!),
            sourceURL: source
        )
        let terminal = await terminalSnapshot(from: handle)
        let headRequests = ManagedTransferURLProtocol.requests.filter { $0.httpMethod == "HEAD" }

        #expect(terminal?.state == .completed)
        #expect(terminal?.uploadOffset == 10)
        #expect(headRequests.count == 1)
    }

    @Test
    func tusRejectsServerOffsetThatDoesNotMatchAppendedChunk() async throws {
        resetManagedProtocol(payload: Data())
        ManagedTransferURLProtocol.tusInvalidAcknowledgement = true
        let session = makeManagedSession()
        let strategy = TUSResumableUploadStrategy(session: session)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/uploads")!)
        let uploadURL = try await strategy.createUpload(for: request, totalBytes: 3)

        await #expect(throws: ManagedTransferError.invalidUploadOffset) {
            _ = try await strategy.append(Data("abc".utf8), to: uploadURL, at: 0, request: request)
        }
    }
}
