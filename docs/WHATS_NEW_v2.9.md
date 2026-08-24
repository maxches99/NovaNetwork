# What's New in 2.9

## Linux build gate for NovaNetworkClient

This is an audit-and-gate pass, not a claim that `NovaNetworkClient` is proven working on Linux
today: there is no prior Linux CI run for it to compare against, and this change was developed
without access to a Linux Swift toolchain. What follows is what was actually verified, versus
what is gated but unverified — the new CI job is the real verification, going forward.

**Verified (macOS + logic-level, not an actual Linux build):**

- Audited every source file in `NovaNetworkClient` for Apple-only imports and APIs. Certificate
  pinning/mTLS (`Security`) were already correctly gated behind `#if canImport(Security)` from
  the 2.4 release; no regression there.
- The offline queue's optional `AESGCMOfflineWriteStoreCipher` and
  `RotatingAESGCMOfflineWriteStoreCipher` are now gated behind `#if canImport(CryptoKit)`. This
  is a structural change only (the implementations themselves are untouched) — verified against
  the existing cipher test suite on macOS. `OfflineWriteStoreCipher` (the protocol) and
  `DiskOfflineWriteStore` (whose `cipher` parameter is already optional) are not gated; the
  offline queue itself works without this specific encryption strategy everywhere.
- Added a from-scratch, dependency-free `PortableSHA256`, used by `SHA256Util` — and therefore
  by request/cache-key fingerprinting and idempotency key generation — only where `CryptoKit`
  isn't available. Verified against the NIST SHA-256 test vectors (empty string, `"abc"`, the
  56-character two-block vector, one million repeated `"a"` characters) both directly and through
  incremental updates split at non-block-aligned boundaries, matching how `SHA256Util.hex(fileAt:)`
  streams a file. `CryptoKit.SHA256` continues to be used unchanged on Apple platforms.
- Deliberately did *not* hand-roll an AES-GCM replacement: fingerprinting is a hashing problem
  with a well-defined, independently-verifiable correct answer; authenticated encryption
  protecting data at rest is a much easier place to introduce a subtle, dangerous bug, and no
  external cryptography dependency was added without that being a decision for project
  maintainers to make explicitly.

**Gated but not run — the actual open question:**

- Added a `linux-client-build-gate` CI job (Ubuntu, Swift 6.2.3) that compiles
  `NovaNetworkClient` and `NovaNetworkClientTestSupport` — the first Linux CI coverage either has
  ever had. It is compile-only; running the test suite on Linux remains unverified.
- `URLSessionWebSocketTask` (used by the WebSocket transport), `NSObject`-based
  `URLSessionTaskDelegate`/`URLSessionDownloadDelegate` conformances (transfer progress), and the
  throwing `FileHandle.write(contentsOf:)` API (multipart encoding) are all believed compatible
  with swift-corelibs-foundation based on general knowledge of its API surface, but none of this
  has been exercised against a real Linux toolchain. The new CI job is what will actually confirm
  or refute that.

## Migration notes

- Additive only; no existing public API changed or moved behind a new availability gate on Apple
  platforms.
