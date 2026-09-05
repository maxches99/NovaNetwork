# Authentication

PKCE, the grants, somewhere safe to keep the token, and request signing — the parts every adopter
currently writes by hand.

## Overview

`NetworkClient` already solves the hard half of authentication: `HTTPAuthRefreshPolicy` coordinates a
single refresh across a burst of unauthorized responses and replays them. What it takes is a closure
you have to fill in, and filling it in means implementing RFC 6749 by hand.

`NovaNetworkAuth` fills it in:

```swift
import NovaNetworkAuth

let oauth = OAuth2Client(configuration: OAuth2Configuration(
    clientID: "your-client-id",
    authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
    tokenEndpoint: URL(string: "https://auth.example.com/token")!,
    redirectURI: URL(string: "yourapp://callback")!,
    scopes: ["profile", "email"]
))
let authenticator = OAuth2Authenticator(client: oauth)

var configuration = NetworkClientConfiguration()
configuration.authRefreshProvider = authenticator.refreshProvider
configuration.middleware = [authenticator.middleware]
let client = NetworkClient(configuration: configuration)
```

From here the token is attached to outgoing requests, refreshed before it expires, and refreshed
again — once, not per caller — whenever the server disagrees with the local clock.

## The authorization code flow

Three steps, and the library owns the two that are easy to get wrong.

```swift
// 1. Start. Keep the verifier and the state; the callback is worthless without them.
let pkce = PKCEChallenge.generate()
let state = UUID().uuidString
let url = try oauth.authorizationURL(state: state, challenge: pkce)

// 2. The app opens `url` and receives the callback. Presenting a browser needs a window anchor,
//    which is why it is the app's job and not this library's.

// 3. Finish.
let code = try oauth.authorizationCode(from: callbackURL, expectedState: state)
let token = try await oauth.exchange(code: code, verifier: pkce.verifier)
try await authenticator.setToken(token)
```

**PKCE is not optional here.** The verifier is 32 random bytes rendered base64url — 43 characters
from the unreserved alphabet — and the challenge is its SHA-256. An intercepted authorization code is
useless without the verifier that never left the device.

**The `state` check comes first.** `authorizationCode(from:expectedState:)` validates it before it
reads anything else, and a mismatch throws without returning the code. That check is what stops an
attacker's authorization code being redeemed in your user's session; skipping it is a login-CSRF.

## Refreshing once, not per caller

```swift
let token = try await authenticator.validToken()
```

An actor is not enough on its own: it suspends at the network call, so a second caller arriving
during a refresh would start a second one and one of the two tokens would be discarded. The
authenticator shares the in-flight refresh task instead, so eight simultaneous callers produce one
request to the provider and all eight get the same token.

Two details that are wrong more often than they are right:

- **A refresh response usually omits `refresh_token`**, meaning "keep using the one you have".
  Dropping it there is how a session ends an hour later for no visible reason, so the previous one is
  retained automatically.
- **A token with no `expires_in` is never treated as expired.** The provider chose not to say;
  guessing would refresh working credentials on a timer.

When a refresh fails with `invalid_grant`, the stored token is cleared: the session is over, and
keeping a revoked token makes every later request fail identically without ever asking the user to
sign in.

## Device flow

For televisions, consoles, and command-line tools:

```swift
let authorization = try await oauth.requestDeviceAuthorization()
print("Go to \(authorization.verificationURI) and enter \(authorization.userCode)")
let token = try await oauth.pollForToken(authorization)
```

Polling honors RFC 8628: `authorization_pending` means wait and retry, `slow_down` means add five
seconds to the interval from then on. Ignoring either is how a device flow gets rate limited by the
provider.

## A provider that is not quite RFC 6749

Plenty of services speak "OAuth 2.0" and shape the token request differently. Supabase's GoTrue reads
`grant_type` from the query string and everything else from a JSON body:

```
POST /auth/v1/token?grant_type=password
{"email": "...", "password": "..."}
```

