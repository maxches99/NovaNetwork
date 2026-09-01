import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

// Requirements: FR-MP-1 (streamed encoding), FR-MP-2 (transport), FR-MP-3 (client convenience).

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private final class MultipartURLProtocol: URLProtocol {
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
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeMultipartSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MultipartURLProtocol.self]
    return URLSession(configuration: configuration)
}

/// A `TransferNetworkTransport` conformer implementing only the `body:`-based upload overload,
/// to exercise the protocol's default `fromFile:` extension.
private final class DataOnlyTransferTransport: TransferNetworkTransport, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "DataOnlyTransferTransport.state")
    private var storedReceivedBody: Data?

    var receivedBody: Data? { stateQueue.sync { storedReceivedBody } }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func upload(_ request: APIRequest, body: Data) -> AsyncThrowingStream<UploadEvent, any Error> {
        stateQueue.sync { storedReceivedBody = body }
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(NetworkResponse(statusCode: 200, headers: [:], body: Data())))
            continuation.finish()
        }
    }

    func download(
        _ request: APIRequest,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) -> AsyncThrowingStream<DownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: NetworkError.invalidResponse) }
    }
}

/// A stub capturing the request and file contents passed to `upload(_:fromFile:)`, for
/// asserting on encoded multipart bodies without any real networking.
private final class CapturingFileUploadTransport: TransferNetworkTransport, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "CapturingFileUploadTransport.state")
    private var capturedRequest: APIRequest?
    private var capturedBody: Data?
    private var capturedFileURL: URL?

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }

    func upload(_ request: APIRequest, body: Data) -> AsyncThrowingStream<UploadEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: NetworkError.invalidResponse) }
    }

    func upload(_ request: APIRequest, fromFile fileURL: URL) -> AsyncThrowingStream<UploadEvent, any Error> {
        let body = try? Data(contentsOf: fileURL)
        stateQueue.sync {
            capturedRequest = request
            capturedBody = body
            capturedFileURL = fileURL
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.progress(.init(completedBytes: Int64(body?.count ?? 0), totalBytes: nil)))
            continuation.yield(.completed(NetworkResponse(statusCode: 200, headers: [:], body: Data())))
            continuation.finish()
        }
    }

    func download(
        _ request: APIRequest,
        to destinationURL: URL,
        policy: DownloadDestinationPolicy
    ) -> AsyncThrowingStream<DownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: NetworkError.invalidResponse) }
    }

    func request() -> APIRequest? { stateQueue.sync { capturedRequest } }
    func body() -> Data? { stateQueue.sync { capturedBody } }
    func fileURL() -> URL? { stateQueue.sync { capturedFileURL } }
}

@Suite
struct MultipartFormDataEncoderTests {
    @Test
    func encodesSingleTextPartWithExpectedWireFormat() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("body.bin")

        let encoder = MultipartFormDataEncoder(parts: [.text(name: "field", value: "value")], boundary: "B")
        let written = try encoder.write(to: destination)
        let output = try String(contentsOf: destination, encoding: .utf8)

