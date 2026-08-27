import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient

#if canImport(Security)
import Security

// Requirements: FR-PIN-1 (SPKI pin computation), FR-PIN-2 (policy evaluation), FR-PIN-3 (delegate).
//
// Test certificates below are self-signed, short-lived (365 days from generation), scoped to
// "pin-test.example.com" with a matching SAN and serverAuth EKU, generated with:
//   openssl req -x509 -newkey <ec:prime256v1|rsa:2048> -days 365 -nodes -config ext.cnf
// Their expected pins were independently computed with:
//   openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | base64

private let ecTestCertificateBase64 = """
MIIBjDCCATGgAwIBAgIJAICnL/3yrYGwMAoGCCqGSM49BAMCMB8xHTAbBgNVBAMMFHBpbi10ZXN0\
LmV4YW1wbGUuY29tMB4XDTI2MDgyNDExMzA0MloXDTI3MDgyNDExMzA0MlowHzEdMBsGA1UEAwwU\
cGluLXRlc3QuZXhhbXBsZS5jb20wWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASKR7n8c9u36MPX\
R7NhOzEJH2yYtQxPWOGGLSwva0sSUDiwWRFpPGbxzwP4ySVIxo2p/8Ir6fTI9xwakTuHBRMVo1Yw\
VDAfBgNVHREEGDAWghRwaW4tdGVzdC5leGFtcGxlLmNvbTATBgNVHSUEDDAKBggrBgEFBQcDATAM\
BgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDAKBggqhkjOPQQDAgNJADBGAiEA0oj2m7OpT6e7\
4bbGP5+IiJm/Nq7dOAHqd72Rj0OZz0wCIQDo0YEBAvCkAjPqKrtuPukwj8RJd92SIvEs3MnEELFk\
Tg==
"""
private let ecTestCertificatePin = "3uJ15Qe99BLOUQtJ/UiOmAtis6L0q0K8MAHOg0yNhYY="

private let rsaTestCertificateBase64 = """
MIIDFzCCAf+gAwIBAgIJAIaoA8UutFrSMA0GCSqGSIb3DQEBCwUAMB8xHTAbBgNVBAMMFHBpbi10\
ZXN0LmV4YW1wbGUuY29tMB4XDTI2MDgyNDExMzEwNloXDTI3MDgyNDExMzEwNlowHzEdMBsGA1UE\
AwwUcGluLXRlc3QuZXhhbXBsZS5jb20wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC5\
gvnZyODxNjKwkUHpKTO/292yP1hTD2mCJXn6EC/juoXe/j/E6b6nhgShK1Ax7J/DFy2cKSX6DgHv\
Zfz6KuuKeqxfigufAXqAC7B+ONCKUup6R6yZQSEfQalu9hsFkxKxKv3bvcIUevMozrfU2Iebbu3f\
Op8LLd0po2jr+IhgxdBg/aEPfN22EemvjCJWophRJz1rzgWr5y8CO7qrISQcCnoy+eZtYArK7Gk\
TXJVjNcoLnbCHWXIu32vOhUKKeGkx+QL+NQ53naZr0XUhPcJfp3UjH1AwXuN1ieoMeYG/zdMlPs\
/1+AkFdY29OPROMVSAY0WJrZIq6d8kS8DW6mBbAgMBAAGjVjBUMB8GA1UdEQQYMBaCFHBpbi10ZX\
N0LmV4YW1wbGUuY29tMBMGA1UdJQQMMAoGCCsGAQUFBwMBMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQ\
H/BAQDAgWgMA0GCSqGSIb3DQEBCwUAA4IBAQCd9h6nMpnOAP2lsr3MCjMuKH1J4zbG5C5Z9BJ1r1\
2jcc7LZscJCjipV7ISGs9uaxzxzf9Gg+FnPp/QQ6Wb7K3BXTFn5NXgt5XEttZ9NrSvE7Cq8cDwlQ\
Ou9Buo1E5FDV2Y8gtIqBln9UmAk4vX1cOJ9+bZJT4kGN573+fPmWgEbZk0Lhfq/zw1MjmFLw013k\
d60RpN+uyFtApvE1SzRYWLxkid+PplFcmvrb7xlGcboU+mH2tzPKFW8WAQrZnnekAhm5XlrfxTk\
Ozwf0f7qoYtTSW4E1FoP3/re31GbmoeWp54GnGTzs1ERyng8mAz1Ozsxc5+TzmHRsRp8AYxYJ1u
"""
private let rsaTestCertificatePin = "FbkbLxpTpLgRI62WdmU/q9cL+qRaEC+lH4XJzR6naOQ="

