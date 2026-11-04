import Foundation
import NovaNetworkCore
#if canImport(Compression)
import Compression
#endif

/// The `Content-Encoding` a request body is compressed with.
public enum RequestBodyEncoding: String, Sendable, Equatable {
    /// RFC 1952. What servers mean by "accepts compressed bodies" almost every time.
    case gzip
    /// RFC 1950 zlib, which is what HTTP's `deflate` means.
    case deflate
}

/// Which request bodies to compress, and how.
///
/// Most servers do not decompress request bodies unless configured to, and one that does not turns
/// every compressed write into a 400. So the hosts are named explicitly, or every host is chosen
/// explicitly with ``anyHost(encoding:minimumBodyBytes:isEligible:)``.
public struct RequestCompressionPolicy: Sendable {
    /// Decides whether a request's body may be compressed, in place of the content-type rule.
    public typealias Eligibility = @Sendable (APIRequest) -> Bool

    /// The hosts to compress for, lowercased; `nil` means every host.
    public let hosts: Set<String>?
    /// The encoding to use.
    public let encoding: RequestBodyEncoding
    /// Bodies smaller than this are sent as they are: the saving would be smaller than the cost.
    public let minimumBodyBytes: Int
    /// Replaces the content-type rule, when given.
    public let isEligible: Eligibility?

    /// Compresses bodies sent to the given hosts.
    ///
    /// - Parameters:
    ///   - hosts: The hosts whose servers decompress request bodies. Matched case-insensitively.
    ///   - encoding: Defaults to `gzip`.
    ///   - minimumBodyBytes: Defaults to 1 KB. Negative values are treated as `0`.
    ///   - isEligible: Replaces the content-type rule, when given.
    public init(
        hosts: Set<String>,
        encoding: RequestBodyEncoding = .gzip,
        minimumBodyBytes: Int = 1_024,
        isEligible: Eligibility? = nil
    ) {
        self.init(hosts: Optional(hosts), encoding: encoding, minimumBodyBytes: minimumBodyBytes, isEligible: isEligible)
    }

    /// Compresses bodies sent to any host. Choose this only when every server the client talks to
    /// decompresses request bodies.
    public static func anyHost(
        encoding: RequestBodyEncoding = .gzip,
        minimumBodyBytes: Int = 1_024,
        isEligible: Eligibility? = nil
    ) -> RequestCompressionPolicy {
        RequestCompressionPolicy(hosts: nil, encoding: encoding, minimumBodyBytes: minimumBodyBytes, isEligible: isEligible)
    }

    private init(hosts: Set<String>?, encoding: RequestBodyEncoding, minimumBodyBytes: Int, isEligible: Eligibility?) {
        self.hosts = hosts.map { Set($0.map { $0.lowercased() }) }
        self.encoding = encoding
        self.minimumBodyBytes = max(0, minimumBodyBytes)
        self.isEligible = isEligible
    }

    /// Whether a content type is worth compressing: JSON, `+json`, text, XML, and form bodies. A
    /// request with no content type is assumed to be one of those.
    public static func isCompressible(contentType: String?) -> Bool {
        guard let contentType else { return true }
        let media = contentType.split(separator: ";").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return media.hasPrefix("text/")
            || media == "application/json" || media.hasSuffix("+json")
            || media == "application/xml" || media.hasSuffix("+xml")
            || media == "application/x-www-form-urlencoded"
            || media == "application/graphql"
    }
}

/// What the compression middleware did with one request body.
public enum RequestCompressionEvent: Sendable, Equatable {
    /// Why a body was sent as it was.
    public enum SkipReason: String, Sendable, Equatable {
        /// The host is not one the policy compresses for.
        case hostNotListed = "host_not_listed"
        /// The body is smaller than ``RequestCompressionPolicy/minimumBodyBytes``.
        case tooSmall = "too_small"
        /// The request already has a `Content-Encoding`.
        case alreadyEncoded = "already_encoded"
        /// The content type is not one that compresses, or `isEligible` said no.
        case notCompressible = "not_compressible"
        /// Compressing did not make the body smaller.
        case notSmaller = "not_smaller"
        /// This platform has no compressor.
        case unavailable
    }

