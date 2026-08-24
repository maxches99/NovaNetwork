import NovaNetworkCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

enum SHA256Util {
    static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    static func hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = PortableSHA256()
        hasher.update(data)
        return hasher.finalizeHex()
        #endif
    }
}