private let testHost = "pin-test.example.com"

private func loadCertificate(base64: String) -> SecCertificate {
    let der = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: ""))!
    return SecCertificateCreateWithData(nil, der as CFData)!
}

/// Builds a `SecTrust` for `certificate`, anchored to itself so `SecTrustEvaluateWithError`
/// succeeds for a self-signed test certificate without depending on any real CA.
private func makeSelfAnchoredTrust(for certificate: SecCertificate, host: String = testHost) -> SecTrust {
    var trust: SecTrust?
    let policy = SecPolicyCreateSSL(true, host as CFString)
    _ = SecTrustCreateWithCertificates(certificate, policy, &trust)
    guard let trust else { fatalError("failed to create SecTrust for test certificate") }
    _ = SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
    _ = SecTrustSetAnchorCertificatesOnly(trust, true)
    return trust
}

/// A single-slot mutable box for capturing a value from a `@Sendable` closure in tests that
/// invoke it synchronously on the calling thread.
private final class Box<Value>: @unchecked Sendable {
    var value: Value?
}

private final class FakeChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

private func makeChallenge(authenticationMethod: String, host: String = testHost) -> URLAuthenticationChallenge {
    let space = URLProtectionSpace(
        host: host,
        port: 443,
        protocol: "https",
        realm: nil,
        authenticationMethod: authenticationMethod
    )
    return URLAuthenticationChallenge(
        protectionSpace: space,
        proposedCredential: nil,
        previousFailureCount: 0,
        failureResponse: nil,
        error: nil,
        sender: FakeChallengeSender()
    )
}

@Suite
struct SubjectPublicKeyInfoPinTests {
    @Test
    func computesTheStandardOpenSSLPinForAnECCertificate() {
        let certificate = loadCertificate(base64: ecTestCertificateBase64)
        #expect(SubjectPublicKeyInfoPin.compute(for: certificate) == ecTestCertificatePin)
    }

    @Test
    func computesTheStandardOpenSSLPinForAnRSACertificate() {
        let certificate = loadCertificate(base64: rsaTestCertificateBase64)
        #expect(SubjectPublicKeyInfoPin.compute(for: certificate) == rsaTestCertificatePin)
    }
}

