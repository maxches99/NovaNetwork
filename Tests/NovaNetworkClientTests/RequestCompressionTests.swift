import Foundation
#if canImport(Compression)
import Compression
#endif
import Testing
@testable import NovaNetworkClient
import NovaNetworkCore

// Requirements: FR-COMPRESS-1…5, EC-COMPRESS-1…4, AR-COMPRESS-1…2
// (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §D). Tests: T-21.1…T-21.7.

private let syncURL = URL(string: "https://sync.example.com/batch")!
private let largeJSON = Data(String(repeating: #"{"event":"opened","screen":"home"},"#, count: 200).utf8)

private final class CompressionEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [RequestCompressionEvent] = []

    func record(_ event: RequestCompressionEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var all: [RequestCompressionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private func send(
    _ request: APIRequest,
    through policy: RequestCompressionPolicy,
    events: CompressionEvents = CompressionEvents()
) async throws -> APIRequest {
    let middleware = NetworkMiddleware.compressingRequestBodies(policy) { events.record($0) }
    return try await middleware.beforeSend!(request, nil)
}

private func post(
    _ body: Data?,
    url: URL = syncURL,
    headers: [String: String] = ["Content-Type": "application/json"]
) -> APIRequest {
    APIRequest(method: .post, url: url, headers: headers, body: body)
}

#if canImport(Compression)
/// Undoes raw DEFLATE, so a test can check that what was sent decodes to what was meant.
private func inflate(_ deflated: Data, expectedSize: Int) -> Data? {
    var output = Data(count: expectedSize + 1)
    let written = output.withUnsafeMutableBytes { destination in
        deflated.withUnsafeBytes { source in
            compression_decode_buffer(
                destination.bindMemory(to: UInt8.self).baseAddress!,
                expectedSize + 1,
                source.bindMemory(to: UInt8.self).baseAddress!,
                deflated.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard written > 0 else { return nil }
    output.count = written
    return output
}

private func uint32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
    let bytes = Array(data[data.startIndex + offset ..< data.startIndex + offset + 4])
    let ordered = bigEndian ? bytes : bytes.reversed()
    return ordered.reduce(0) { ($0 << 8) | UInt32($1) }
}

@Suite
struct RequestCompressionTests {
    @Test // T-21.1
    func aLargeJSONBodyIsSentAsGzipThatDecodesToTheOriginal() async throws {
        let events = CompressionEvents()
        let sent = try await send(post(largeJSON), through: RequestCompressionPolicy(hosts: ["sync.example.com"]), events: events)
        let body = try #require(sent.body)

        #expect(sent.headers["Content-Encoding"] == "gzip")
        #expect(sent.headers["Content-Type"] == "application/json")
        #expect(body.count < largeJSON.count / 5)
        #expect(Array(body.prefix(3)) == [0x1f, 0x8b, 0x08])
        // Trailer: CRC-32 and size of the original, little-endian.
        #expect(uint32(body, at: body.count - 8, bigEndian: false) == RequestBodyCompressor.crc32(largeJSON))
        #expect(uint32(body, at: body.count - 4, bigEndian: false) == UInt32(largeJSON.count))
        let deflated = body.dropFirst(10).dropLast(8)
        #expect(inflate(Data(deflated), expectedSize: largeJSON.count) == largeJSON)
        #expect(events.all == [
            .compressed(url: syncURL, encoding: .gzip, originalBytes: largeJSON.count, compressedBytes: body.count),
        ])
    }

    @Test // T-21.2
    func deflateMeansAZlibStreamAndTheChecksumsMatchTheirReferenceValues() async throws {
        let sent = try await send(post(largeJSON), through: RequestCompressionPolicy(hosts: ["sync.example.com"], encoding: .deflate))
        let body = try #require(sent.body)

        #expect(sent.headers["Content-Encoding"] == "deflate")
        #expect(Array(body.prefix(2)) == [0x78, 0x9c])
        #expect((UInt16(body[body.startIndex]) << 8 | UInt16(body[body.startIndex + 1])) % 31 == 0)
        #expect(uint32(body, at: body.count - 4, bigEndian: true) == RequestBodyCompressor.adler32(largeJSON))
        #expect(inflate(Data(body.dropFirst(2).dropLast(4)), expectedSize: largeJSON.count) == largeJSON)

        // The standard check values for each algorithm.
        #expect(RequestBodyCompressor.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(RequestBodyCompressor.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(RequestBodyCompressor.crc32(Data()) == 0)
    }

    @Test // T-21.3
    func eachRuleThatSaysNoSendsTheBodyUnchangedAndSaysWhy() async throws {
        let policy = RequestCompressionPolicy(hosts: ["SYNC.example.com"])
        let cases: [(APIRequest, RequestCompressionEvent.SkipReason)] = [
            (post(largeJSON, url: URL(string: "https://api.other.com/x")!), .hostNotListed),
            (post(Data("{}".utf8)), .tooSmall),
            (post(largeJSON, headers: ["Content-Type": "application/json", "content-encoding": "br"]), .alreadyEncoded),
            (post(largeJSON, headers: ["Content-Type": "multipart/form-data; boundary=x"]), .notCompressible),
            (post(largeJSON, headers: ["Content-Type": "image/png"]), .notCompressible),
        ]

        for (request, reason) in cases {
            let events = CompressionEvents()
            let sent = try await send(request, through: policy, events: events)
            #expect(sent.body == request.body, "\(reason)")
            #expect(sent.headers == request.headers, "\(reason)")
            #expect(events.all == [.skipped(url: request.url, reason: reason)], "\(reason)")
        }

        // The host matched case-insensitively, and these content types count as compressible.
        for type in ["text/plain", "application/problem+json", "application/xml", "application/atom+xml",
                     "application/x-www-form-urlencoded", "application/graphql; charset=utf-8"] {
            #expect(RequestCompressionPolicy.isCompressible(contentType: type), "\(type)")
        }
        #expect(RequestCompressionPolicy.isCompressible(contentType: nil))
        let sent = try await send(post(largeJSON, headers: [:]), through: policy)
        #expect(sent.headers["Content-Encoding"] == "gzip")
    }

    @Test // T-21.4
    func dataThatDoesNotCompressIsSentAsItIs() async throws {
        var generator = SystemRandomNumberGenerator()
        let noise = Data((0..<4_096).map { _ in UInt8.random(in: 0...255, using: &generator) })
        let events = CompressionEvents()

        let sent = try await send(post(noise, headers: ["Content-Type": "text/plain"]), through: .anyHost(), events: events)

        #expect(sent.body == noise)
        #expect(sent.headers["Content-Encoding"] == nil)
        #expect(events.all == [.skipped(url: syncURL, reason: .notSmaller)])
    }

    @Test // T-21.5
    func anEligibilityRuleReplacesTheContentTypeRule() async throws {
        let onlyBatches = RequestCompressionPolicy.anyHost(isEligible: { $0.url.path.hasSuffix("/batch") })

        let png = try await send(post(largeJSON, headers: ["Content-Type": "image/png"]), through: onlyBatches)
        #expect(png.headers["Content-Encoding"] == "gzip")

        let events = CompressionEvents()
        let other = try await send(post(largeJSON, url: URL(string: "https://sync.example.com/other")!), through: onlyBatches, events: events)
        #expect(other.headers["Content-Encoding"] == nil)
        #expect(events.all == [.skipped(url: URL(string: "https://sync.example.com/other")!, reason: .notCompressible)])
    }

    @Test // T-21.6
    func aRequestWithNoBodyPassesSilentlyAndANegativeMinimumIsZero() async throws {
        let events = CompressionEvents()
        let get = APIRequest(method: .get, url: syncURL)
        #expect(try await send(get, through: .anyHost(), events: events).body == nil)
        #expect(try await send(post(Data()), through: .anyHost(), events: events).body == Data())
        #expect(events.all.isEmpty)

        let policy = RequestCompressionPolicy.anyHost(minimumBodyBytes: -10)
        #expect(policy.minimumBodyBytes == 0)
        #expect(policy.hosts == nil)
        #expect(RequestCompressionPolicy(hosts: ["A.com"]).hosts == ["a.com"])
    }
}

private actor RecordingTransport: NetworkTransport {
    private(set) var received: [APIRequest] = []

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        received.append(request)
        return NetworkResponse(statusCode: 200, headers: [:], body: Data())
    }
}

@Suite
struct RequestCompressionClientTests {
    @Test // T-21.7
    func aSigningMiddlewareAfterCompressionSignsTheBytesThatAreSent() async throws {
        let transport = RecordingTransport()
        let signing = NetworkMiddleware(beforeSend: { request, _ in
            request.withMergedHeaders(["X-Body-SHA256": SHA256Util.hex(request.body ?? Data())])
        })
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                transport: transport,
                middlewares: [.compressingRequestBodies(RequestCompressionPolicy(hosts: ["sync.example.com"])), signing]
            )
        )

        _ = try await client.load(request: post(largeJSON), authScope: nil)

        let sent = try #require(await transport.received.first)
        #expect(sent.headers["Content-Encoding"] == "gzip")
        #expect(sent.headers["X-Body-SHA256"] == SHA256Util.hex(sent.body ?? Data()))
        #expect(sent.body != largeJSON)

        // Without the middleware, nothing is compressed.
        let plain = RecordingTransport()
        _ = try await NetworkClient(configuration: NetworkClientConfiguration(transport: plain))
            .load(request: post(largeJSON), authScope: nil)
        #expect(await plain.received.first?.body == largeJSON)
    }
}
#endif
