import NovaNetworkCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BackgroundDelegateEvent: Sendable {
    case progress(transferID: TransferID, completedBytes: Int64, totalBytes: Int64?)
    case completed(
        transferID: TransferID,
        stagedFileURL: URL?,
        statusCode: Int?,
        cancelled: Bool,
        errorReason: String?
    )
    case sessionFinished(identifier: String)
}

#if os(iOS) || os(macOS)
final class BackgroundTransferSessionDelegate: NSObject,
    URLSessionTaskDelegate,
    URLSessionDownloadDelegate,
    Sendable {
    private let sessionIdentifier: String
    private let stagingDirectoryURL: URL
    private let eventHandler: @Sendable (BackgroundDelegateEvent) -> Void

    init(
        sessionIdentifier: String,
        stagingDirectoryURL: URL,
        eventHandler: @escaping @Sendable (BackgroundDelegateEvent) -> Void
    ) {
        self.sessionIdentifier = sessionIdentifier
        self.stagingDirectoryURL = stagingDirectoryURL
        self.eventHandler = eventHandler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let transferID = Self.transferIdentity(from: task.taskDescription) else { return }
        eventHandler(
            .progress(
                transferID: transferID,
                completedBytes: totalBytesSent,
                totalBytes: totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let transferID = Self.transferIdentity(from: downloadTask.taskDescription) else { return }
        eventHandler(
            .progress(
                transferID: transferID,
                completedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let transferID = Self.transferIdentity(from: downloadTask.taskDescription) else { return }
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: true
            )
            let stagedURL = stagingDirectoryURL
                .appendingPathComponent("\(downloadTask.taskIdentifier)-\(UUID().uuidString).download")
            try FileManager.default.moveItem(at: location, to: stagedURL)
            downloadTask.taskDescription = Self.encodedDescription(
                transferID: transferID,
                stagedFileURL: stagedURL
            )
        } catch {
            downloadTask.taskDescription = transferID.rawValue
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let transferID = Self.transferIdentity(from: task.taskDescription) else { return }
        let nsError = error as NSError?
        let cancelled = nsError?.domain == NSURLErrorDomain && nsError?.code == NSURLErrorCancelled
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        eventHandler(
            .completed(
                transferID: transferID,
                stagedFileURL: Self.stagedFileURL(from: task.taskDescription),
                statusCode: statusCode,
                cancelled: cancelled,
                errorReason: error == nil ? nil : "url_session_\(nsError?.code ?? -1)"
            )
        )
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventHandler(.sessionFinished(identifier: sessionIdentifier))
    }

    static func transferIdentity(from description: String?) -> TransferID? {
        guard let description, !description.isEmpty else { return nil }
        guard description.hasPrefix("nova:") else { return TransferID(rawValue: description) }
        let components = description.split(separator: ":", maxSplits: 2).map(String.init)
        guard
            components.count == 3,
            let data = Data(base64Encoded: components[1]),
            let rawValue = String(data: data, encoding: .utf8)
        else { return nil }
        return TransferID(rawValue: rawValue)
    }

    private static func encodedDescription(transferID: TransferID, stagedFileURL: URL) -> String {
        let id = Data(transferID.rawValue.utf8).base64EncodedString()
        let path = Data(stagedFileURL.path.utf8).base64EncodedString()
        return "nova:\(id):\(path)"
    }

    private static func stagedFileURL(from description: String?) -> URL? {
        guard let description, description.hasPrefix("nova:") else { return nil }
        let components = description.split(separator: ":", maxSplits: 2).map(String.init)
        guard
            components.count == 3,
            let data = Data(base64Encoded: components[2]),
            let path = String(data: data, encoding: .utf8)
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
#endif

/// Apple background URLSession owner with durable transfer identity and lifecycle handoff.
///
/// The host application remains responsible for entitlements and forwarding its background
/// session callback to ``handleEvents(forSessionIdentifier:completionHandler:)``. The same
/// identifier must not be owned by another URLSession instance in the process.
public actor BackgroundTransferCoordinator {
    /// Managed lifecycle and persistence coordinator shared by every background session.
    public let transfers: ManagedTransferCoordinator

    private struct SessionRecord {
        let session: URLSession
#if os(iOS) || os(macOS)
        let delegate: BackgroundTransferSessionDelegate
#endif
    }

    private let stagingDirectoryURL: URL
    private var sessions: [String: SessionRecord] = [:]
    private var pendingHostCompletions: [String: [@Sendable () -> Void]] = [:]
    private var finishedBeforeHostHandoff: Set<String> = []

    /// Creates an Apple background transfer coordinator.
    ///
    /// - Parameters:
    ///   - journal: Optional durable journal used for relaunch restoration.
    ///   - stagingDirectoryURL: Private location that receives system download files before
    ///     integrity validation and atomic destination finalization.
    ///   - telemetryHooks: Optional hooks receiving credential-free managed transfer events.
    public init(
        journal: (any TransferJournal)? = nil,
        stagingDirectoryURL: URL? = nil,
        telemetryHooks: NetworkTelemetryHooks? = nil
    ) {
        self.transfers = ManagedTransferCoordinator(
            journal: journal,
            telemetry: telemetryHooks?.onManagedTransferEvent
        )
        self.stagingDirectoryURL = stagingDirectoryURL ?? Self.defaultStagingDirectory()
    }

    /// Restores durable snapshots without starting duplicate URLSession tasks.
    @discardableResult
    public func restore() async throws -> TransferJournalLoadResult {
        try await transfers.restore()
    }

    /// Schedules a background download task and returns its stable managed handle.
    public func scheduleDownload(
        request: APIRequest,
        to destinationURL: URL,
        destinationPolicy: DownloadDestinationPolicy = .failIfExists,
        options: ManagedTransferOptions,
        id: TransferID = .init()
    ) async throws -> ManagedTransferHandle {
        let sessionIdentifier = try Self.backgroundIdentifier(from: options)
        let session = try backgroundSession(identifier: sessionIdentifier, policy: options.networkPolicy)
        let now = Date()
        let snapshot = ManagedTransferSnapshot(
            id: id,
            kind: .download,
            state: .queued,
            createdAt: now,
            updatedAt: now,
            requestURL: request.urlRequest().url ?? request.url,
            method: request.method.rawValue,
            options: options,
            destinationURL: destinationURL,
            destinationPolicy: destinationPolicy,
            sessionIdentifier: sessionIdentifier
        )
        try await transfers.register(snapshot)
        let handle = try await transfers.handle(for: id)
        try await transfers.transition(id: id, to: .preparing)
        var urlRequest = request.urlRequest()
        Self.applyNetworkPolicy(options.networkPolicy, to: &urlRequest)
        let task = session.downloadTask(with: urlRequest)
        task.taskDescription = id.rawValue
        task.priority = Float(options.networkPolicy.priority)
        try await transfers.attachBackgroundTask(
            .init(
                transferID: id,
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: task.taskIdentifier
            )
        )
        await transfers.recordTelemetry(id: id, event: .backgroundScheduled)
        try await transfers.attachCancellationAction(id: id) { task.cancel() }
        try await transfers.transition(id: id, to: .transferring)
        task.resume()
        return handle
    }

    /// Schedules a background upload from a file and returns its stable managed handle.
    ///
    /// URLSession background uploads require file-backed bodies. Request bodies embedded in the
    /// supplied `APIRequest` are ignored in favor of `sourceURL`.
    public func scheduleUpload(
        request: APIRequest,
        sourceURL: URL,
        options: ManagedTransferOptions,
        id: TransferID = .init()
    ) async throws -> ManagedTransferHandle {
        let sessionIdentifier = try Self.backgroundIdentifier(from: options)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ManagedTransferError.invalidResumeCheckpoint
        }
        let session = try backgroundSession(identifier: sessionIdentifier, policy: options.networkPolicy)
        let totalBytes = Self.fileSize(at: sourceURL)
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
            options: options,
            sessionIdentifier: sessionIdentifier
        )
        try await transfers.register(snapshot)
        let handle = try await transfers.handle(for: id)
        try await transfers.transition(id: id, to: .preparing)
        var urlRequest = request.urlRequest()
        urlRequest.httpBody = nil
        Self.applyNetworkPolicy(options.networkPolicy, to: &urlRequest)
        let task = session.uploadTask(with: urlRequest, fromFile: sourceURL)
        task.taskDescription = id.rawValue
        task.priority = Float(options.networkPolicy.priority)
        try await transfers.attachBackgroundTask(
            .init(
                transferID: id,
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: task.taskIdentifier
            )
        )
        await transfers.recordTelemetry(id: id, event: .backgroundScheduled)
        try await transfers.attachCancellationAction(id: id) { task.cancel() }
        try await transfers.transition(id: id, to: .transferring)
        task.resume()
        return handle
    }

    /// Reconciles live tasks in one background session with restored durable snapshots.
    public func reconcile(sessionIdentifier: String) async throws -> TransferReconciliationReport {
        let session = try backgroundSession(identifier: sessionIdentifier, policy: .init())
        let tasks = await allTasks(in: session)
        let descriptors = tasks.map { task in
            let transferID = Self.transferIdentity(from: task.taskDescription)
                ?? TransferID(rawValue: "orphan-task-\(task.taskIdentifier)")
            return BackgroundTransferTaskDescriptor(
                transferID: transferID,
                sessionIdentifier: sessionIdentifier,
                taskIdentifier: task.taskIdentifier
            )
        }
        return try await transfers.reconcile(liveTasks: descriptors)
    }

    /// Registers the host's background-session completion handoff.
    ///
    /// The closure is invoked exactly once after URLSession reports that pending delegate events
    /// for this delivery have drained. It may run on a non-main executor.
    public func handleEvents(
        forSessionIdentifier identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        if finishedBeforeHostHandoff.remove(identifier) != nil {
            completionHandler()
        } else {
            pendingHostCompletions[identifier, default: []].append(completionHandler)
        }
    }
}

extension BackgroundTransferCoordinator {
    func backgroundSession(
        identifier: String,
        policy: TransferNetworkPolicy
    ) throws -> URLSession {
        if let existing = sessions[identifier] { return existing.session }
#if os(iOS) || os(macOS)
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = policy.isDiscretionary
        configuration.allowsCellularAccess = policy.allowsCellularAccess
        if #available(iOS 13, macOS 10.15, *) {
            configuration.allowsExpensiveNetworkAccess = policy.allowsExpensiveNetworkAccess
            configuration.allowsConstrainedNetworkAccess = policy.allowsConstrainedNetworkAccess
        }
        let delegate = BackgroundTransferSessionDelegate(
            sessionIdentifier: identifier,
            stagingDirectoryURL: stagingDirectoryURL
        ) { [weak self] event in
            Task { await self?.receive(event) }
        }
        let queue = OperationQueue()
        queue.name = "NovaNetwork.Background.\(identifier)"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        sessions[identifier] = SessionRecord(session: session, delegate: delegate)
        return session
#else
        throw ManagedTransferError.backgroundTransfersUnavailable
#endif
    }

    func receive(_ event: BackgroundDelegateEvent) async {
        switch event {
        case .progress(let id, let completed, let total):
            try? await transfers.updateProgress(id: id, completedBytes: completed, totalBytes: total)
        case .completed(let id, let stagedURL, let statusCode, let cancelled, let reason):
            if cancelled {
                await transfers.cancel(id: id)
                if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
                return
            }
            guard reason == nil else {
                if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
                try? await transfers.transition(id: id, to: .failed, reason: reason)
                return
            }
            guard let statusCode, (200..<300).contains(statusCode) else {
                if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
                try? await transfers.transition(
                    id: id,
                    to: .failed,
                    reason: statusCode.map { "http_\($0)" } ?? "invalid_response"
                )
                return
            }
            await finalizeSuccessfulTransfer(id: id, stagedFileURL: stagedURL)
        case .sessionFinished(let identifier):
            await sessionDidFinishEvents(identifier: identifier)
        }
    }

    func finalizeSuccessfulTransfer(id: TransferID, stagedFileURL: URL?) async {
        guard let snapshot = await transfers.snapshot(id: id), !snapshot.state.isTerminal else {
            if let stagedFileURL { try? FileManager.default.removeItem(at: stagedFileURL) }
            return
        }
        do {
            if snapshot.state != .finalizing {
                try await transfers.transition(id: id, to: .finalizing)
            }
            switch snapshot.kind {
            case .upload:
                try await transfers.transition(
                    id: id,
                    to: .completed,
                    completedBytes: snapshot.totalBytes ?? snapshot.completedBytes,
                    totalBytes: snapshot.totalBytes
                )
            case .download:
                guard let stagedFileURL, let destinationURL = snapshot.destinationURL else {
                    throw ManagedTransferError.invalidResumeCheckpoint
                }
                try Self.verifyIntegrity(at: stagedFileURL, policy: snapshot.options.integrity)
                try Self.finalizeFile(
                    from: stagedFileURL,
                    to: destinationURL,
                    policy: snapshot.destinationPolicy
                )
                let bytes = Self.fileSize(at: destinationURL)
                try await transfers.transition(
                    id: id,
                    to: .completed,
                    completedBytes: bytes,
                    totalBytes: bytes
                )
            }
        } catch {
            if let stagedFileURL { try? FileManager.default.removeItem(at: stagedFileURL) }
            try? await transfers.transition(
                id: id,
                to: .failed,
                reason: Self.sanitizedReason(error)
            )
        }
    }

    func sessionDidFinishEvents(identifier: String) async {
        let handlers = pendingHostCompletions.removeValue(forKey: identifier) ?? []
        if handlers.isEmpty {
            finishedBeforeHostHandoff.insert(identifier)
        } else {
            for handler in handlers { handler() }
        }
        let snapshots = await transfers.snapshots()
        for snapshot in snapshots where snapshot.sessionIdentifier == identifier {
            await transfers.recordTelemetry(
                id: snapshot.id,
                event: .backgroundHandoffCompleted
            )
        }
    }

    func allTasks(in session: URLSession) async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in continuation.resume(returning: tasks) }
        }
    }

    static func backgroundIdentifier(from options: ManagedTransferOptions) throws -> String {
        guard case .background(let identifier) = options.execution, !identifier.isEmpty else {
            throw ManagedTransferError.backgroundTransfersUnavailable
        }
        return identifier
    }

    static func applyNetworkPolicy(_ policy: TransferNetworkPolicy, to request: inout URLRequest) {
        request.allowsCellularAccess = policy.allowsCellularAccess
        if #available(iOS 13, macOS 10.15, watchOS 6, tvOS 13, *) {
            request.allowsExpensiveNetworkAccess = policy.allowsExpensiveNetworkAccess
            request.allowsConstrainedNetworkAccess = policy.allowsConstrainedNetworkAccess
        }
    }

    static func transferIdentity(from description: String?) -> TransferID? {
#if os(iOS) || os(macOS)
        BackgroundTransferSessionDelegate.transferIdentity(from: description)
#else
        description.map(TransferID.init(rawValue:))
#endif
    }

    static func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    static func verifyIntegrity(at url: URL, policy: TransferIntegrityPolicy) throws {
        let byteCount = fileSize(at: url)
        switch policy {
        case .none:
            return
        case .expectedByteCount(let expected):
            guard byteCount == expected else {
                throw ManagedTransferError.byteCountMismatch(expected: expected, actual: byteCount)
            }
        case .expectedSHA256(let expected):
            guard try SHA256Util.hex(fileAt: url).caseInsensitiveCompare(expected) == .orderedSame else {
                throw ManagedTransferError.checksumMismatch
            }
        case .expectedByteCountAndSHA256(let expected, let digest):
            guard byteCount == expected else {
                throw ManagedTransferError.byteCountMismatch(expected: expected, actual: byteCount)
            }
            guard try SHA256Util.hex(fileAt: url).caseInsensitiveCompare(digest) == .orderedSame else {
                throw ManagedTransferError.checksumMismatch
            }
        }
    }

    static func finalizeFile(
        from stagedURL: URL,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            switch policy {
            case .failIfExists:
                throw NetworkTransferError.destinationAlreadyExists(destinationURL)
            case .keepExisting:
                try FileManager.default.removeItem(at: stagedURL)
            case .replace:
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
            }
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    static func sanitizedReason(_ error: any Error) -> String {
        guard let managed = error as? ManagedTransferError else { return "file_failure" }
        switch managed {
        case .byteCountMismatch: return "byte_count_mismatch"
        case .checksumMismatch: return "checksum_mismatch"
        default: return "background_finalization_failed"
        }
    }

    static func defaultStagingDirectory() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("NovaNetwork/BackgroundStaging", isDirectory: true)
    }
}
