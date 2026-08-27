import Foundation
import NovaNetworkCore

#if canImport(CryptoKit)
import CryptoKit
#endif

/// HMAC-SHA256, using the platform implementation where there is one.
///
/// The portable path exists so signing works on Linux. It is asserted equal to CryptoKit's output
/// across many random inputs rather than against a vector recalled from memory — the second kind of
/// test passes for the wrong reasons.
public enum HMACSHA256 {
    /// The 32-byte authentication code for a message under a key.
    public static func authenticate(_ message: Data, key: Data) -> Data {
        #if canImport(CryptoKit)
        let code = CryptoKit.HMAC<CryptoKit.SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: key)
        )
        return Data(code)
        #else
        return portableAuthenticate(message, key: key)
        #endif
    }

    /// The hex-encoded authentication code.
    public static func hex(_ message: Data, key: Data) -> String {
        authenticate(message, key: key).map { String(format: "%02x", $0) }.joined()
    }

    /// RFC 2104 over this package's portable SHA-256, for platforms without CryptoKit.
    ///
    /// Internal rather than private so a test can compare it against CryptoKit where both exist.
    static func portableAuthenticate(_ message: Data, key: Data) -> Data {
        let blockSize = 64
        var normalizedKey = key.count > blockSize ? SHA256Util.digest(key) : key
        normalizedKey.append(contentsOf: [UInt8](repeating: 0, count: blockSize - normalizedKey.count))

        var inner = Data(normalizedKey.map { $0 ^ 0x36 })
        inner.append(message)

        var outer = Data(normalizedKey.map { $0 ^ 0x5c })
        outer.append(SHA256Util.digest(inner))

        return SHA256Util.digest(outer)
    }
}

/// Signs requests with a shared secret.
///
/// Many internal and partner APIs authenticate this way rather than with OAuth: a key identifier, a
/// timestamp, a nonce, and an HMAC over a canonical form of the request. The canonical form is
/// documented below because both sides have to agree on it exactly, and a signer whose rules live
/// only in its implementation is a signer nobody can implement against.
public struct HMACRequestSigner: Sendable {
    /// Identifies which key signed the request, so the server knows which secret to verify with.
    public let keyID: String
    /// The header carrying the signature.
    public let headerName: String
    /// The scheme name written before the signature.
    public let scheme: String

    private let secret: Data

    /// Creates a signer.
    ///
    /// - Parameters:
    ///   - keyID: The key identifier the server knows this secret by.
    ///   - secret: The shared secret.
    ///   - headerName: Header carrying the signature. `Authorization` by default.
    ///   - scheme: Scheme name written before the signature.
    public init(
        keyID: String,
        secret: Data,
        headerName: String = "Authorization",
        scheme: String = "HMAC-SHA256"
    ) {
        self.keyID = keyID
        self.secret = secret
        self.headerName = headerName
        self.scheme = scheme
    }

    /// The canonical string a signature is computed over.
    ///
    /// Six lines, in this order, joined with `\n`:
    ///
    /// 1. the HTTP method, uppercased;
    /// 2. the URL path;
    /// 3. query items as `name=value`, sorted, joined with `&`;
    /// 4. the timestamp, as seconds since the epoch;
    /// 5. the nonce;
    /// 6. the SHA-256 of the body, hex-encoded — of the empty body when there is none.
    ///
    /// Sorting the query means a client that reorders parameters still verifies. Hashing the body
    /// rather than including it keeps the canonical string small and constant-size.
    public func canonicalString(for request: APIRequest, timestamp: Date, nonce: String) -> String {
        let url = request.urlRequest().url ?? request.url
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = (components?.queryItems ?? [])
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
            .joined(separator: "&")

        return [
            request.method.rawValue.uppercased(),
            components?.path ?? url.path,
            query,
            String(Int(timestamp.timeIntervalSince1970)),
            nonce,
            SHA256Util.hex(request.body ?? Data()),
        ].joined(separator: "\n")
    }

    /// The signature for a request, hex-encoded.
    public func signature(for request: APIRequest, timestamp: Date, nonce: String) -> String {
        HMACSHA256.hex(Data(canonicalString(for: request, timestamp: timestamp, nonce: nonce).utf8), key: secret)
    }

    /// Returns a copy of the request carrying the signature and the values needed to verify it.
    ///
    /// The timestamp and nonce travel in their own headers because the server cannot recompute what
    /// it cannot see.
    public func signed(_ request: APIRequest, timestamp: Date, nonce: String) -> APIRequest {
        request.withMergedHeaders([
            headerName: "\(scheme) keyId=\(keyID),nonce=\(nonce),ts=\(Int(timestamp.timeIntervalSince1970)),signature=\(signature(for: request, timestamp: timestamp, nonce: nonce))",
            "X-Nova-Timestamp": String(Int(timestamp.timeIntervalSince1970)),
            "X-Nova-Nonce": nonce,
        ])
    }

    /// Middleware that signs every outgoing request.
    ///
    /// - Parameters:
    ///   - now: Clock used for the timestamp.
    ///   - nonce: Produces a value unique per request, so a captured signature cannot be replayed.
    public func middleware(
        now: @escaping @Sendable () -> Date = Date.init,
        nonce: @escaping @Sendable () -> String = { UUID().uuidString }
    ) -> NetworkMiddleware {
        NetworkMiddleware(beforeSend: { request, _ in
            signed(request, timestamp: now(), nonce: nonce())
        })
    }
}
