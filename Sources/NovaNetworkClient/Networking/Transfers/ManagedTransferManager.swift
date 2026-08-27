import NovaNetworkCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// High-level owner of foreground resumable downloads and uploads.
///
/// The manager keeps transfer lifecycle state in ``ManagedTransferCoordinator`` and optionally
/// persists it through a ``TransferJournal``. Credentials are supplied again through live
/// `APIRequest` values during restoration and are never written to the journal.
public final class ManagedTransferManager: Sendable {
    /// Actor that owns snapshots, subscriptions, cancellation, and reconciliation.
    public let coordinator: ManagedTransferCoordinator

    private let session: URLSession
    private let partialDirectoryURL: URL
    private let uploadStrategy: any ResumableUploadStrategy
    private let uploadChunkSize: Int

    /// Creates a managed transfer manager.
    ///
    /// - Parameters:
    ///   - session: Foreground URLSession. A custom session can be used by deterministic tests.
    ///   - journal: Optional durable journal. Supply ``DiskTransferJournal`` for relaunch recovery.
    ///   - partialDirectoryURL: Private directory for incomplete download data. When omitted, a
    ///     NovaNetwork subdirectory in the user's caches directory is used.
    ///   - uploadStrategy: Offset-based upload protocol. Defaults to TUS 1.0.
    ///   - uploadChunkSize: Maximum upload data retained in memory at once, clamped to at least
    ///     one byte.
    ///   - telemetryHooks: Optional hooks receiving credential-free managed transfer events.
    public init(
        session: URLSession = .shared,
        journal: (any TransferJournal)? = nil,
        partialDirectoryURL: URL? = nil,
        uploadStrategy: (any ResumableUploadStrategy)? = nil,
        uploadChunkSize: Int = 1_048_576,
        telemetryHooks: NetworkTelemetryHooks? = nil
    ) {
        self.session = session
        self.coordinator = ManagedTransferCoordinator(
            journal: journal,
            telemetry: telemetryHooks?.onManagedTransferEvent
        )
        self.partialDirectoryURL = partialDirectoryURL ?? Self.defaultPartialDirectory()
        self.uploadStrategy = uploadStrategy ?? TUSResumableUploadStrategy(session: session)
        self.uploadChunkSize = max(1, uploadChunkSize)
    }

    /// Restores journal snapshots without automatically reusing credentials or starting work.
    ///
    /// The host must subsequently call ``resumeDownload(id:request:)`` or
    /// ``resumeUpload(id:request:sourceURL:)`` with a fresh authenticated request.
    @discardableResult
    public func restore() async throws -> TransferJournalLoadResult {
        try await coordinator.restore()
    }

    /// Starts a resumable foreground download and returns immediately with its control handle.
    ///
    /// Background execution options are rejected by this foreground manager. Use
    /// ``BackgroundTransferCoordinator`` for Apple background URLSession work.
    public func startDownload(
        request: APIRequest,
        to destinationURL: URL,
        destinationPolicy: DownloadDestinationPolicy = .failIfExists,
        options: ManagedTransferOptions = .init(),
        id: TransferID = .init()
    ) async throws -> ManagedTransferHandle {
        guard case .foreground = options.execution else {
            throw ManagedTransferError.backgroundTransfersUnavailable
        }
        let partialURL = partialURL(for: id)
        let existingBytes = options.resume == .disabled ? 0 : Self.fileSize(at: partialURL)
        if options.resume == .disabled {
            try? FileManager.default.removeItem(at: partialURL)
        }
        let now = Date()
        let snapshot = ManagedTransferSnapshot(
            id: id,
            kind: .download,
            state: .queued,
            createdAt: now,
            updatedAt: now,
            completedBytes: existingBytes,
            requestURL: request.urlRequest().url ?? request.url,
            method: request.method.rawValue,
            options: options,
            destinationURL: destinationURL,
            destinationPolicy: destinationPolicy,
            partialFileURL: partialURL
        )
        try await coordinator.register(snapshot)
        let handle = try await coordinator.handle(for: id)
        await startDownloadTask(snapshot: snapshot, request: request, destinationPolicy: destinationPolicy)
        return handle
    }

