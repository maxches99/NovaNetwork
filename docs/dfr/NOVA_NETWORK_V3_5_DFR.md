# NovaNetwork 3.5 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.5 — Safe cache defaults and providers that are not quite RFC 6749
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: adopter report in issue #48 (Supabase-backed SwiftUI app, 3.4.0)
- Target version: 3.5.0
- Source baseline: 3.4 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.5.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.5.md`
  - Reported by: https://github.com/maxches99/NovaNetwork/issues/48

## 2. Goal and Scope

### Goal

Stop the client caching responses to writes, and let an adopter whose token endpoint is not RFC
6749's keep the parts of `NovaNetworkAuth` that are worth keeping.

### User value

Both items in scope cost a real team real time, and both failed silently.

Caching was decided by the request's `Cache-Control` header alone, so a `POST` was cached like a
`GET`. A sign-in response was served from the cache with an expired token; refreshing it was rejected
as `invalid_grant`, and the app showed "wrong password". The cause took a week to find. The same
default meant an edit could be answered from the cache and never sent — a sync that reported success
and changed nothing.

Separately, `OAuth2Client` always posted a form-encoded body with `grant_type` inside it. Supabase's
GoTrue reads `grant_type` from the query string and the rest from JSON, so the adopter bypassed
`OAuth2Client` *and* `OAuth2Authenticator`, losing single-flight refresh and token storage — the two
reasons to take the module — and rebuilt part of it by hand through
`configuration.httpAuthRefreshProvider`.

### Scope split

- MVP / required for 3.5:
  - unsafe methods excluded from cache lookup and storage, with an explicit opt-in;
  - a configurable token-request shape (body encoding, `grant_type` placement, extra headers);
  - an injectable token exchange that keeps storage, single-flight refresh, and middleware;
  - the documentation gaps the same report named.
- Nice-to-have after MVP:
  - a `password` grant, so a GoTrue sign-in needs no closure at all;
  - per-parameter renaming for providers that use `email` where RFC 6749 uses `username`.

### Non-goals

- Implementing RFC 9111's `POST`-response caching rules (a `POST` cached against the URI of a
  subsequent `GET`). The opt-in is deliberately blunt.
- Becoming a Supabase client. The shape is described; the vocabulary is the app's.
- Changing what `enqueueWrite` does. Writes that must survive being offline still go there.

### Definition of Done

- A cached `POST` is impossible without a policy that names the opt-in, asserted per method.
- A GoTrue-shaped token request is produced by configuration alone, asserted on the wire.
- An injected exchange refreshes once across concurrent callers, asserted.
- DFR, traceability pack, release notes, README, DocC, and CHANGELOG updated together.

## 3. User Value

### User problem

A networking library's defaults are the part nobody reviews. Caching a `POST` is not something an
HTTP client is expected to do, so nobody looks there when a write goes missing — and neither failure
mode announces itself: one shows up as a wrong password, the other as a sync that worked.

The auth problem is the opposite shape. The module is taken *for* its storage and its single refresh;
the token request is the small part. Hard-coding the small part is what made the large part
unreachable.

### Success metrics

- No policy in the package can cache a response to `POST`, `PUT`, `PATCH`, or `DELETE` unless the
  policy says `includingUnsafeMethods`.
- A GoTrue token request is expressible without writing a `NetworkTransport`.
- An adopter with a non-standard endpoint writes one closure and keeps storage, single-flight
  refresh, `retainingRefreshToken(from:)`, the `invalid_grant` sign-out, and the middleware.

## 4. Rollout, Dependencies, Risks

### Rollout plan

The cache change is a behavior change and ships as one, described in the release notes with the
one-line opt-in for anyone who was relying on the old default. The auth additions are additive.

### Dependencies

None beyond Foundation.

### Risks and mitigations

- **An adopter depending on the old caching.** Mitigated by `CachePolicy.includingUnsafeMethods(_:)`,
  which restores the previous behavior for one call or for a whole client, and by naming it in the
  release notes rather than only in the changelog.
- **`switch` over `CachePolicy` in adopter code.** The new case is a source break for an exhaustive
  switch. Judged acceptable: the type is constructed and passed, not matched on, and the alternative
  designs put the opt-in somewhere it would not be read.
- **An opt-in used as a performance knob.** Mitigated by saying in the checklist and the symbol
  documentation what it costs, and by keeping `Cache-Control: no-store` authoritative over it.
- **A custom exchange that silently drops the refresh token.** Mitigated by keeping
  `retainingRefreshToken(from:)` on the library side of the boundary and asserting it.

## 5. Requirements

### Functional requirements (FR)

- **FR-CACHE-SAFE-1** `URLMethod` reports which methods are safe and which are cacheable without an
  opt-in; only `GET` and `HEAD` are the latter.
- **FR-CACHE-SAFE-2** Cache lookup and cache storage are both refused for a method that is not
  cacheable by default, under every `CachePolicy` and regardless of the response's `Cache-Control`.
- **FR-CACHE-SAFE-3** `CachePolicy.includingUnsafeMethods(_:)` restores participation for the
  strategy it wraps, per call or as a client default.
- **FR-CACHE-SAFE-4** `preload` stores nothing for a method that is not cacheable by default.
- **FR-OAUTH-SHAPE-1** `OAuth2TokenRequestStyle` decides body encoding (form or JSON) and whether
  `grant_type` is carried in the body or the query string.
- **FR-OAUTH-SHAPE-2** `additionalHeaders` is applied after the headers the client sets, so it can
  add or override.
- **FR-OAUTH-SHAPE-3** The style applies to every request the client sends to a provider, the device
  authorization request included.
- **FR-OAUTH-EXCHANGE-1** An injected `OAuth2TokenExchange` replaces the token request for every
  grant, and the transport is not used.
- **FR-OAUTH-EXCHANGE-2** The grant handed to the closure carries the `grant_type`, the parameters
  the standard request would have sent, the endpoint, and the token being refreshed.
- **FR-OAUTH-EXCHANGE-3** `OAuth2Authenticator` accepts an exchange directly and keeps single-flight
  refresh, storage, retained refresh tokens, and its middleware.
- **DX-METHOD-1** `HTTPMethod` names the same type as `URLMethod`.
- **DOC-1** The production checklist states the cache rule and what the opt-in costs.
- **DOC-2** Getting Started installs the diagnostics recorder in three lines.
- **DOC-3** An article says whether the offline queue or the app's own database owns an offline edit.
- **DOC-4** The query layer says what it is for when a local store already exists.

### Edge cases (EC)

- **EC-CACHE-SAFE-1** `Cache-Control: no-store` on the request still bypasses the cache when the
  opt-in is present.
- **EC-CACHE-SAFE-2** Nesting the opt-in, or wrapping a strategy with a negative window, normalizes
  to one wrapper around a clamped strategy.
- **EC-OAUTH-1** A request that carries no `grant_type` — the device authorization request — is
  unchanged by a style that places `grant_type` in the query string.
- **EC-OAUTH-2** A custom exchange that returns no refresh token keeps the previous one.

## 6. State Machine and Flows

Cache admission is now two gates in sequence: *may this method participate at all* → *what does
freshness say*. The first gate is the method and the policy's opt-in; the second is the existing
strategy. A request refused at the first gate emits `cacheMiss` and goes to the network without
storing, which is the path a `no-store` request already took.

A grant flows `parameters → OAuth2Grant → {injected exchange | styled request → transport} → token →
retainingRefreshToken → store`.

## 7. Engineering Notes

The opt-in is an `indirect case` rather than a new type or a flag on the client. A struct with static
factories would break every `case .cacheFirst(let maxAge)` in adopter code; a client-level flag would
be set once, far from the call it affects, and never re-read in review. Wrapping keeps the decision
at the call site and next to the strategy it modifies.

`CachePolicy.freshness` exists because `strategy` returns a `CachePolicy`, so switching over it would
still need a branch for a case it can never be. `freshness` is a separate, non-recursive enum, which
keeps the client's switch exhaustive without an unreachable arm.

The exchange is injected into `OAuth2Client` rather than into `OAuth2Authenticator`'s stored state,
so `OAuth2Authenticator.client` keeps its type. The authenticator's new initializer builds the client
for the caller, so the ergonomics the report asked for survive without an API break.

## 8. Test Matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-CACHE-SAFE-1, DX-METHOD-1 | T-15.1…T-15.6 | unit | Engineering |
| FR-CACHE-SAFE-2 | T-15.7, T-15.8 | unit | Engineering |
| FR-CACHE-SAFE-3 | T-15.9, T-15.10 | unit | Engineering |
| FR-CACHE-SAFE-4 | T-15.11 | unit | Engineering |
| EC-CACHE-SAFE-1, EC-CACHE-SAFE-2 | T-15.12, T-15.13, T-15.14 | unit | Engineering |
| FR-OAUTH-SHAPE-1, FR-OAUTH-SHAPE-2 | T-16.1, T-16.2, T-16.3 | unit | Engineering |
| FR-OAUTH-SHAPE-3, EC-OAUTH-1 | T-16.4, T-16.5 | unit | Engineering |
| FR-OAUTH-EXCHANGE-1, FR-OAUTH-EXCHANGE-2 | T-16.6, T-16.8 | unit | Engineering |
| FR-OAUTH-EXCHANGE-3, EC-OAUTH-2 | T-16.7, T-16.9 | unit | Engineering |

### Negative tests

- A `GET` still caches, so the gate is not simply off.
- `no-store` still wins over the opt-in.
- A device authorization request is untouched by a `grant_type`-in-query style.
- An injected exchange leaves the transport unused.

### Analytics

No new telemetry. A refused method emits the existing `cacheMiss`, which is what a `no-store` request
already emitted, so no dashboard changes shape.
