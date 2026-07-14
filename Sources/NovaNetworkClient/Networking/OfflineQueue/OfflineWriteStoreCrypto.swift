import NovaNetworkCore
import CryptoKit
import Foundation

public enum OfflineWriteStoreCipherError: Error, Equatable {
    case keyUnavailable
    case unsupportedVersion(Int)
    case decryptionFailed
}

public protocol OfflineWriteStoreCipher: Sendable {
    var algorithm: String { get }
    var version: Int { get }
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data, algorithm: String, version: Int) throws -> Data
}

public struct AESGCMOfflineWriteStoreCipher: OfflineWriteStoreCipher {
    private let keyProvider: @Sendable () throws -> Data

    public let algorithm: String = "AES.GCM"
    public let version: Int

    public init(version: Int = 1, keyProvider: @escaping @Sendable () throws -> Data) {
        self.version = max(1, version)
        self.keyProvider = keyProvider
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let key = try makeKey()
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data, algorithm: String, version: Int) throws -> Data {
        guard algorithm == self.algorithm else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        guard version <= self.version else {
            throw OfflineWriteStoreCipherError.unsupportedVersion(version)
        }
        let key = try makeKey()
        guard let sealed = try? AES.GCM.SealedBox(combined: ciphertext) else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        guard let decrypted = try? AES.GCM.open(sealed, using: key) else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        return decrypted
    }

    private func makeKey() throws -> SymmetricKey {
        let keyData: Data
        do {
            keyData = try keyProvider()
        } catch {
            throw OfflineWriteStoreCipherError.keyUnavailable
        }
        guard keyData.count == 16 || keyData.count == 24 || keyData.count == 32 else {
            throw OfflineWriteStoreCipherError.keyUnavailable
        }
        return SymmetricKey(data: keyData)
    }
}

public struct RotatingAESGCMOfflineWriteStoreCipher: OfflineWriteStoreCipher {
    private let currentKeyProvider: @Sendable () throws -> Data
    private let historicalKeyProvider: @Sendable (Int) throws -> Data

    public let algorithm: String = "AES.GCM"
    public let version: Int

    public init(
        version: Int,
        currentKeyProvider: @escaping @Sendable () throws -> Data,
        historicalKeyProvider: @escaping @Sendable (Int) throws -> Data
    ) {
        self.version = max(1, version)
        self.currentKeyProvider = currentKeyProvider
        self.historicalKeyProvider = historicalKeyProvider
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let key = try makeKey(from: currentKeyProvider())
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data, algorithm: String, version: Int) throws -> Data {
        guard algorithm == self.algorithm else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        guard version <= self.version else {
            throw OfflineWriteStoreCipherError.unsupportedVersion(version)
        }
        guard let sealed = try? AES.GCM.SealedBox(combined: ciphertext) else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }

        let decryptionKeyData: Data
        do {
            if version == self.version {
                decryptionKeyData = try currentKeyProvider()
            } else {
                decryptionKeyData = try historicalKeyProvider(version)
            }
        } catch {
            throw OfflineWriteStoreCipherError.keyUnavailable
        }
        let key = try makeKey(from: decryptionKeyData)
        guard let plaintext = try? AES.GCM.open(sealed, using: key) else {
            throw OfflineWriteStoreCipherError.decryptionFailed
        }
        return plaintext
    }

    private func makeKey(from keyData: Data) throws -> SymmetricKey {
        guard keyData.count == 16 || keyData.count == 24 || keyData.count == 32 else {
            throw OfflineWriteStoreCipherError.keyUnavailable
        }
        return SymmetricKey(data: keyData)
    }
}
