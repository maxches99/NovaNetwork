# What's New in 2.14

## Authentication, not just refresh

The client has always solved the hard half: `HTTPAuthRefreshPolicy` coordinates a single refresh
across a burst of unauthorized responses and replays them. What it took was a closure you had to fill
in, and filling it in meant implementing RFC 6749 by hand.

```swift
import NovaNetworkAuth

let authenticator = OAuth2Authenticator(client: OAuth2Client(configuration: configuration))

var clientConfiguration = NetworkClientConfiguration()
clientConfiguration.authRefreshProvider = authenticator.refreshProvider
clientConfiguration.middleware = [authenticator.middleware]
```

### The authorization code flow, with PKCE always on

```swift
let pkce = PKCEChallenge.generate()
let state = UUID().uuidString
let url = try oauth.authorizationURL(state: state, challenge: pkce)
// the app opens `url`, the provider sends the user back
let code = try oauth.authorizationCode(from: callbackURL, expectedState: state)
let token = try await oauth.exchange(code: code, verifier: pkce.verifier)
```

The verifier is 32 random bytes as base64url — 43 characters from RFC 7636's alphabet — and the
challenge is its SHA-256, so an intercepted authorization code is useless without the secret that
never left the device.

The `state` check runs **before** anything else is read, and a mismatch throws without returning the
code. That is not defensive tidiness: it is what stops an attacker's authorization code from being
redeemed in your user's session.

### One refresh, however many callers

An actor is not enough on its own. It suspends at the network call, so a second caller arriving
during a refresh would start a second one and one of the two tokens would be discarded. The
authenticator shares the in-flight task, so eight simultaneous callers produce one request to the
provider and all eight receive the same token.

Two details that are wrong more often than they are right:

- **A refresh response usually omits `refresh_token`**, meaning "keep using the one you have".
  Dropping it there is how a session ends an hour later for no visible reason.
- **A token with no `expires_in` is never treated as expired.** The provider chose not to say, and
  guessing would refresh working credentials on a timer.

A refresh rejected with `invalid_grant` clears the stored token, so the app can ask for a sign-in
rather than failing identically forever.

### Device flow

```swift
let authorization = try await oauth.requestDeviceAuthorization()
print("Go to \(authorization.verificationURI) and enter \(authorization.userCode)")
let token = try await oauth.pollForToken(authorization)
```

Polling follows RFC 8628: `authorization_pending` means wait and retry, `slow_down` means add five
seconds to the interval from then on. Ignoring either is how a device flow gets rate limited.

### Where the token lives

In memory by default. A library that persists credentials unless told otherwise is a library that
persists them in the one app that forgot to look. `KeychainTokenStore` files them as generic
passwords with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: reachable from a background
refresh, never copied to another device or into a backup.

### Signing with a shared secret

`HMACRequestSigner` covers the internal and partner APIs that authenticate with an HMAC instead of a
bearer token. The canonical string is documented on the method that builds it, because both sides
have to agree on it exactly: method, path, sorted query, timestamp, nonce, and the SHA-256 of the
body.

### SHA-256 moved rather than multiplied

The client carried a portable SHA-256 locked inside it. Auth needs the same primitive, and a second
copy of cryptography in a second module is how one of the copies ends up wrong, so it is now
documented `NovaNetworkCore` API — `SHA256Util.hex(_:)` and `SHA256Util.digest(_:)` — used by
fingerprinting, cache keys, integrity checks, and PKCE alike.

## What was verified

- 611 tests pass; 62 are new and cover PKCE generation and validation, the authorization URL and
  every callback outcome, all four grants, error envelopes at both 200 and 4xx, device polling
  including `slow_down`, expiry math, both token stores' contracts, single-flight refresh under eight
  concurrent callers, the middleware, and signing.
- `Sources/NovaNetworkAuth` joins the ≥90% coverage gate at 96.62% line coverage, with
  `KeychainTokenStore.swift` excluded and the reason stated in the workflow: its read and write paths
  need a real Keychain, which a headless CI process cannot use reliably. Its query construction is
  unit tested.
- The portable HMAC is asserted equal to CryptoKit's across two hundred random key and message sizes,
  including keys longer than the block size — rather than against a vector recalled from memory,
  which is a test that passes for the wrong reasons.
- `Examples/Authentication` runs the whole flow against a scripted provider and reports that eight
  concurrent callers produced exactly one refresh.

## Known limitations

- **No browser presentation.** It needs a window anchor, differs per platform, and every app already
  has an opinion. The library supplies the URL and parses the callback.
- **No AWS Signature Version 4.** Its correctness cannot be established without reference vectors,
  and an unverified signer would look finished and be dangerous. Follow-up work, stated rather than
  omitted.
- **The Keychain store's I/O is not exercised in CI**, for the reason above.
- Token introspection, revocation beyond the basics, and JWT decoding are not included.

## Migration notes

Additive. New product `NovaNetworkAuth`; no existing API changed shape or behavior, and the API
breaking-changes gate passes with no new allowlist entries. `SHA256Util` moved from an internal
client utility to public `NovaNetworkCore` API, which is an addition — the client's call sites and
behavior are unchanged.

## Source traceability

- DFR: [NovaNetwork 2.14 DFR](dfr/NOVA_NETWORK_V2_14_DFR.md)
- Traceability pack: [v2.14](TRACEABILITY_PACK_v2.14.md)
- Requirement IDs: FR-1…FR-14, UR-1…UR-4, DR-1…DR-3, AR-1, NFR-1…NFR-5, EC-1…EC-8
