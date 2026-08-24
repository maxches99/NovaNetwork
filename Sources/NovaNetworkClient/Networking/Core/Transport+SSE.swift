import NovaNetworkCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Transport: ServerSentEventTransport {
    /// Streams and incrementally parses a `text/event-stream` response.
    ///
    /// Falls back to parsing one complete response on operating system versions that predate
    /// `URLSession.bytes(for:)`, matching ``stream(_:authScope:)``'s fallback behavior.
    public func serverSentEventElements(
        _ request: APIRequest,
        authScope: String?
    ) -> AsyncThrowingStream<SSEParsedElement, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { continuation in
            let producer = Task {
                do {
                    var urlRequest = request.urlRequest()
                    if urlRequest.value(forHTTPHeaderField: "Accept") == nil {
                        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    }

                    // `URLSession.bytes(for:)` does not exist in swift-corelibs-foundation, so Linux
                    // always takes the single-response fallback below, the same one used on
                    // operating system versions that predate the streaming API.
                    #if !canImport(FoundationNetworking)
                    if #available(iOS 15, macOS 12, watchOS 8, tvOS 15, *) {
                        let (bytes, response) = try await session.bytes(for: urlRequest)
                        guard let httpResponse = response as? HTTPURLResponse else {
                            throw NetworkError.invalidResponse
                        }
                        guard (200..<300).contains(httpResponse.statusCode) else {
                            var errorBody = Data()
                            for try await byte in bytes {
                                errorBody.append(byte)
                            }
                            throw NetworkError.httpStatus(
                                code: httpResponse.statusCode,
                                headers: Self.headerDictionary(from: httpResponse),
                                body: errorBody
                            )
                        }

                        var decoder = SSEDecoder()
                        var chunk = Data()
                        chunk.reserveCapacity(4_096)
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            chunk.append(byte)
                            guard chunk.count >= 4_096 else { continue }
                            for element in decoder.decode(chunk) {
                                try await Self.yieldPreserving(element, to: continuation)
                            }
                            chunk.removeAll(keepingCapacity: true)
                        }
                        if !chunk.isEmpty {
                            for element in decoder.decode(chunk) {
                                try await Self.yieldPreserving(element, to: continuation)
                            }
                        }
                        if let final = decoder.flush() {
                            try await Self.yieldPreserving(final, to: continuation)
                        }
                    } else {
                        try await singleResponseFallback(request, to: continuation)
                    }
                    #else
                    try await singleResponseFallback(request, to: continuation)
                    #endif
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

    private func singleResponseFallback(
        _ request: APIRequest,
        to continuation: AsyncThrowingStream<SSEParsedElement, any Error>.Continuation
    ) async throws {
        let response = try await execute(request)
        var decoder = SSEDecoder()
        for element in decoder.decode(response.body) {
            try await Self.yieldPreserving(element, to: continuation)
        }
        if let final = decoder.flush() {
            try await Self.yieldPreserving(final, to: continuation)
        }
    }
}

private extension Transport {
    static func headerDictionary(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [String: String]()) { partial, item in
            guard let key = item.key as? String else { return }
            partial[key] = String(describing: item.value)
        }
    }

    static func yieldPreserving(
        _ element: SSEParsedElement,
        to continuation: AsyncThrowingStream<SSEParsedElement, any Error>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(element) {
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
