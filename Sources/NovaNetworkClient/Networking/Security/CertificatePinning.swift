import Foundation
#if canImport(Security)
import Security
import CryptoKit

/// Public-key pinning configuration for one or more hosts.
///
/// Each host maps to a set of accepted Subject Public Key Info (SPKI) SHA-256 pins, matching
/// the values reported by:
/// ```
/// openssl x509 -in cert.pem -pubkey -noout \
///   | openssl pkey -pubin -outform DER \
///   | openssl dgst -sha256 -binary \
///   | openssl base64
/// ```
/// Configuring more than one pin per host (a primary pin and one or more backup pins) allows
/// certificate or key rotation without an app update: a connection succeeds as soon as any
/// certificate in the presented chain matches any configured pin for that host.
public struct CertificatePinningPolicy: Sendable {
    /// Behavior applied to hosts with no configured pins.
    public enum UnpinnedHostPolicy: Sendable {
        /// Hosts without configured pins fall back to the platform's default trust evaluation.
        case allowDefaultEvaluation
        /// Hosts without configured pins are rejected outright (allow-list enforcement).
        case reject
    }

    /// Base64-encoded SPKI SHA-256 pins, keyed by exact host name.
    public let pinsByHost: [String: Set<String>]
    /// Behavior for hosts not present in `pinsByHost`.
    public let unpinnedHostPolicy: UnpinnedHostPolicy

    /// Creates a certificate pinning policy.
    public init(
        pinsByHost: [String: Set<String>],
        unpinnedHostPolicy: UnpinnedHostPolicy = .allowDefaultEvaluation
    ) {
        self.pinsByHost = pinsByHost
        self.unpinnedHostPolicy = unpinnedHostPolicy
    }
}

/// The outcome of evaluating one server trust challenge against a ``CertificatePinningPolicy``.
public struct CertificatePinningValidationEvent: Sendable {
    /// A validation outcome category.
    public enum Outcome: String, Sendable {
        /// A certificate in the chain matched a configured pin.
        case pinMatched
        /// No certificate in the chain matched any configured pin for the host.
        case pinMismatch
        /// The host had no configured pins and default evaluation was used.
        case unpinnedHostAllowed
        /// The host had no configured pins and the policy rejected it.
        case unpinnedHostRejected
        /// Default platform trust evaluation itself rejected the chain.
        case defaultEvaluationFailed
        /// The chain or its public keys could not be evaluated (always treated as a failure).
        case evaluationError
    }

    /// The challenged host.
    public let host: String
    /// The validation outcome.
    public let outcome: Outcome
    /// Additional detail, when available.
    public let reason: String?

    public init(host: String, outcome: Outcome, reason: String? = nil) {
        self.host = host
        self.outcome = outcome
        self.reason = reason
    }
}

/// Computes Subject Public Key Info (SPKI) SHA-256 pins from certificates.
public enum SubjectPublicKeyInfoPin {
    /// Computes the base64 SPKI SHA-256 pin for one certificate's public key.
    ///
    /// Returns `nil` if the key's type or size is not one this implementation can reconstruct
    /// an X.509 `AlgorithmIdentifier` for (RSA of any size, or EC P-256/P-384/P-521).
    public static func compute(for certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        return compute(for: publicKey)
    }