    /// Resumes a restored download using a fresh request whose headers remain in memory only.
    public func resumeDownload(
        id: TransferID,
        request: APIRequest,
        destinationPolicy: DownloadDestinationPolicy = .failIfExists
    ) async throws -> ManagedTransferHandle {
        guard let snapshot = await coordinator.snapshot(id: id) else {
            throw ManagedTransferError.transferNotFound(id)
        }
        guard snapshot.kind == .download, snapshot.destinationURL != nil else {
            throw ManagedTransferError.invalidResumeCheckpoint
        }
        guard !snapshot.state.isTerminal else {
            throw ManagedTransferError.terminalStateAlreadyReached(id)
        }
        let handle = try await coordinator.handle(for: id)
        await startDownloadTask(snapshot: snapshot, request: request, destinationPolicy: destinationPolicy)
        return handle
    }

    /// Starts a resumable foreground upload from a file using the configured strategy.
    public func startUpload(
        request: APIRequest,
        sourceURL: URL,
        options: ManagedTransferOptions = .init(),
        id: TransferID = .init()
    ) async throws -> ManagedTransferHandle {
        guard case .foreground = options.execution else {
            throw ManagedTransferError.backgroundTransfersUnavailable
        }
        let totalBytes = try Self.requiredFileSize(at: sourceURL)
        let now = Date()
        let snapshot = ManagedTransferSnapshot(
            id: id,
            kind: .upload,
            state: .queued,
            createdAt: now,
            updatedAt: now,
            totalBytes: totalBytes,
            requestURL: request.urlRequest().url ?? request.url,
            method: request.method.rawValue,
            options: options
        )
        try await coordinator.register(snapshot)
        let handle = try await coordinator.handle(for: id)
        await startUploadTask(snapshot: snapshot, request: request, sourceURL: sourceURL)
        return handle
    }

    /// Resumes a restored upload using a fresh authenticated request and source file URL.
    public func resumeUpload(
        id: TransferID,
        request: APIRequest,
        sourceURL: URL
    ) async throws -> ManagedTransferHandle {
        guard let snapshot = await coordinator.snapshot(id: id) else {
            throw ManagedTransferError.transferNotFound(id)
        }
        guard snapshot.kind == .upload else {
            throw ManagedTransferError.invalidResumeCheckpoint
        }
        guard !snapshot.state.isTerminal else {
            throw ManagedTransferError.terminalStateAlreadyReached(id)
        }
        _ = try Self.requiredFileSize(at: sourceURL)
        let handle = try await coordinator.handle(for: id)
        await startUploadTask(snapshot: snapshot, request: request, sourceURL: sourceURL)
        return handle
    }
}