        let expected = "--B\r\n" +
            "Content-Disposition: form-data; name=\"field\"\r\n\r\n" +
            "value\r\n" +
            "--B--\r\n"
        #expect(output == expected)
        #expect(written == Int64(expected.utf8.count))
        #expect(encoder.contentType == "multipart/form-data; boundary=B")
    }

    @Test
    func encodesDataPartWithFilenameAndContentType() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("body.bin")

        let encoder = MultipartFormDataEncoder(
            parts: [.data(name: "meta", filename: "meta.json", contentType: "application/json", data: Data("{}".utf8))],
            boundary: "B"
        )
        try encoder.write(to: destination)
        let output = try String(contentsOf: destination, encoding: .utf8)

        let expected = "--B\r\n" +
            "Content-Disposition: form-data; name=\"meta\"; filename=\"meta.json\"\r\n" +
            "Content-Type: application/json\r\n\r\n" +
            "{}\r\n" +
            "--B--\r\n"
        #expect(output == expected)
    }

    @Test
    func encodesMultiplePartsInOrderWithSharedBoundary() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("body.bin")

        let encoder = MultipartFormDataEncoder(
            parts: [.text(name: "a", value: "1"), .text(name: "b", value: "2")],
            boundary: "B"
        )
        try encoder.write(to: destination)
        let output = try String(contentsOf: destination, encoding: .utf8)

        let expected = "--B\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" +
            "--B\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n2\r\n" +
            "--B--\r\n"
        #expect(output == expected)
    }

    @Test
    func streamsFilePartFromDiskByteForByteAcrossChunkBoundaries() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("body.bin")

        // Larger than the encoder's internal 64 KiB chunk size, to exercise multi-chunk streaming.
        let sourceBytes = Data((0..<150_000).map { UInt8($0 % 251) })
        try sourceBytes.write(to: sourceURL)

        let encoder = MultipartFormDataEncoder(
            parts: [.file(name: "upload", filename: "source.bin", contentType: "application/octet-stream", fileURL: sourceURL)],
            boundary: "B"
        )
        try encoder.write(to: destination)

        let output = try Data(contentsOf: destination)
        let header = Data((
            "--B\r\n" +
            "Content-Disposition: form-data; name=\"upload\"; filename=\"source.bin\"\r\n" +
            "Content-Type: application/octet-stream\r\n\r\n"
        ).utf8)
        let footer = Data("\r\n--B--\r\n".utf8)

        #expect(output.count == header.count + sourceBytes.count + footer.count)
        #expect(output.prefix(header.count) == header)
        #expect(output[header.count..<(header.count + sourceBytes.count)] == sourceBytes)
        #expect(output.suffix(footer.count) == footer)
    }

    @Test
    func contentLengthMatchesActualWrittenByteCount() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("source.bin")
        let destination = root.appendingPathComponent("body.bin")
        try Data((0..<10_000).map { UInt8($0 % 251) }).write(to: sourceURL)

        let encoder = MultipartFormDataEncoder(
            parts: [
                .text(name: "field", value: "value"),
                .file(name: "upload", filename: "source.bin", contentType: "application/octet-stream", fileURL: sourceURL),
            ],
            boundary: "B"
        )

        let predicted = try encoder.contentLength()
        let written = try encoder.write(to: destination)
        #expect(predicted == written)
    }

    @Test
    func escapesQuotesAndStripsCRLFFromNameAndFilename() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("body.bin")

        // A filename attempting header/part injection must not break out of its quoted value.
        let encoder = MultipartFormDataEncoder(
            parts: [.data(name: "f", filename: "evil\".jpg\r\nX-Injected: 1\r\n", contentType: nil, data: Data())],
            boundary: "B"
        )
        try encoder.write(to: destination)
        let output = try String(contentsOf: destination, encoding: .utf8)

        // The injected text survives as inert literal content trapped inside the quoted
        // filename attribute; what matters is that it never becomes its own header line.
        #expect(!output.contains("\r\nX-Injected"))
        #expect(output.contains("filename=\"evil%22.jpgX-Injected: 1\""))
    }

    @Test
    func throwsSourceFileUnreadableForMissingFile() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.bin")
        let destination = root.appendingPathComponent("body.bin")

        let encoder = MultipartFormDataEncoder(
            parts: [.file(name: "upload", filename: "missing.bin", fileURL: missing)]
        )
        #expect(throws: MultipartFormDataError.sourceFileUnreadable(missing)) {
            try encoder.write(to: destination)
        }
        #expect(throws: MultipartFormDataError.sourceFileUnreadable(missing)) {
            try encoder.contentLength()
        }
    }

    @Test
    func generatesARandomBoundaryWhenNoneSupplied() {
        let first = MultipartFormDataEncoder(parts: [])
        let second = MultipartFormDataEncoder(parts: [])
        #expect(first.boundary != second.boundary)
    }
}

@Suite
struct FileUploadTransportTests {
    @Test
    func defaultProtocolExtensionReadsFileAndDelegatesToBodyUpload() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("payload.bin")
        try Data("hello from disk".utf8).write(to: fileURL)

        let transport = DataOnlyTransferTransport()
        var completed = false
        for try await event in transport.upload(APIRequest(method: .post, url: URL(string: "https://example.com")!), fromFile: fileURL) {
            if case .completed = event { completed = true }
        }

        #expect(completed)
        #expect(transport.receivedBody == Data("hello from disk".utf8))
    }

    @Test
    func defaultTransportUploadsFileStreamedFromDiskAndReturnsResponse() async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("payload.bin")
        try Data((0..<20_000).map { UInt8($0 % 251) }).write(to: fileURL)

        MultipartURLProtocol.responseData = Data("accepted".utf8)
        MultipartURLProtocol.statusCode = 201
        let transport = Transport(session: makeMultipartSession())
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/upload")!)

        // URLProtocol-mocked uploads do not reliably drive didSendBodyData progress callbacks
        // (matching TransferTests.swift's equivalent body-based upload test), so this only
        // asserts the completed response, which is what URLSession.upload(for:fromFile:) itself
        // is responsible for.
        var completed: NetworkResponse?
        for try await event in transport.upload(request, fromFile: fileURL) {
            if case .completed(let response) = event {
                completed = response
            }
        }

        #expect(completed?.statusCode == 201)
        #expect(completed?.body == Data("accepted".utf8))
    }
}

