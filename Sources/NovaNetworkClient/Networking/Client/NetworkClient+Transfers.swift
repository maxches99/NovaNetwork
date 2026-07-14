import NovaNetworkCore
import Foundation

public extension NetworkClient {
    /// Uploads bytes through a transfer-capable transport.
    ///
    /// The returned stream emits progress and exactly one completion event. Stopping
    /// iteration or cancelling the consumer cancels the underlying operation.
    func upload(
        request: APIRequest,
        body: Data,
        authScope: String?,
        options: RequestExecutionOptions = .init()
    ) -> AsyncThrowingStream<UploadEvent, any Error> {
        guard let transferTransport = transport as? any TransferNetworkTransport else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NetworkError.invalidResponse)
            }
        }
        let key = makeFingerprint(for: request, authScope: authScope).key
        return AsyncThrowingStream { continuation in
            telemetryHooks?.onTransferEvent?(.init(kind: .upload, phase: .started, key: key))
            let consumer = Task {
                do {
                    let prepared = try await prepareRequestForExecution(request: request, key: key, options: options)
                    for try await event in transferTransport.upload(prepared, body: body) {
                        switch event {
                        case .progress(let progress):
                            telemetryHooks?.onTransferEvent?(
                                .init(
                                    kind: .upload,
                                    phase: .progress,
                                    key: key,
                                    completedBytes: progress.completedBytes,
                                    totalBytes: progress.totalBytes
                                )
                            )
                        case .completed:
                            telemetryHooks?.onTransferEvent?(.init(kind: .upload, phase: .completed, key: key))
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    let cancelled = error is CancellationError || (error as? NetworkError)?.failureReason == .cancelled
                    telemetryHooks?.onTransferEvent?(
                        .init(
                            kind: .upload,
                            phase: cancelled ? .cancelled : .failed,
                            key: key,
                            reason: String(describing: type(of: error))
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in consumer.cancel() }
        }
    }

    /// Downloads a request to a file through a transfer-capable transport.
    func download(
        request: APIRequest,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy = .failIfExists,
        authScope: String?,
        options: RequestExecutionOptions = .init()
    ) -> AsyncThrowingStream<DownloadEvent, any Error> {
        guard let transferTransport = transport as? any TransferNetworkTransport else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: NetworkError.invalidResponse)
            }
        }
        let key = makeFingerprint(for: request, authScope: authScope).key
        return AsyncThrowingStream { continuation in
            telemetryHooks?.onTransferEvent?(.init(kind: .download, phase: .started, key: key))
            let consumer = Task {
                do {
                    let prepared = try await prepareRequestForExecution(request: request, key: key, options: options)
                    for try await event in transferTransport.download(prepared, to: destinationURL, policy: policy) {
                        switch event {
                        case .progress(let progress):
                            telemetryHooks?.onTransferEvent?(
                                .init(
                                    kind: .download,
                                    phase: .progress,
                                    key: key,
                                    completedBytes: progress.completedBytes,
                                    totalBytes: progress.totalBytes
                                )
                            )
                        case .completed:
                            telemetryHooks?.onTransferEvent?(.init(kind: .download, phase: .completed, key: key))
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    let cancelled = error is CancellationError || (error as? NetworkError)?.failureReason == .cancelled
                    telemetryHooks?.onTransferEvent?(
                        .init(
                            kind: .download,
                            phase: cancelled ? .cancelled : .failed,
                            key: key,
                            reason: String(describing: type(of: error))
                        )
                    )
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in consumer.cancel() }
        }
    }
}