Say so, and the standard grants keep working:

```swift
var configuration = OAuth2Configuration(clientID: projectRef, tokenEndpoint: gotrueTokenURL)
configuration.tokenRequestStyle = OAuth2TokenRequestStyle(
    bodyEncoding: .json,
    grantTypePlacement: .query,
    additionalHeaders: ["apikey": anonKey]
)
```

``OAuth2TokenRequestStyle/additionalHeaders`` is applied after the headers this library sets, so a
provider-wide API key lands on every token request and can override a default rather than fight it.

When the difference is larger than an encoding — a different parameter vocabulary, a signature over
the body, a grant that is not an OAuth grant — supply the exchange itself:

```swift
let authenticator = OAuth2Authenticator(
    configuration: configuration,
    exchange: OAuth2TokenExchange { grant in try await myTokenRequest(grant) },
    store: KeychainTokenStore(service: "com.example.app", account: "session")
)
```

The closure receives an ``OAuth2Grant`` — the `grant_type`, the parameters the standard request would
have carried, the endpoint, and the token being refreshed — and returns an `OAuth2Token`. Everything
around it stays library-side: storage, the single refresh across a burst of unauthorized responses,
`retainingRefreshToken(from:)`, clearing the session on `invalid_grant`, and the middleware. Writing
the token request is the part your provider made you write; writing the rest again is the part this
avoids.

For a sign-in this library has no grant for — `grant_type=password` among them — perform it yourself
and hand the result over with `setToken(_:)`. Refresh still runs through the exchange from then on.

## Where the token lives

The choice is explicit, and the default is memory:

```swift
OAuth2Authenticator(client: oauth, store: InMemoryTokenStore())                       // default
OAuth2Authenticator(client: oauth, store: KeychainTokenStore(service: "com.example.app", account: "user-1"))
```

A library that persists credentials unless told otherwise is a library that persists credentials in
the one app that forgot to look. `KeychainTokenStore` files items as generic passwords with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: reachable from a background refresh, never copied
to another device or into a backup.

## Signing with a shared secret

Many internal and partner APIs authenticate with an HMAC rather than a bearer token:

```swift
let signer = HMACRequestSigner(keyID: "key-1", secret: secret)
configuration.middleware = [signer.middleware()]
```

The canonical string is documented on `canonicalString(for:timestamp:nonce:)` because both sides have
to agree on it exactly: method, path, sorted query, timestamp, nonce, and the SHA-256 of the body.
Sorting the query means a client that reorders parameters still verifies; hashing the body keeps the
canonical string constant-size.

The HMAC uses CryptoKit where it exists and a portable implementation elsewhere. The two are asserted
equal across two hundred random key and message sizes, rather than against a vector recalled from
memory — that kind of test passes for the wrong reasons.

## What this does not do

- **Present a browser.** It needs a window anchor, it differs per platform, and every app already has
  an opinion. This gives you the URL and parses the callback.
- **Sign for AWS.** Signature Version 4 is a large specification whose correctness cannot be
  established without reference vectors, and an unverified signer would look finished and be
  dangerous. It is follow-up work, not a quiet omission.
- **Store anything by default.** See above.

## The symbols

`OAuth2Configuration` and `PKCEChallenge` describe the flow, and `OAuth2TokenRequestStyle` says what
shape a token request takes on the wire; `OAuth2Client` performs the grants, or hands them to an
`OAuth2TokenExchange` as an `OAuth2Grant`;
`OAuth2Token`, `DeviceAuthorization`, and `OAuth2Error` are what comes back. `OAuth2Authenticator`
holds the token and produces the `HTTPAuthRefreshProvider` and middleware. `TokenStore`,
`InMemoryTokenStore`, and `KeychainTokenStore` decide where it lives. `HMACRequestSigner` and
`HMACSHA256` sign.

They live in the `NovaNetworkAuth` module.

## See Also

- <doc:ProductionChecklist>
- <doc:ChoosingAnAPI>