@Suite
struct NetworkClientMultipartTests {
    @Test
    func uploadFromFileFailsImmediatelyWhenTransportUnsupported() async throws {
        let client = NetworkClient(transport: GenericThrowingTransport(error: DummyError.boom))
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("payload.bin")
        try Data("x".utf8).write(to: fileURL)

        await #expect(throws: (any Error).self) {
            for try await _ in client.upload(request: APIRequest(method: .post, url: URL(string: "https://example.com")!), fromFile: fileURL, authScope: nil) {}
        }
    }

    @Test
    func uploadMultipartBuildsExpectedRequestAndCleansUpTemporaryFile() async throws {
        let transport = CapturingFileUploadTransport()
        let client = NetworkClient(transport: transport)
        let tempDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var completed = false
        for try await event in client.uploadMultipart(
            url: URL(string: "https://example.com/upload")!,
            headers: ["Authorization": "Bearer token"],
            parts: [.text(name: "field", value: "value")],
            authScope: "user:1",
            temporaryDirectory: tempDirectory
        ) {
            if case .completed = event { completed = true }
        }

        #expect(completed)
        let request = transport.request()
        #expect(request?.headers["Authorization"] == "Bearer token")
        let contentType = request?.headers["Content-Type"]
        #expect(contentType?.hasPrefix("multipart/form-data; boundary=") == true)

        let body = transport.body()
        #expect(body.map { String(data: $0, encoding: .utf8) ?? "" }?.contains("name=\"field\"") == true)
        #expect(body.map { String(data: $0, encoding: .utf8) ?? "" }?.contains("value") == true)

        // The temporary encoded body file is removed once the upload stream finishes. Removal
        // happens after the final event rather than before it, so wait for the file to go instead
        // of assuming it is already gone -- the latter fails whenever the machine is busy.
        if let capturedURL = transport.fileURL() {
            await waitForFileToDisappear(at: capturedURL)
            #expect(!FileManager.default.fileExists(atPath: capturedURL.path))
        }
    }

    @Test
    func uploadMultipartDoesNotOverrideCallerSuppliedContentType() async throws {
        let transport = CapturingFileUploadTransport()
        let client = NetworkClient(transport: transport)
        let tempDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        for try await _ in client.uploadMultipart(
            url: URL(string: "https://example.com/upload")!,
            headers: ["Content-Type": "multipart/form-data; boundary=custom"],
            parts: [.text(name: "field", value: "value")],
            authScope: nil,
            temporaryDirectory: tempDirectory
        ) {}

        let request = transport.request()
        #expect(request?.headers["Content-Type"] == "multipart/form-data; boundary=custom")
    }

    @Test
    func uploadMultipartStreamsFilePartWithoutBufferingWholeContentInAPIRequest() async throws {
        let transport = CapturingFileUploadTransport()
        let client = NetworkClient(transport: transport)
        let tempDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let sourceURL = tempDirectory.appendingPathComponent("source.bin")
        let sourceBytes = Data((0..<80_000).map { UInt8($0 % 251) })
        try sourceBytes.write(to: sourceURL)

        for try await _ in client.uploadMultipart(
            url: URL(string: "https://example.com/upload")!,
            parts: [.file(name: "upload", filename: "source.bin", contentType: "application/octet-stream", fileURL: sourceURL)],
            authScope: nil,
            temporaryDirectory: tempDirectory
        ) {}

        // APIRequest.body stays nil: the encoded multipart body only ever exists as a file on
        // disk, never as an in-memory Data payload attached to the request itself.
        let request = transport.request()
        #expect(request?.body == nil)
        let body = transport.body()
        #expect(body?.count ?? 0 > sourceBytes.count)
    }

    @Test
    func uploadMultipartCleansUpTemporaryFileOnFailure() async throws {
        let transport = GenericThrowingTransport(error: NetworkError.transport(underlying: DummyError.boom))
        let client = NetworkClient(transport: transport)
        let tempDirectory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        do {
            for try await _ in client.uploadMultipart(
                url: URL(string: "https://example.com/upload")!,
                parts: [.text(name: "field", value: "value")],
                authScope: nil,
                temporaryDirectory: tempDirectory
            ) {}
            Issue.record("expected the upload to throw")
        } catch {}

        let leftoverFiles = try FileManager.default.contentsOfDirectory(atPath: tempDirectory.path)
        #expect(leftoverFiles.isEmpty)
    }
}

/// Waits for a file to be removed, up to a deadline.
///
/// The multipart upload deletes its temporary body file after the stream's final event, so a test
/// that checks immediately is racing the cleanup rather than testing it.
private func waitForFileToDisappear(at url: URL, timeout: Duration = .seconds(5)) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if !FileManager.default.fileExists(atPath: url.path) { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}
