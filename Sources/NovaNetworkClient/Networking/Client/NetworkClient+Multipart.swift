import NovaNetworkCore
import Foundation

public extension NetworkClient {
    /// Encodes `parts` as `multipart/form-data`, streams the encoded body to a private
    /// temporary file, uploads it, and removes the temporary file once the upload finishes
    /// (successfully, with an error, or cancelled). File parts are streamed from disk in fixed
    /// chunks; their contents are never fully buffered in memory.
    ///
    /// For a durable, resumable multipart upload, use ``MultipartFormDataEncoder`` directly
    /// instead of this method: write the encoded body to a stable file the app manages, merge
    /// the encoder's `contentType` into the request headers, and pass that file to
    /// `ManagedTransferManager.startUpload(request:sourceURL:)`.
    func uploadMultipart(
        method: URLMethod = .post,
        url: URL,
        queryItems: [URLQueryItem] = [],
        headers: [String: String] = [:],
        parts: [MultipartFormDataPart],
        authScope: String?,
        options: RequestExecutionOptions = .init(),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) -> AsyncThrowingStream<UploadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let encoder = MultipartFormDataEncoder(parts: parts)
                let bodyFileURL = temporaryDirectory.appendingPathComponent("nova-multipart-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: bodyFileURL) }

                do {
                    try encoder.write(to: bodyFileURL)

                    var resolvedHeaders = headers
                    if resolvedHeaders["Content-Type"] == nil {
                        resolvedHeaders["Content-Type"] = encoder.contentType
                    }
                    let request = APIRequest(
                        method: method,
                        url: url,
                        queryItems: queryItems,
                        headers: resolvedHeaders
                    )

                    for try await event in upload(
                        request: request,
                        fromFile: bodyFileURL,
                        authScope: authScope,
                        options: options
                    ) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: NetworkError.cancelled)
                } catch let error as NetworkError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: NetworkError.transport(underlying: error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
