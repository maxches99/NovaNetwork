import Foundation
#if canImport(Security)
import Security

/// A client identity (private key + certificate) presented to servers that request mutual TLS.
///
/// `SecIdentity` and `SecCertificate` are thread-safe, immutable Core Foundation reference
/// types; this wrapper is `@unchecked Sendable` on that basis, matching how the platform SDKs
/// document their concurrency behavior.
public struct ClientCertificateIdentity: @unchecked Sendable {
    /// The identity's private key and leaf certificate.
    public let identity: SecIdentity
    /// Additional certificates completing the chain to a trusted root, if needed.
    public let certificateChain: [SecCertificate]

    /// Creates a client certificate identity.
    public init(identity: SecIdentity, certificateChain: [SecCertificate] = []) {
        self.identity = identity
        self.certificateChain = certificateChain
    }
}

/// Supplies a client certificate identity for mutual TLS (mTLS) authentication challenges.
public struct ClientCertificateProvider: Sendable {
    /// Returns the identity to present for `host`, or `nil` to decline the challenge and fall
    /// back to the platform's default handling (typically proceeding without a certificate).
    public typealias Provide = @Sendable (_ host: String) -> ClientCertificateIdentity?

    /// Closure invoked once per client-certificate authentication challenge.
    public let provide: Provide

    /// Creates a client certificate provider.
    public init(provide: @escaping Provide) {
        self.provide = provide
    }

    /// A provider that always presents the same identity, regardless of host.
    public static func fixed(_ identity: ClientCertificateIdentity) -> ClientCertificateProvider {
        ClientCertificateProvider { _ in identity }
    }
}
#endif
