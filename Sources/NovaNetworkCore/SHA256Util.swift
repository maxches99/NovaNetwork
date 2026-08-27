import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 hashing that works everywhere this package does.
///
/// `CryptoKit` is used where it exists and a from-scratch implementation stands in where it does
/// not, so request fingerprinting, cache keys, integrity checks, and PKCE all hash the same way on
/// every platform. It lives here rather than inside one module because a second copy of
/// cryptography is how one of the copies ends up wrong.
public enum SHA256Util {
    /// The hex-encoded digest of a UTF-8 string.
    public static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    /// The hex-encoded digest of bytes.
    public static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = PortableSHA256()
        hasher.update(data)
        return hasher.finalizeHex()
        #endif
    }

    /// The raw 32-byte digest of bytes.
    ///
    /// Needed wherever the digest itself is the input to something else — a PKCE challenge, an HMAC
    /// — rather than a string to compare.
    public static func digest(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(CryptoKit.SHA256.hash(data: data))
        #else
        var hasher = PortableSHA256()
        hasher.update(data)
        return hasher.finalize()
        #endif
    }

    /// The hex-encoded digest of a file, read in chunks so a large file is never held in memory.
    public static func hex(fileAt url: URL, chunkSize: Int = 65_536) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        while true {
            let data = handle.readData(ofLength: max(1, chunkSize))
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = PortableSHA256()
        while true {
            let data = handle.readData(ofLength: max(1, chunkSize))
            if data.isEmpty { break }
            hasher.update(data)
        }
        return hasher.finalizeHex()
        #endif
    }
}