extension ManagedTransferManager {
    struct ResponseMetadata: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let expectedContentLength: Int64
    }

    struct ContentRange: Equatable {
        let start: Int64
        let end: Int64
        let total: Int64?
    }

    func startDownloadTask(
        snapshot: ManagedTransferSnapshot,
        request: APIRequest,
        destinationPolicy: DownloadDestinationPolicy
    ) async {
        let task = Task { [self] in
            await runDownload(snapshot: snapshot, request: request, destinationPolicy: destinationPolicy)
        }
        // Awaited so the cancellation action is registered before the caller can possibly observe
        // the handle and call `cancel()` -- an unawaited sibling `Task` here would race with an
        // immediate cancel, which could silently no-op instead of stopping the in-flight transfer.
        try? await coordinator.attachCancellationAction(id: snapshot.id) { task.cancel() }
    }

    func startUploadTask(
        snapshot: ManagedTransferSnapshot,
        request: APIRequest,
        sourceURL: URL
    ) async {
        let task = Task { [self] in
            await runUpload(snapshot: snapshot, request: request, sourceURL: sourceURL)
        }
        try? await coordinator.attachCancellationAction(id: snapshot.id) { task.cancel() }
    }

    func runDownload(
        snapshot: ManagedTransferSnapshot,
        request: APIRequest,
        destinationPolicy: DownloadDestinationPolicy
    ) async {
        do {
            try await transitionFromCurrent(snapshot.id, to: .preparing)
            guard let destinationURL = snapshot.destinationURL else {
                throw ManagedTransferError.invalidResumeCheckpoint
            }

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                switch destinationPolicy {
                case .failIfExists:
                    throw NetworkTransferError.destinationAlreadyExists(destinationURL)
                case .keepExisting:
                    try verifyIntegrity(at: destinationURL, policy: snapshot.options.integrity)
                    try await coordinator.transition(id: snapshot.id, to: .finalizing)
                    try await coordinator.transition(
                        id: snapshot.id,
                        to: .completed,
                        completedBytes: Self.fileSize(at: destinationURL),
                        totalBytes: Self.fileSize(at: destinationURL)
                    )
                    return
                case .replace:
                    break
                }
            }

            let partialURL = snapshot.partialFileURL ?? partialURL(for: snapshot.id)
            try FileManager.default.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var offset = Self.fileSize(at: partialURL)
            if snapshot.completedBytes != offset, snapshot.completedBytes > 0 {
                try? FileManager.default.removeItem(at: partialURL)
                offset = 0
            }
            if snapshot.options.resume == .disabled
                || (snapshot.options.resume == .requiresValidator && snapshot.validator?.ifRangeValue == nil) {
                try? FileManager.default.removeItem(at: partialURL)
                offset = 0
            }

            if offset > 0 {
                await coordinator.recordTelemetry(
                    id: snapshot.id,
                    event: .resumeAttempted,
                    offset: offset
                )
                try await coordinator.transition(id: snapshot.id, to: .resuming)
            } else {
                try await coordinator.transition(id: snapshot.id, to: .transferring)
            }

            try await transferDownload(
                id: snapshot.id,
                request: request,
                partialURL: partialURL,
                initialOffset: offset,
                validator: snapshot.validator,
                allowRestart: true
            )
            if offset > 0, await coordinator.snapshot(id: snapshot.id)?.state == .resuming {
                try await coordinator.transition(id: snapshot.id, to: .transferring)
            }
            try Task.checkCancellation()
            try await coordinator.transition(id: snapshot.id, to: .finalizing)
            try verifyIntegrity(at: partialURL, policy: snapshot.options.integrity)
            try finalizeDownload(from: partialURL, to: destinationURL, policy: destinationPolicy)
            let finalSize = Self.fileSize(at: destinationURL)
            try await coordinator.transition(
                id: snapshot.id,
                to: .completed,
                completedBytes: finalSize,
                totalBytes: finalSize
            )
        } catch is CancellationError {
            await coordinator.cancel(id: snapshot.id)
        } catch {
            if Self.isIntegrityError(error) {
                if let partialURL = snapshot.partialFileURL {
                    try? FileManager.default.removeItem(at: partialURL)
                }
            }
            try? await coordinator.transition(
                id: snapshot.id,
                to: .failed,
                reason: Self.sanitizedReason(for: error)
            )
        }
    }

    func transferDownload(
        id: TransferID,
        request: APIRequest,
        partialURL: URL,
        initialOffset: Int64,
        validator: TransferResourceValidator?,
        allowRestart: Bool
    ) async throws {
        var urlRequest = request.urlRequest()
        if initialOffset > 0 {
            urlRequest.setValue("bytes=\(initialOffset)-", forHTTPHeaderField: "Range")
            if let ifRange = validator?.ifRangeValue {
                urlRequest.setValue(ifRange, forHTTPHeaderField: "If-Range")
            }
        }

        // `URLSession.bytes(for:)` does not exist in swift-corelibs-foundation, so Linux always
        // takes the single-response fallback below, the same one used on operating system
        // versions that predate the streaming API.
        #if !canImport(FoundationNetworking)
        if #available(iOS 15, macOS 12, watchOS 8, tvOS 15, *) {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            let metadata = try Self.metadata(from: response)
            let disposition = try Self.downloadDisposition(
                statusCode: metadata.statusCode,
                headers: metadata.headers,
                requestedOffset: initialOffset,
                allowRestart: allowRestart
            )
            if disposition == .retryFromZero {
                await coordinator.recordTelemetry(
                    id: id,
                    event: .resumeRestarted,
                    offset: initialOffset,
                    reason: "precondition_failed"
                )
                try? FileManager.default.removeItem(at: partialURL)
                try await transitionToPreparingForRestart(id: id)
                return try await transferDownload(
                    id: id,
                    request: request,
                    partialURL: partialURL,
                    initialOffset: 0,
                    validator: nil,
                    allowRestart: false
                )
            }
            let append = disposition == .append
            if append {
                await coordinator.recordTelemetry(
                    id: id,
                    event: .resumeAccepted,
                    offset: initialOffset
                )
            }
            let total = Self.totalBytes(
                metadata: metadata,
                headers: metadata.headers,
                startingOffset: append ? initialOffset : 0
            )
            let responseValidator = Self.validator(headers: metadata.headers)
            try Self.prepareFile(at: partialURL, append: append)
            let handle = try FileHandle(forWritingTo: partialURL)
            defer { try? handle.close() }
            if append { try handle.seekToEnd() }
            var buffer = Data()
            buffer.reserveCapacity(65_536)
            var completed = append ? initialOffset : 0
            for try await byte in bytes {
                try Task.checkCancellation()
                buffer.append(byte)
                if buffer.count == 65_536 {
                    try handle.write(contentsOf: buffer)
                    completed += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    try await coordinator.updateDownloadCheckpoint(
                        id: id,
                        partialFileURL: partialURL,
                        completedBytes: completed,
                        totalBytes: total,
                        validator: responseValidator
                    )
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                completed += Int64(buffer.count)
            }
            try await coordinator.updateDownloadCheckpoint(
                id: id,
                partialFileURL: partialURL,
                completedBytes: completed,
                totalBytes: total,
                validator: responseValidator
            )
        } else {
            try await legacyTransferDownload(
                id: id,
                request: request,
                urlRequest: urlRequest,
                partialURL: partialURL,
                initialOffset: initialOffset,
                allowRestart: allowRestart
            )
        }
        #else
        try await legacyTransferDownload(
            id: id,
            request: request,
            urlRequest: urlRequest,
            partialURL: partialURL,
            initialOffset: initialOffset,
            allowRestart: allowRestart
        )
        #endif
    }

    func legacyTransferDownload(
        id: TransferID,
        request: APIRequest,
        urlRequest: URLRequest,
        partialURL: URL,
        initialOffset: Int64,
        allowRestart: Bool
    ) async throws {
        let stagingURL = partialURL.appendingPathExtension("response")
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let (response, metadata) = try await legacyDownload(
            request: urlRequest,
            stagingURL: stagingURL
        )
        _ = response
        let disposition = try Self.downloadDisposition(
            statusCode: metadata.statusCode,
            headers: metadata.headers,
            requestedOffset: initialOffset,
            allowRestart: allowRestart
        )
        if disposition == .retryFromZero {
            await coordinator.recordTelemetry(
                id: id,
                event: .resumeRestarted,
                offset: initialOffset,
                reason: "precondition_failed"
            )
            try? FileManager.default.removeItem(at: partialURL)
            try await transitionToPreparingForRestart(id: id)
            return try await transferDownload(
                id: id,
                request: request,
                partialURL: partialURL,
                initialOffset: 0,
                validator: nil,
                allowRestart: false
            )
        }
        try Self.merge(stagingURL: stagingURL, partialURL: partialURL, append: disposition == .append)
        if disposition == .append {
            await coordinator.recordTelemetry(
                id: id,
                event: .resumeAccepted,
                offset: initialOffset
            )
        }
        let completed = Self.fileSize(at: partialURL)
        try await coordinator.updateDownloadCheckpoint(
            id: id,
            partialFileURL: partialURL,
            completedBytes: completed,
            totalBytes: Self.totalBytes(
                metadata: metadata,
                headers: metadata.headers,
                startingOffset: disposition == .append ? initialOffset : 0
            ),
            validator: Self.validator(headers: metadata.headers)
        )
    }

    func runUpload(snapshot: ManagedTransferSnapshot, request: APIRequest, sourceURL: URL) async {
        do {
            try await transitionFromCurrent(snapshot.id, to: .preparing)
            let totalBytes = try Self.requiredFileSize(at: sourceURL)
            let uploadURL: URL
            var offset: Int64
            if let existingURL = snapshot.uploadURL {
                await coordinator.recordTelemetry(
                    id: snapshot.id,
                    event: .resumeAttempted,
                    offset: snapshot.uploadOffset
                )
                try await coordinator.transition(id: snapshot.id, to: .resuming)
                uploadURL = existingURL
                offset = try await uploadStrategy.offset(for: existingURL, request: request)
                await coordinator.recordTelemetry(
                    id: snapshot.id,
                    event: .resumeAccepted,
                    offset: offset
                )
            } else {
                uploadURL = try await uploadStrategy.createUpload(for: request, totalBytes: totalBytes)
                offset = 0
                try await coordinator.transition(id: snapshot.id, to: .transferring)
            }
            guard offset >= 0, offset <= totalBytes else {
                throw ManagedTransferError.invalidUploadOffset
            }
            try await coordinator.updateUploadCheckpoint(
                id: snapshot.id,
                uploadURL: uploadURL,
                uploadOffset: offset,
                totalBytes: totalBytes
            )
            if snapshot.uploadURL != nil {
                try await coordinator.transition(id: snapshot.id, to: .transferring)
            }

            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { handle.closeFile() }
            handle.seek(toFileOffset: UInt64(offset))
            while offset < totalBytes {
                try Task.checkCancellation()
                let count = min(uploadChunkSize, Int(totalBytes - offset))
                let chunk = handle.readData(ofLength: count)
                guard !chunk.isEmpty else { throw ManagedTransferError.invalidUploadOffset }
                offset = try await uploadStrategy.append(
                    chunk,
                    to: uploadURL,
                    at: offset,
                    request: request
                )
                guard offset <= totalBytes else { throw ManagedTransferError.invalidUploadOffset }
                try await coordinator.updateUploadCheckpoint(
                    id: snapshot.id,
                    uploadURL: uploadURL,
                    uploadOffset: offset,
                    totalBytes: totalBytes
                )
            }
            try await coordinator.transition(id: snapshot.id, to: .finalizing)
            try await coordinator.transition(
                id: snapshot.id,
                to: .completed,
                completedBytes: totalBytes,
                totalBytes: totalBytes
            )
        } catch is CancellationError {
            await coordinator.cancel(id: snapshot.id)
        } catch {
            try? await coordinator.transition(
                id: snapshot.id,
                to: .failed,
                reason: Self.sanitizedReason(for: error)
            )
        }
    }

    func transitionFromCurrent(_ id: TransferID, to target: ManagedTransferState) async throws {
        guard let current = await coordinator.snapshot(id: id) else {
            throw ManagedTransferError.transferNotFound(id)
        }
        switch current.state {
        case .queued, .restoring:
            try await coordinator.transition(id: id, to: target)
        case .suspended:
            try await coordinator.transition(id: id, to: .resuming)
            try await coordinator.transition(id: id, to: target)
        default:
            throw ManagedTransferError.invalidStateTransition(from: current.state, to: target)
        }
    }

    func transitionToPreparingForRestart(id: TransferID) async throws {
        guard let current = await coordinator.snapshot(id: id) else {
            throw ManagedTransferError.transferNotFound(id)
        }
        if current.state == .resuming {
            try await coordinator.transition(id: id, to: .preparing)
            try await coordinator.transition(id: id, to: .transferring)
        }
    }

    enum DownloadDisposition: Equatable {
        case append
        case replace
        case retryFromZero
    }

    static func downloadDisposition(
        statusCode: Int,
        headers: [String: String],
        requestedOffset: Int64,
        allowRestart: Bool
    ) throws -> DownloadDisposition {
        if statusCode == 412 {
            if allowRestart { return .retryFromZero }
            throw ManagedTransferError.invalidResumeResponse
        }
        if statusCode == 200 {
            return .replace
        }
        if statusCode == 206 {
            guard
                let rawRange = header("Content-Range", in: headers),
                let range = parseContentRange(rawRange),
                range.start == requestedOffset
            else {
                throw ManagedTransferError.invalidResumeResponse
            }
            return requestedOffset > 0 ? .append : .replace
        }
        guard (200..<300).contains(statusCode) else {
            throw NetworkError.httpStatus(code: statusCode, headers: headers, body: Data())
        }
        if requestedOffset > 0 {
            if allowRestart { return .retryFromZero }
            throw ManagedTransferError.invalidResumeResponse
        }
        return .replace
    }

    static func parseContentRange(_ value: String) -> ContentRange? {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = parts[1].split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard
            bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            start >= 0,
            end >= start
        else { return nil }
        let total = rangeAndTotal[1] == "*" ? nil : Int64(rangeAndTotal[1])
        if let total, total <= end { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    static func metadata(from response: URLResponse) throws -> ResponseMetadata {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let name = item.key as? String else { return }
            result[name] = String(describing: item.value)
        }
        return ResponseMetadata(
            statusCode: http.statusCode,
            headers: headers,
            expectedContentLength: response.expectedContentLength
        )
    }

    static func totalBytes(
        metadata: ResponseMetadata,
        headers: [String: String],
        startingOffset: Int64
    ) -> Int64? {
        if
            let rawRange = header("Content-Range", in: headers),
            let total = parseContentRange(rawRange)?.total {
            return total
        }
        guard metadata.expectedContentLength >= 0 else { return nil }
        return startingOffset + metadata.expectedContentLength
    }

    static func validator(headers: [String: String]) -> TransferResourceValidator? {
        let value = TransferResourceValidator(
            eTag: header("ETag", in: headers),
            lastModified: header("Last-Modified", in: headers)
        )
        return value.ifRangeValue == nil ? nil : value
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func prepareFile(at url: URL, append: Bool) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if !append {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.close()
        }
    }

    static func merge(stagingURL: URL, partialURL: URL, append: Bool) throws {
        if !append {
            try? FileManager.default.removeItem(at: partialURL)
            try FileManager.default.moveItem(at: stagingURL, to: partialURL)
            return
        }
        try prepareFile(at: partialURL, append: true)
        let output = try FileHandle(forWritingTo: partialURL)
        defer { output.closeFile() }
        output.seekToEndOfFile()
        let input = try FileHandle(forReadingFrom: stagingURL)
        defer { input.closeFile() }
        while true {
            let data = input.readData(ofLength: 65_536)
            if data.isEmpty { break }
            output.write(data)
        }
    }

    func legacyDownload(
        request: URLRequest,
        stagingURL: URL
    ) async throws -> (URLResponse, ResponseMetadata) {
        try await withCheckedThrowingContinuation { continuation in
            session.downloadTask(with: request) { temporaryURL, response, error in
                do {
                    if let error { throw error }
                    guard let temporaryURL, let response else { throw NetworkError.invalidResponse }
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
                    continuation.resume(returning: (response, try Self.metadata(from: response)))
                } catch {
                    continuation.resume(throwing: error)
                }
            }.resume()
        }
    }

    func verifyIntegrity(at url: URL, policy: TransferIntegrityPolicy) throws {
        let actualBytes = Self.fileSize(at: url)
        switch policy {
        case .none:
            return
        case .expectedByteCount(let expected):
            guard actualBytes == expected else {
                throw ManagedTransferError.byteCountMismatch(expected: expected, actual: actualBytes)
            }
        case .expectedSHA256(let expected):
            guard try SHA256Util.hex(fileAt: url).caseInsensitiveCompare(expected) == .orderedSame else {
                throw ManagedTransferError.checksumMismatch
            }
        case .expectedByteCountAndSHA256(let expected, let digest):
            guard actualBytes == expected else {
                throw ManagedTransferError.byteCountMismatch(expected: expected, actual: actualBytes)
            }
            guard try SHA256Util.hex(fileAt: url).caseInsensitiveCompare(digest) == .orderedSame else {
                throw ManagedTransferError.checksumMismatch
            }
        }
    }

    func finalizeDownload(
        from partialURL: URL,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                switch policy {
                case .failIfExists:
                    throw NetworkTransferError.destinationAlreadyExists(destinationURL)
                case .keepExisting:
                    try? FileManager.default.removeItem(at: partialURL)
                    return
                case .replace:
                    try AtomicFileReplacement.replaceItem(at: destinationURL, with: partialURL)
                }
            } else {
                try AtomicFileReplacement.replaceItem(at: destinationURL, with: partialURL)
            }
        } catch let error as NetworkTransferError {
            throw error
        } catch {
            throw NetworkTransferError.destinationFinalizationFailed(destinationURL)
        }
    }

    func partialURL(for id: TransferID) -> URL {
        partialDirectoryURL.appendingPathComponent("\(SHA256Util.hex(id.rawValue)).partial")
    }

    static func defaultPartialDirectory() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("NovaNetwork/ManagedTransfers", isDirectory: true)
    }

    static func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    static func requiredFileSize(at url: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ManagedTransferError.invalidResumeCheckpoint
        }
        return fileSize(at: url)
    }

    static func isIntegrityError(_ error: any Error) -> Bool {
        guard let managed = error as? ManagedTransferError else { return false }
        switch managed {
        case .byteCountMismatch, .checksumMismatch:
            return true
        default:
            return false
        }
    }

    static func sanitizedReason(for error: any Error) -> String {
        switch error {
        case is CancellationError:
            return "cancelled"
        case let error as ManagedTransferError:
            switch error {
            case .invalidResumeResponse: return "invalid_resume_response"
            case .invalidResumeCheckpoint: return "invalid_resume_checkpoint"
            case .byteCountMismatch: return "byte_count_mismatch"
            case .checksumMismatch: return "checksum_mismatch"
            case .resumableUploadUnsupported: return "resumable_upload_unsupported"
            case .invalidUploadOffset: return "invalid_upload_offset"
            case .backgroundTransfersUnavailable: return "background_transfers_unavailable"
            case .restorationConflict: return "restoration_conflict"
            case .transferNotFound: return "transfer_not_found"
            case .transferAlreadyExists: return "transfer_already_exists"
            case .terminalStateAlreadyReached: return "terminal_state"
            case .invalidStateTransition: return "invalid_state_transition"
            }
        case let error as NetworkError:
            switch error {
            case .cancelled: return "cancelled"
            case .httpStatus(let code, _, _): return "http_\(code)"
            case .invalidResponse: return "invalid_response"
            default: return "network_failure"
            }
        case is NetworkTransferError:
            return "file_failure"
        default:
            return "transfer_failure"
        }
    }
}