    /// The body was replaced with a compressed one.
    case compressed(url: URL, encoding: RequestBodyEncoding, originalBytes: Int, compressedBytes: Int)
    /// The body was sent unchanged.
    case skipped(url: URL, reason: SkipReason)
}

public extension NetworkMiddleware {
    /// Compresses request bodies for servers that accept compressed bodies.
    ///
    /// ```swift
    /// configuration.middlewares = [
    ///     .compressingRequestBodies(RequestCompressionPolicy(hosts: ["sync.example.com"])),
    ///     signingMiddleware,   // after compression, so the signature covers the bytes sent
    /// ]
    /// ```
    ///
    /// Middleware runs in array order. Put this before any middleware that signs or hashes the body,
    /// so it covers the bytes that are actually sent.
    ///
    /// On platforms without Apple's Compression framework every body is sent unchanged and reported
    /// as ``RequestCompressionEvent/SkipReason/unavailable``.
    static func compressingRequestBodies(
        _ policy: RequestCompressionPolicy,
        onEvent: (@Sendable (RequestCompressionEvent) -> Void)? = nil
    ) -> NetworkMiddleware {
        NetworkMiddleware(beforeSend: { request, _ in
            guard let body = request.body, !body.isEmpty else { return request }
            func skip(_ reason: RequestCompressionEvent.SkipReason) -> APIRequest {
                onEvent?(.skipped(url: request.url, reason: reason))
                return request
            }

            if let hosts = policy.hosts, !hosts.contains(request.url.host?.lowercased() ?? "") {
                return skip(.hostNotListed)
            }
            if body.count < policy.minimumBodyBytes {
                return skip(.tooSmall)
            }
            if Self.header("Content-Encoding", in: request.headers) != nil {
                return skip(.alreadyEncoded)
            }
            let eligible = policy.isEligible?(request)
                ?? RequestCompressionPolicy.isCompressible(contentType: Self.header("Content-Type", in: request.headers))
            if !eligible {
                return skip(.notCompressible)
            }
            guard let compressed = RequestBodyCompressor.compress(body, as: policy.encoding) else {
                return skip(.unavailable)
            }
            guard compressed.count < body.count else {
                return skip(.notSmaller)
            }

            onEvent?(.compressed(url: request.url, encoding: policy.encoding, originalBytes: body.count, compressedBytes: compressed.count))
            var headers = request.headers
            headers["Content-Encoding"] = policy.encoding.rawValue
            return APIRequest(
                method: request.method,
                url: request.url,
                queryItems: request.queryItems,
                headers: headers,
                body: compressed,
                timeout: request.timeout
            )
        })
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// gzip and zlib framing around raw DEFLATE data.
enum RequestBodyCompressor {
    /// The body framed for `encoding`, or `nil` when this platform cannot compress.
    static func compress(_ data: Data, as encoding: RequestBodyEncoding) -> Data? {
        guard let deflated = rawDeflate(data) else { return nil }
        switch encoding {
        case .gzip:
            // ID1 ID2, CM = deflate, no flags, no mtime, no extra flags, OS = unknown.
            var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
            output.append(deflated)
            output.append(littleEndian: crc32(data))
            output.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
            return output
        case .deflate:
            // CMF = deflate with a 32 KB window, FLG = default level with a valid check value.
            var output = Data([0x78, 0x9c])
            output.append(deflated)
            output.append(bigEndian: adler32(data))
            return output
        }
    }

    /// RFC 1951 data, from the Compression framework's `COMPRESSION_ZLIB`.
    static func rawDeflate(_ data: Data) -> Data? {
        #if canImport(Compression)
        // DEFLATE's stored blocks bound the worst case at a few bytes per 64 KB above the input.
        let capacity = data.count + data.count / 16 + 64
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        output.count = written
        return output
        #else
        return nil
        #endif
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    /// CRC-32 (IEEE 802.3), as gzip's trailer uses.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// Adler-32, as zlib's trailer uses.
    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
