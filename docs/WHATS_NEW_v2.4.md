# What's New in 2.4

## Certificate pinning and mutual TLS (Apple platforms)

- Added `CertificatePinningPolicy`: base64 SPKI SHA-256 public-key pins keyed by host, with
  support for multiple pins per host (primary plus backup pins for rotation without an app
  update) and a configurable `unpinnedHostPolicy` (`allowDefaultEvaluation` or `reject`) for
  hosts with no configured pins.
- Added `SubjectPublicKeyInfoPin.compute(for:)`, computing the standard SPKI SHA-256 pin for an
  RSA (any key size) or EC (P-256/P-384/P-521) certificate by reconstructing its X.509
  SubjectPublicKeyInfo DER structure. Cross-verified byte-for-byte against
  `openssl x509 -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary`
  for RSA-2048, RSA-3072, and all three supported EC curves.
- Added `CertificatePinningEvaluator`, which evaluates a `SecTrust` chain against the policy: the
  platform's own trust evaluation still runs for pinned hosts, so a connection must satisfy both
  the system trust store and the pin, never just one or the other.
- Added `ClientCertificateProvider` and `ClientCertificateIdentity` for mutual TLS: supply a
  `SecIdentity` (and any intermediate certificates) per host to answer client-certificate
  authentication challenges.
- Added `PinningURLSessionDelegate`, a `URLSessionDelegate` wiring both of the above into
  `URLSession`'s authentication challenge handling, with a `onValidation` callback reporting the
  outcome of every server trust challenge (matched, mismatched, unpinned-allowed,
  unpinned-rejected, or evaluation error) for telemetry.
- Added `Transport.pinned(policy:clientCertificateProvider:configuration:onValidation:)`, a
  factory that builds a ready-to-use `Transport` backed by a `URLSession` configured with the
  pinning delegate.
- This functionality depends on the `Security` framework and compiles only on Apple platforms
  (`#if canImport(Security)`); it has no effect on `NovaNetworkCore`, which remains
  platform-independent.

## Migration notes

- Additive only; no existing public API changed.
