import Foundation
#if canImport(Security)
import Security

/// A `URLSessionDelegate` that enforces certificate pinning and, optionally, presents a client
/// certificate for mutual TLS (mTLS).
///
/// Server trust challenges for hosts with configured pins are evaluated against
/// ``CertificatePinningPolicy``; the platform's default trust evaluation still runs first, so a
/// pinned connection must satisfy both the system trust store and the pin. Hosts without
/// configured pins follow ``CertificatePinningPolicy/UnpinnedHostPolicy``.
public final class PinningURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let policy: CertificatePinningPolicy
    private let clientCertificateProvider: ClientCertificateProvider?
    private let onValidation: (@Sendable (CertificatePinningValidationEvent) -> Void)?

    /// Creates a pinning delegate.
    ///
    /// - Parameters:
    ///   - policy: The certificate pinning policy to enforce.
    ///   - clientCertificateProvider: Supplies a client identity for mTLS challenges, if any.
    ///   - onValidation: Invoked once per server trust challenge with the evaluation outcome.
    public init(
        policy: CertificatePinningPolicy,
        clientCertificateProvider: ClientCertificateProvider? = nil,
        onValidation: (@Sendable (CertificatePinningValidationEvent) -> Void)? = nil
    ) {
        self.policy = policy
        self.clientCertificateProvider = clientCertificateProvider
        self.onValidation = onValidation
    }

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            handleServerTrust(challenge: challenge, completionHandler: completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            handleClientCertificate(challenge: challenge, completionHandler: completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func handleServerTrust(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        guard let trust = challenge.protectionSpace.serverTrust else {
            onValidation?(CertificatePinningValidationEvent(host: host, outcome: .evaluationError, reason: "no server trust"))
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: host, policy: policy)
        onValidation?(event)

        switch event.outcome {
        case .pinMatched:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .unpinnedHostAllowed:
            completionHandler(.performDefaultHandling, nil)
        case .pinMismatch, .unpinnedHostRejected, .defaultEvaluationFailed, .evaluationError:
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func handleClientCertificate(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        guard let identity = clientCertificateProvider?.provide(host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let credential = URLCredential(
            identity: identity.identity,
            certificates: identity.certificateChain.isEmpty ? nil : identity.certificateChain,
            persistence: .forSession
        )
        completionHandler(.useCredential, credential)
    }
}
#endif
