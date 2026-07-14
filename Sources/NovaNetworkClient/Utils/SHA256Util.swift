import NovaNetworkCore
import Foundation
import CryptoKit

enum SHA256Util {
    static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    static func hex(_ data: Data) -> String {
        let digest = CryptoKit.SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
