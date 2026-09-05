# What's New in 3.5

Both changes here come from one adopter's report ([#48]) after moving a SwiftUI app onto
`NovaNetworkClient` and `NovaNetworkAuth` 3.4.0 against a Supabase backend. Both cost that team real
time, and both failed quietly.

## Writes are no longer cached

Until now, whether a response could be cached was decided by the request's `Cache-Control` header
alone. The method was never consulted, so a `POST` was cached like a `GET`.

That bit twice in one app:

- a sign-in response was served from the cache carrying an expired token; refreshing it was rejected
  as `invalid_grant`, and the screen said "wrong password". A week went into looking in the wrong
  place.
- an edit could be answered from the cache and never sent: a sync that reported success and changed
  nothing.

From 3.5, `POST`, `PUT`, `PATCH`, and `DELETE` take part in neither cache lookup nor cache storage,
under every `CachePolicy`, whatever the server's `Cache-Control` says. `GET` and `HEAD` — the two
methods RFC 9111 makes cacheable by default — are unchanged.

A `POST` that really is a read says so:

```swift
let data = try await client.load(
    request: searchRequest,
    authScope: "user:42",
    cachePolicy: .includingUnsafeMethods(.cacheFirst(maxAge: 30))
)
```

The opt-in wraps a strategy rather than sitting on the client, so it is read where it applies. It can
still be a client-wide default when that is genuinely what you mean:

```swift
configuration.defaultCachePolicy = .includingUnsafeMethods(.staleWhileRevalidate(maxAge: 20, staleAge: 180))
```

`Cache-Control: no-store` on a request still wins over the opt-in.

Two properties on `URLMethod` say what the pipeline consults: `isSafe` and `isCacheableByDefault`.
And because the type is hard to find by name, `HTTPMethod` is now a typealias for it — both spellings
compile, and searching the documentation for either one works.

## An OAuth endpoint that is not quite RFC 6749

`OAuth2Client` always posted a form-encoded body with `grant_type` inside it. Supabase's GoTrue wants
`grant_type` in the query string and JSON in the body, so the whole module had to be bypassed — and
bypassing it meant losing single-flight refresh and token storage, which are the reasons to take it.

Two ways back, depending on how far the provider strays.

**Describe the shape.** Encoding, where `grant_type` goes, and headers to add:

```swift
configuration.tokenRequestStyle = OAuth2TokenRequestStyle(
    bodyEncoding: .json,
    grantTypePlacement: .query,
    additionalHeaders: ["apikey": anonKey]
)
```

That is enough for a GoTrue refresh. `additionalHeaders` is applied last, so a provider-wide API key
lands on every token request and can override a default rather than fight it.

**Or supply the exchange.** When the difference is bigger than an encoding — a different parameter
vocabulary, a signature over the body, a grant that is not an OAuth grant:

```swift
let authenticator = OAuth2Authenticator(
    configuration: configuration,
    exchange: OAuth2TokenExchange { grant in try await myTokenRequest(grant) },
    store: KeychainTokenStore(service: "com.example.app", account: "session")
)
```

The closure receives an `OAuth2Grant` — the `grant_type`, the parameters the standard request would
have carried, the endpoint, and the token being refreshed — and returns an `OAuth2Token`. Everything
else stays where it was: storage, one refresh across a burst of 401s, the retained refresh token when
the provider omits it, the `invalid_grant` sign-out, and the middleware. A sign-in this package has
no grant for — `grant_type=password` among them — is still performed by the app and handed over with
`setToken(_:)`; refresh runs through the exchange from then on.

## Documentation the same report asked for

- **[Offline-First Apps](../Sources/NovaNetworkClient/NovaNetworkClient.docc/OfflineFirst.md)**, a new
  article answering the question the offline queue's documentation left open: when the unit of an
  edit is a row in SwiftData or GRDB rather than a request, the app owns it and the queue is the
  wrong shape — and running both over one edit sends it twice.
- **The query layer** now says what it is for when a local store already exists: it caches server
  state you do not persist, and your store is the cache for anything you do.
- **Getting Started** installs `DiagnosticsRecorder` in three lines, near the beginning. Half a day
  spent on a "server not found" that turned out to be a VPN is half a day the panel would have saved.
- **The production checklist** states the cache rule and what the opt-in costs.

## What was verified

- 25 new tests: 10 for the cache gate and the policy, 9 for the request style and the injected
  exchange, 6 for the method classification.
- The full suite: 870 tests, green.
- A `GET` still caches, so the new gate is not simply off; `no-store` still wins over the opt-in; an
  injected exchange leaves the transport untouched; and an injected exchange still refreshes once
  across concurrent callers.

## Migration notes

**The cache change is a behavior change.** If you relied on responses to writes being cached, wrap
the policy in `.includingUnsafeMethods(_:)` — one line per call site, or once on the client.

**`CachePolicy` gained a case.** Code that switches exhaustively over it needs an arm for
`.includingUnsafeMethods`; `policy.strategy` gives the wrapped strategy and
`policy.includesUnsafeMethods` the flag.

Everything in `NovaNetworkAuth` is additive: `tokenRequestStyle` defaults to the RFC 6749 shape, and
a client with no exchange behaves exactly as before.

## Source traceability

- DFR: `docs/dfr/NOVA_NETWORK_V3_5_DFR.md`
- Traceability pack: `docs/TRACEABILITY_PACK_v3.5.md`
- Reported in: [#48]

[#48]: https://github.com/maxches99/NovaNetwork/issues/48
