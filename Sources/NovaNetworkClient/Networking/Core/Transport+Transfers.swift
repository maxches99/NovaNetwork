import NovaNetworkCore
import Foundation

private final class URLSessionTransferProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, Sendable {
    private let progressHandler: @Sendable (TransferProgress) -> Void

    init(progressHandler: @escaping @Sendable (TransferProgress) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progressHandler(
            TransferProgress(
                completedBytes: totalBytesSent,
                totalBytes: totalBytesExpectedToSend
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
        progressHandler(
            TransferProgress(
                completedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

public extension Transport {
    /// Streams URLSession response bytes in 64 KiB chunks on supported operating systems.
    func stream(_ request: APIRequest, authScope: String?) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let producer = Task {
                do {
                    let urlRequest = request.urlRequest()
                    if #available(iOS 15, macOS 12, watchOS 8, tvOS 15, *) {
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        let metadata = try Self.httpMetadata(from: response)
                        var chunk = Data()
                        chunk.reserveCapacity(65_536)
                        var errorBody = Data()

                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if (200..<300).contains(metadata.statusCode) {
                                chunk.append(byte)
                                if chunk.count == 65_536 {
                                    try await Self.yieldPreserving(chunk, to: continuation)
                                    chunk.removeAll(keepingCapacity: true)
                                }
                            } else {
                                errorBody.append(byte)
                            }
                        }

                        guard (200..<300).contains(metadata.statusCode) else {
                            throw NetworkError.httpStatus(
                                code: metadata.statusCode,
                                headers: metadata.headers,
                                body: errorBody
                            )
                        }
                        if !chunk.isEmpty {
                            try await Self.yieldPreserving(chunk, to: continuation)
                        }
                    } else {
                        let response = try await execute(request)
                        try await Self.yieldPreserving(response.body, to: continuation)
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
            continuation.onTermination = { _ in
                producer.cancel()
            }
        }
    }

    /// Uploads bytes with native URLSession progress callbacks.
    func upload(_ request: APIRequest, body: Data) -> AsyncThrowingStream<UploadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                let delegate = URLSessionTransferProgressDelegate { progress in
                    continuation.yield(.progress(progress))
                }
                do {
                    var urlRequest = request.urlRequest()
                    urlRequest.httpBody = nil
                    let networkResponse: NetworkResponse
                    if #available(iOS 15, macOS 12, watchOS 8, tvOS 15, *) {
                        let (data, response) = try await session.upload(
                            for: urlRequest,
                            from: body,
                            delegate: delegate
                        )
                        let metadata = try Self.httpMetadata(from: response)
                        guard (200..<300).contains(metadata.statusCode) else {
                            throw NetworkError.httpStatus(
                                code: metadata.statusCode,
                                headers: metadata.headers,
                                body: data
                            )
                        }
                        networkResponse = NetworkResponse(
                            statusCode: metadata.statusCode,
                            headers: metadata.headers,
                            body: data
                        )
                    } else {
                        let fallback = APIRequest(
                            method: request.method,
                            url: request.url,
                            queryItems: request.queryItems,
                            headers: request.headers,
                            body: body,
                            timeout: request.timeout
                        )
                        networkResponse = try await execute(fallback)
                        continuation.yield(
                            .progress(.init(completedBytes: Int64(body.count), totalBytes: Int64(body.count)))
                        )
                    }
                    continuation.yield(.completed(networkResponse))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: NetworkError.cancelled)
                } catch let error as NetworkError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: NetworkError.transport(underlying: error))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Uploads a file with native URLSession progress callbacks, streaming its contents from
    /// disk without buffering them in memory.
    func upload(_ request: APIRequest, fromFile fileURL: URL) -> AsyncThrowingStream<UploadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                let delegate = URLSessionTransferProgressDelegate { progress in
                    continuation.yield(.progress(progress))
                }
                do {
                    var urlRequest = request.urlRequest()
                    urlRequest.httpBody = nil
                    let networkResponse: NetworkResponse
                    if #available(iOS 15, macOS 12, watchOS 8, tvOS 15, *) {
                        let (data, response) = try await session.upload(
                            for: urlRequest,
                            fromFile: fileURL,
                            delegate: delegate
                        )
                        let metadata = try Self.httpMetadata(from: response)
                        guard (200..<300).contains(metadata.statusCode) else {
                            throw NetworkError.httpStatus(
                                code: metadata.statusCode,
                                headers: metadata.headers,
                                body: data
                            )
                        }
                        networkResponse = NetworkResponse(
                            statusCode: metadata.statusCode,
                            headers: metadata.headers,
                            body: data
                        )
                    } else {
                        let body = try Data(contentsOf: fileURL)
                        let fallback = APIRequest(
                            method: request.method,
                            url: request.url,
                            queryItems: request.queryItems,
                            headers: request.headers,
                            body: body,
                            timeout: request.timeout
                        )
                        networkResponse = try await execute(fallback)
                        continuation.yield(
                            .progress(.init(completedBytes: Int64(body.count), totalBytes: Int64(body.count)))
                        )
                    }
                    continuation.yield(.completed(networkResponse))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: NetworkError.cancelled)
                } catch let error as NetworkError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: NetworkError.transport(underlying: error))
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// Downloads a response to a destination with native URLSession progress callbacks.
    func download(
        _ request: APIRequest,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) -> AsyncThrowingStream<DownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                let delegate = URLSessionTransferProgressDelegate { progress in
                    continuation.yield(.progress(progress))
                }
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        switch policy {
                        case .failIfExists:
                            throw NetworkTransferError.destinationAlreadyExists(destinationURL)
                        case .keepExisting:
                            continuation.yield(
                                .completed(.init(fileURL: destinationURL, statusCode: 200, headers: [:]))
                            )
                            continuation.finish()
                            return
                        case .replace:
                            break
                        }
                    }

                    let temporaryURL: URL
                    let metadata: HTTPMetadata
                    if #available(iOS 15, macOS 12, watchOS 8, tvOS 15, *) {
                        let (nativeTemporaryURL, response) = try await session.download(
                            for: request.urlRequest(),
                            delegate: delegate
                        )
                        temporaryURL = nativeTemporaryURL
                        metadata = try Self.httpMetadata(from: response)
                        guard (200..<300).contains(metadata.statusCode) else {
                            throw NetworkError.httpStatus(
                                code: metadata.statusCode,
                                headers: metadata.headers,
                                body: Data()
                            )
                        }
                    } else {
                        let response = try await execute(request)
                        temporaryURL = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                        try response.body.write(to: temporaryURL, options: .atomic)
                        metadata = HTTPMetadata(statusCode: response.statusCode, headers: response.headers)
                        continuation.yield(
                            .progress(
                                .init(
                                    completedBytes: Int64(response.body.count),
                                    totalBytes: Int64(response.body.count)
                                )
                            )
                        )
                    }
                    defer { try? FileManager.default.removeItem(at: temporaryURL) }

                    let parent = destinationURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    do {
                        if FileManager.default.fileExists(atPath: destinationURL.path) {
                            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
                        } else {
                            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
                        }
                    } catch {
                        throw NetworkTransferError.destinationFinalizationFailed(destinationURL)
                    }

                    continuation.yield(
                        .completed(
                            DownloadedFile(
                                fileURL: destinationURL,
                                statusCode: metadata.statusCode,
                                headers: metadata.headers
                            )
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: NetworkError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

private extension Transport {
    struct HTTPMetadata {
        let statusCode: Int
        let headers: [String: String]
    }

    static func httpMetadata(from response: URLResponse) throws -> HTTPMetadata {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { partial, item in
            guard let key = item.key as? String else { return }
            partial[key] = String(describing: item.value)
        }
        return HTTPMetadata(statusCode: httpResponse.statusCode, headers: headers)
    }

    static func yieldPreserving(
        _ data: Data,
        to continuation: AsyncThrowingStream<Data, any Error>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(data) {
            case .enqueued:
                return
            case .dropped:
                await Task.yield()
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }
}
