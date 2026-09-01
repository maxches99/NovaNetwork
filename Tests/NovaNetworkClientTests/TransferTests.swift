import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

// Requirements: FR-XFER-1...4, EC-6...7, AR-2.

private final class TransferURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responseData = Data()
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(Self.responseData.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let split = min(70_000, Self.responseData.count)
        if split > 0 {
            client?.urlProtocol(self, didLoad: Self.responseData.prefix(split))
        }
        if split < Self.responseData.count {
            client?.urlProtocol(self, didLoad: Self.responseData.suffix(from: split))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeTransferSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TransferURLProtocol.self]
    return URLSession(configuration: configuration)
}

private actor TransferCancellationProbe {
    private var cancelled = false
    func markCancelled() { cancelled = true }
    func wasCancelled() -> Bool { cancelled }
}

private struct StubTransferTransport: TransferNetworkTransport, StreamingNetworkTransport {
    let cancellationProbe: TransferCancellationProbe?

    init(cancellationProbe: TransferCancellationProbe? = nil) {
        self.cancellationProbe = cancellationProbe
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func stream(_ request: APIRequest, authScope: String?) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await cancellationProbe?.markCancelled()
                    continuation.finish(throwing: NetworkError.cancelled)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func upload(_ request: APIRequest, body: Data) -> AsyncThrowingStream<UploadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(.init(completedBytes: Int64(body.count), totalBytes: Int64(body.count))))
            continuation.yield(.completed(.init(statusCode: 201, headers: [:], body: Data("uploaded".utf8))))
            continuation.finish()
        }
    }

    func download(
        _ request: APIRequest,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) -> AsyncThrowingStream<DownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await cancellationProbe?.markCancelled()
                    continuation.finish(throwing: NetworkError.cancelled)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}

private actor TransferTelemetryProbe {
    private var contexts: [TelemetryTransferContext] = []
    func append(_ context: TelemetryTransferContext) { contexts.append(context) }
    func phases() -> [TelemetryTransferContext.Phase] { contexts.map(\.phase) }
}

@Suite(.serialized)
struct TransferTests {
    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func defaultTransportStreamsLargeResponseIncrementally() async throws {
        let expected = Data((0..<180_000).map { UInt8($0 % 251) })
        TransferURLProtocol.responseData = expected
        TransferURLProtocol.statusCode = 200
        let transport = Transport(session: makeTransferSession())
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/stream")!)
        var chunks: [Data] = []

        for try await chunk in transport.stream(request, authScope: nil) {
            chunks.append(chunk)
        }

        #expect(chunks.count >= 2)
        #expect(chunks.reduce(into: Data()) { $0.append($1) } == expected)
    }

    @Test
    func defaultTransportUploadsAndReturnsHTTPResponse() async throws {
        TransferURLProtocol.responseData = Data("accepted".utf8)
        TransferURLProtocol.statusCode = 201
        let transport = Transport(session: makeTransferSession())
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/upload")!)
        var completed: NetworkResponse?

        for try await event in transport.upload(request, body: Data("payload".utf8)) {
            if case .completed(let response) = event {
                completed = response
            }
        }

        #expect(completed?.statusCode == 201)
        #expect(completed?.body == Data("accepted".utf8))
    }

    // Crashes inside libFoundationNetworking on Linux (URLSession.download ->
    // _ProtocolClient.urlProtocolDidFinishLoading), taking the whole test process with it.
    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func defaultTransportDownloadsAndFinalizesDestination() async throws {
        let expected = Data("downloaded-file".utf8)
        TransferURLProtocol.responseData = expected
        TransferURLProtocol.statusCode = 200
        let transport = Transport(session: makeTransferSession())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("asset.bin")
        defer { try? FileManager.default.removeItem(at: root) }
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/download")!)
        var completedURL: URL?

        for try await event in transport.download(request, to: destination, policy: .failIfExists) {
            if case .completed(let file) = event {
                completedURL = file.fileURL
            }
        }

        #expect(completedURL == destination)
        #expect(try Data(contentsOf: destination) == expected)
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason))
    func existingDownloadDestinationFailsWithoutNetworkMutation() async throws {
        let transport = Transport(session: makeTransferSession())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("existing.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/download")!)

        do {
            for try await _ in transport.download(request, to: destination, policy: .failIfExists) {}
            Issue.record("Expected destination conflict")
        } catch let error as NetworkTransferError {
            #expect(error == .destinationAlreadyExists(destination))
        }
        #expect(try Data(contentsOf: destination) == Data("existing".utf8))
    }

    @Test(.enabled(if: PlatformSupport.hasAppleURLSessionBehaviour, PlatformSupport.urlSessionReason), arguments: [DownloadDestinationPolicy.replace, .keepExisting])
    func existingDownloadDestinationHonorsNonFailingPolicies(
        policy: DownloadDestinationPolicy
    ) async throws {
        TransferURLProtocol.responseData = Data("replacement".utf8)
        TransferURLProtocol.statusCode = 200
        let transport = Transport(session: makeTransferSession())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = root.appendingPathComponent("existing.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/download")!)

        for try await _ in transport.download(request, to: destination, policy: policy) {}

        let expected = policy == .replace ? Data("replacement".utf8) : Data("existing".utf8)
        #expect(try Data(contentsOf: destination) == expected)
    }

    @Test
    func clientUploadForwardsProgressCompletionAndTelemetry() async throws {
        let telemetry = TransferTelemetryProbe()
        let hooks = NetworkTelemetryHooks(onTransferEvent: { context in
            Task { await telemetry.append(context) }
        })
        let client = NetworkClient(transport: StubTransferTransport(), telemetryHooks: hooks)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/upload")!)
        var sawProgress = false
        var sawCompletion = false

        for try await event in client.upload(
            request: request,
            body: Data("payload".utf8),
            authScope: "user:1"
        ) {
            switch event {
            case .progress:
                sawProgress = true
            case .completed:
                sawCompletion = true
            }
        }

        for _ in 0..<100 {
            if await telemetry.phases().contains(.completed) { break }
            await Task.yield()
        }
        #expect(sawProgress)
        #expect(sawCompletion)
        #expect(await telemetry.phases().contains(.started))
        #expect(await telemetry.phases().contains(.progress))
        #expect(await telemetry.phases().contains(.completed))
    }

    @Test
    func terminatingClientDownloadCancelsUnderlyingTransfer() async {
        let cancellation = TransferCancellationProbe()
        let client = NetworkClient(transport: StubTransferTransport(cancellationProbe: cancellation))
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/download")!)
        let stream = client.download(
            request: request,
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            authScope: nil
        )
        let consumer = Task {
            for try await _ in stream {}
        }

        for _ in 0..<20 { await Task.yield() }
        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<200 {
            if await cancellation.wasCancelled() { break }
            await Task.yield()
        }

        #expect(await cancellation.wasCancelled())
    }

    @Test
    func terminatingClientStreamCancelsUnderlyingTransfer() async {
        let cancellation = TransferCancellationProbe()
        let client = NetworkClient(transport: StubTransferTransport(cancellationProbe: cancellation))
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/stream")!)
        let consumer = Task {
            for try await _ in client.loadStream(request: request, authScope: nil) {}
        }

        for _ in 0..<20 { await Task.yield() }
        consumer.cancel()
        _ = await consumer.result
        for _ in 0..<200 {
            if await cancellation.wasCancelled() { break }
            await Task.yield()
        }

        #expect(await cancellation.wasCancelled())
    }
}