@Suite
struct CertificatePinningEvaluatorTests {
    @Test
    func matchesAConfiguredPin() {
        let certificate = loadCertificate(base64: ecTestCertificateBase64)
        let trust = makeSelfAnchoredTrust(for: certificate)
        let policy = CertificatePinningPolicy(pinsByHost: [testHost: [ecTestCertificatePin]])

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: testHost, policy: policy)
        #expect(event.outcome == .pinMatched)
    }

    @Test
    func matchesAnyOneOfMultipleBackupPins() {
        let certificate = loadCertificate(base64: ecTestCertificateBase64)
        let trust = makeSelfAnchoredTrust(for: certificate)
        let policy = CertificatePinningPolicy(
            pinsByHost: [testHost: ["not-the-real-pin=", ecTestCertificatePin]]
        )

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: testHost, policy: policy)
        #expect(event.outcome == .pinMatched)
    }

    @Test
    func rejectsAMismatchedPin() {
        let certificate = loadCertificate(base64: ecTestCertificateBase64)
        let trust = makeSelfAnchoredTrust(for: certificate)
        let policy = CertificatePinningPolicy(pinsByHost: [testHost: ["wrong-pin-value="]])

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: testHost, policy: policy)
        #expect(event.outcome == .pinMismatch)
    }

    @Test
    func allowsAnUnpinnedHostByDefault() {
        let certificate = loadCertificate(base64: ecTestCertificateBase64)
        let trust = makeSelfAnchoredTrust(for: certificate)
        let policy = CertificatePinningPolicy(pinsByHost: ["other.example.com": [ecTestCertificatePin]])

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: testHost, policy: policy)
        #expect(event.outcome == .unpinnedHostAllowed)
    }

    @Test
    func rejectsAnUnpinnedHostWhenConfiguredToRejectByDefault() {
        let certificate = loadCertificate(base64: ecTestCertificateBase64)
        let trust = makeSelfAnchoredTrust(for: certificate)
        let policy = CertificatePinningPolicy(
            pinsByHost: ["other.example.com": [ecTestCertificatePin]],
            unpinnedHostPolicy: .reject
        )

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: testHost, policy: policy)
        #expect(event.outcome == .unpinnedHostRejected)
    }

    @Test
    func acceptsAnRSACertificatePin() {
        let certificate = loadCertificate(base64: rsaTestCertificateBase64)
        let trust = makeSelfAnchoredTrust(for: certificate)
        let policy = CertificatePinningPolicy(pinsByHost: [testHost: [rsaTestCertificatePin]])

        let event = CertificatePinningEvaluator.evaluate(trust: trust, host: testHost, policy: policy)
        #expect(event.outcome == .pinMatched)
    }
}

@Suite
struct PinningURLSessionDelegateTests {
    @Test
    func performsDefaultHandlingForUnrelatedAuthenticationMethods() {
        let delegate = PinningURLSessionDelegate(policy: CertificatePinningPolicy(pinsByHost: [:]))
        let challenge = makeChallenge(authenticationMethod: NSURLAuthenticationMethodHTTPBasic)

        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            result = (disposition, credential)
        }

        #expect(result?.0 == .performDefaultHandling)
    }

    @Test
    func cancelsServerTrustChallengesMissingATrustObject() {
        let observed = Box<CertificatePinningValidationEvent>()
        let delegate = PinningURLSessionDelegate(
            policy: CertificatePinningPolicy(pinsByHost: [testHost: [ecTestCertificatePin]]),
            onValidation: { observed.value = $0 }
        )
        // A manually constructed protection space has no serverTrust (only real TLS handshakes
        // populate it), exercising the delegate's defensive "no trust object" path.
        let challenge = makeChallenge(authenticationMethod: NSURLAuthenticationMethodServerTrust)

        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            result = (disposition, credential)
        }

        #expect(result?.0 == .cancelAuthenticationChallenge)
        #expect(observed.value?.outcome == .evaluationError)
    }

    @Test
    func performsDefaultHandlingForClientCertificateChallengesWithNoProvider() {
        let delegate = PinningURLSessionDelegate(policy: CertificatePinningPolicy(pinsByHost: [:]))
        let challenge = makeChallenge(authenticationMethod: NSURLAuthenticationMethodClientCertificate)

        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            result = (disposition, credential)
        }

        #expect(result?.0 == .performDefaultHandling)
    }

    @Test
    func performsDefaultHandlingWhenTheProviderDeclinesTheHost() {
        let provider = ClientCertificateProvider { _ in nil }
        let delegate = PinningURLSessionDelegate(
            policy: CertificatePinningPolicy(pinsByHost: [:]),
            clientCertificateProvider: provider
        )
        let challenge = makeChallenge(authenticationMethod: NSURLAuthenticationMethodClientCertificate)

        var result: (URLSession.AuthChallengeDisposition, URLCredential?)?
        delegate.urlSession(URLSession.shared, didReceive: challenge) { disposition, credential in
            result = (disposition, credential)
        }

        #expect(result?.0 == .performDefaultHandling)
    }
}
#endif