    /// Computes the base64 SPKI SHA-256 pin for a public key.
    public static func compute(for publicKey: SecKey) -> String? {
        guard
            let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any],
            let keyType = attributes[kSecAttrKeyType] as? String,
            let sizeInBits = attributes[kSecAttrKeySizeInBits] as? Int,
            let algorithmIdentifier = algorithmIdentifier(keyType: keyType as CFString, sizeInBits: sizeInBits)
        else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let representation = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }

        let spki = DER.sequence(algorithmIdentifier + DER.bitString([UInt8](representation)))
        let digest = CryptoKit.SHA256.hash(data: Data(spki))
        return Data(digest).base64EncodedString()
    }

    private static func algorithmIdentifier(keyType: CFString, sizeInBits: Int) -> [UInt8]? {
        if keyType == kSecAttrKeyTypeRSA {
            // The RSA AlgorithmIdentifier (rsaEncryption OID + NULL params) is fixed regardless
            // of key size; SecKeyCopyExternalRepresentation already returns the PKCS#1
            // RSAPublicKey DER that becomes the BIT STRING content.
            return rsaAlgorithmIdentifier
        }
        if keyType == kSecAttrKeyTypeECSECPrimeRandom {
            switch sizeInBits {
            case 256: return ecAlgorithmIdentifier(curveOID: ecP256CurveOID)
            case 384: return ecAlgorithmIdentifier(curveOID: ecP384CurveOID)
            case 521: return ecAlgorithmIdentifier(curveOID: ecP521CurveOID)
            default: return nil
            }
        }
        return nil
    }

    private static let rsaAlgorithmIdentifier: [UInt8] = [
        0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
    ]
    private static let ecPublicKeyOID: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let ecP256CurveOID: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let ecP384CurveOID: [UInt8] = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x22]
    private static let ecP521CurveOID: [UInt8] = [0x06, 0x05, 0x2B, 0x81, 0x04, 0x00, 0x23]

    private static func ecAlgorithmIdentifier(curveOID: [UInt8]) -> [UInt8] {
        DER.sequence(ecPublicKeyOID + curveOID)
    }

    /// Minimal DER encoding helpers for building an X.509 SubjectPublicKeyInfo structure.
    private enum DER {
        static func length(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            var bytes: [UInt8] = []
            var value = n
            while value > 0 {
                bytes.insert(UInt8(value & 0xFF), at: 0)
                value >>= 8
            }
            return [0x80 | UInt8(bytes.count)] + bytes
        }

        static func sequence(_ content: [UInt8]) -> [UInt8] {
            [0x30] + length(content.count) + content
        }

        static func bitString(_ content: [UInt8]) -> [UInt8] {
            // A leading 0x00 byte declares zero unused bits in the final content octet.
            let withUnusedBitsByte: [UInt8] = [0x00] + content
            return [0x03] + length(withUnusedBitsByte.count) + withUnusedBitsByte
        }
    }
}

/// Evaluates a `SecTrust` challenge against a ``CertificatePinningPolicy``.
enum CertificatePinningEvaluator {
    static func evaluate(
        trust: SecTrust,
        host: String,
        policy: CertificatePinningPolicy
    ) -> CertificatePinningValidationEvent {
        guard let configuredPins = policy.pinsByHost[host] else {
            switch policy.unpinnedHostPolicy {
            case .allowDefaultEvaluation:
                return CertificatePinningValidationEvent(host: host, outcome: .unpinnedHostAllowed)
            case .reject:
                return CertificatePinningValidationEvent(host: host, outcome: .unpinnedHostRejected)
            }
        }

        var evaluationError: CFError?
        guard SecTrustEvaluateWithError(trust, &evaluationError) else {
            return CertificatePinningValidationEvent(
                host: host,
                outcome: .defaultEvaluationFailed,
                reason: evaluationError.map { String(describing: $0) }
            )
        }

        let certificateCount = SecTrustGetCertificateCount(trust)
        guard certificateCount > 0 else {
            return CertificatePinningValidationEvent(host: host, outcome: .evaluationError, reason: "empty chain")
        }

        for index in 0..<certificateCount {
            guard let certificate = SecTrustGetCertificateAtIndex(trust, index),
                  let pin = SubjectPublicKeyInfoPin.compute(for: certificate) else {
                continue
            }
            if configuredPins.contains(pin) {
                return CertificatePinningValidationEvent(host: host, outcome: .pinMatched)
            }
        }

        return CertificatePinningValidationEvent(host: host, outcome: .pinMismatch)
    }
}
#endif
