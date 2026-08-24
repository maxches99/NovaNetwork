import Foundation

/// Byte-level progress for an upload or download operation.
public struct TransferProgress: Sendable, Equatable {
    /// Number of bytes transferred so far.
    public let completedBytes: Int64

    /// Expected total byte count, or `nil` when the server does not provide one.
    public let totalBytes: Int64?

    /// Fraction completed in `0...1`, or `nil` when the total is unknown.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    /// Creates a transfer progress value.
    public init(completedBytes: Int64, totalBytes: Int64?) {
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Events produced while uploading a request body.
public enum UploadEvent: Sendable {
    /// Updated body transfer progress.
    case progress(TransferProgress)

    /// Terminal successful HTTP response.
    case completed(NetworkResponse)
}

/// Policy applied when a download destination already exists.
public enum DownloadDestinationPolicy: Sendable, Equatable {
    /// Fail without modifying the existing file.
    case failIfExists

    /// Atomically replace the existing file after a successful download.
    case replace

    /// Preserve the existing file and return it as the completed destination.
    case keepExisting
}

/// Metadata returned after a successful file download.
public struct DownloadedFile: Sendable {
    /// Final file URL visible to the caller.
    public let fileURL: URL

    /// HTTP status code associated with the downloaded response.
    public let statusCode: Int

    /// HTTP response headers.
    public let headers: [String: String]

    /// Creates completed download metadata.
    public init(fileURL: URL, statusCode: Int, headers: [String: String]) {
        self.fileURL = fileURL
        self.statusCode = statusCode
        self.headers = headers
    }
}

/// Events produced while downloading a response to a file.
public enum DownloadEvent: Sendable {
    /// Updated response transfer progress.
    case progress(TransferProgress)

    /// Terminal successful destination metadata.
    case completed(DownloadedFile)
}

/// Transfer-specific errors detected outside the normal HTTP response mapping.
public enum NetworkTransferError: Error, Sendable, Equatable {
    /// The requested destination already exists and replacement was not allowed.
    case destinationAlreadyExists(URL)

    /// The temporary download could not be finalized at the destination.
    case destinationFinalizationFailed(URL)
}

/// Transport capability for native upload and file download operations.
public protocol TransferNetworkTransport: NetworkTransport {
    /// Uploads request body bytes and emits progress plus one completion event.
    func upload(_ request: APIRequest, body: Data) -> AsyncThrowingStream<UploadEvent, any Error>

    /// Uploads a request body streamed from a file, without buffering its contents in memory.
    ///
    /// Conformers that can stream directly from disk (like the default `Transport`) should
    /// override this; the default implementation reads the file into memory and delegates to
    /// the `body:`-based overload, so existing conformers remain source-compatible.
    func upload(_ request: APIRequest, fromFile fileURL: URL) -> AsyncThrowingStream<UploadEvent, any Error>

    /// Downloads a response to a final destination and emits progress plus one completion event.
    func download(
        _ request: APIRequest,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) -> AsyncThrowingStream<DownloadEvent, any Error>
}

public extension TransferNetworkTransport {
    /// Reads the file into memory and delegates to the `Data`-based upload overload.
    func upload(_ request: APIRequest, fromFile fileURL: URL) -> AsyncThrowingStream<UploadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let data = try Data(contentsOf: fileURL)
                    for try await event in upload(request, body: data) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: NetworkError.transport(underlying: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Telemetry emitted for transfer lifecycle changes.
public struct TelemetryTransferContext: Sendable {
    /// Transfer operation kind.
    public enum Kind: String, Sendable {
        /// Request body upload.
        case upload
        /// Response file download.
        case download
        /// Incremental response body stream.
        case stream
    }

    /// Transfer lifecycle phase.
    public enum Phase: String, Sendable {
        /// Transfer work started.
        case started
        /// Byte progress was observed.
        case progress
        /// Transfer completed successfully.
        case completed
        /// Transfer failed.
        case failed
        /// Transfer was cancelled.
        case cancelled
    }

    /// Operation kind.
    public let kind: Kind

    /// Current lifecycle phase.
    public let phase: Phase

    /// Stable request fingerprint key.
    public let key: String

    /// Completed bytes when known.
    public let completedBytes: Int64?

    /// Total bytes when known.
    public let totalBytes: Int64?

    /// Sanitized failure reason; credential and header values are never included.
    public let reason: String?

    /// Creates transfer telemetry.
    public init(
        kind: Kind,
        phase: Phase,
        key: String,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.phase = phase
        self.key = key
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.reason = reason
    }
}
