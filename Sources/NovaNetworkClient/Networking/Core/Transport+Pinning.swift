import Foundation
#if canImport(Security)
import Security

public extension Transport {
    /// Creates a transport whose `URLSession` enforces certificate pinning, and optionally
    /// presents a client certificate for mutual TLS (mTLS), via a dedicated
    /// ``PinningURLSessionDelegate``.
    ///
    /// The session retains its delegate for its lifetime, matching standard `URLSession`
    /// behavior, so no additional reference needs to be kept alive by the caller.
    static func pinned(
        policy: CertificatePinningPolicy,
        clientCertificateProvider: ClientCertificateProvider? = nil,
        configuration: URLSessionConfiguration = .default,
        onValidation: (@Sendable (CertificatePinningValidationEvent) -> Void)? = nil
    ) -> Transport {
        let delegate = PinningURLSessionDelegate(
            policy: policy,
            clientCertificateProvider: clientCertificateProvider,
            onValidation: onValidation
        )
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return Transport(session: session)
    }
}
#endif
