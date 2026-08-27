# NovaNetwork 2.14 DFR

## 1. Metadata

- Feature name: NovaNetwork 2.14 — Authentication, not just refresh
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, Security
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 2.14.0
- Source baseline: 2.13 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v2.14.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v2.14.md`
  - DocC article: `Sources/NovaNetworkClient/NovaNetworkClient.docc/Authentication.md`

## 2. Goal and Scope

### Goal

Ship the parts of authentication that every adopter currently writes by hand and gets subtly wrong:
PKCE, the token exchange, the refresh grant, the device flow, somewhere safe to keep the result, and
request signing. The client already coordinates *when* to refresh; this supplies *what* to refresh
with.

### User value

`HTTPAuthRefreshProvider` solves the hard concurrency problem — one refresh, not a stampede — but it
takes a closure the adopter has to fill in. Filling it in means implementing RFC 6749 by hand:
building the authorization URL, generating a code verifier and its S256 challenge, validating
`state`, posting form-encoded grants, parsing an error envelope that is not JSON-shaped like the
success one, deciding when a token counts as expired, and finding somewhere to keep it that is not
`UserDefaults`. Each of those has a wrong version that works until it does not.

### Scope split

- MVP / required for 2.14:
  - PKCE (S256) generation and verification;
  - authorization URL construction and redirect callback parsing with `state` validation;
  - authorization code, refresh token, and client credentials grants;
  - device authorization grant (RFC 8628) with correct `authorization_pending` and `slow_down`
    handling;
  - typed OAuth 2.0 error envelope parsing (RFC 6749 §5.2);
  - a token model that knows when it is expired, with leeway;
  - a token store protocol, an in-memory store, and a Keychain store on Apple platforms;
  - single-flight integration: an authenticator that produces `HTTPAuthRefreshProvider` and a
    middleware that attaches the current token;
  - HMAC-SHA256 request signing;
  - SHA-256 promoted from an internal client utility to a documented `NovaNetworkCore` API, so
    nothing has to duplicate cryptography.
- Nice-to-have after MVP:
  - AWS Signature Version 4;
  - an `ASWebAuthenticationSession` wrapper;
  - token introspection and revocation beyond the basic revoke call;
  - JWT decoding helpers.

### Non-goals

- Presenting a browser. Presentation needs a window anchor and belongs to the app; this supplies the
  URL to open and parses what comes back.
- Being an identity provider SDK. No provider-specific quirks, no hosted-UI assumptions.
- Storing credentials anywhere by default. A store is chosen explicitly, and the in-memory one is
  the default precisely so nothing is persisted by accident.
- **AWS Signature Version 4.** Deliberately excluded: it is a large specification whose correctness
  cannot be established without reference vectors, and shipping an unverified signer is worse than
  shipping none. Follow-up work.

### Definition of Done

- [x] DFR updated and approved
- [x] Code implemented
- [x] Tests added/updated per matrix, unit coverage stays above 90%
- [x] Telemetry reviewed (see AR-1)
- [x] "What's New" added
- [x] Traceability pack added
- [x] Documentation (DocC, README, examples) updated
- [x] Rollout plan documented

## 3. User Value

### User problem

The refresh closure is where every adopter's authentication code goes to be written badly. The
failure modes are quiet: a code verifier generated from a non-uniform alphabet, a missing `state`
check that turns into a login-CSRF, an expiry compared without leeway so every refresh races the
server clock, a device flow that ignores `slow_down` and gets rate limited, a refresh token in
`UserDefaults`.

### Success metrics

| Metric | Baseline | Target | Measurement method |
|---|---|---|---|
| Lines to wire OAuth2 into the client | ~150 hand-written | ≤ 10 | `Examples/Authentication` |
| Cryptographic implementations duplicated across modules | 1 (client-internal SHA-256) | 0 shared, 0 duplicated | Core API, `T-1.1` |
| Grants covered by tests | 0 | authorization code, refresh, client credentials, device | `T-4.x`, `T-5.x` |
| Credentials in a default configuration's persistent storage | n/a | 0 | `T-7.1` |

## 4. Rollout, Dependencies, Risks

### Rollout plan

- Feature flag: none. New product `NovaNetworkAuth`; nothing existing changes behavior.
- Initial rollout: additive minor release 2.14.0.
- Segments: all consumers; opt-in by linking the product.
- Rollback trigger: none applicable — existing auth refresh keeps working untouched.

### Dependencies

- Internal: `NovaNetworkCore` (requests, SHA-256), `NovaNetworkClient` (`HTTPAuthRefreshProvider`,
  middleware).
- External: none. `CryptoKit` and `Security` are used behind `canImport`.

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| A hand-rolled HMAC is wrong | High | Medium | CryptoKit is used where available; the portable path is asserted equal to CryptoKit's output across many random inputs, and against a fixed vector |
| Tokens end up somewhere insecure | High | Medium | In-memory by default, Keychain provided, and the protocol makes the choice explicit rather than implicit |
| PKCE verifier is predictable | High | Low | Generated from `SystemRandomNumberGenerator` over the RFC 7636 unreserved alphabet, length validated to 43–128 |
| `state` is not validated, enabling login CSRF | High | Medium | Callback parsing requires the expected state and fails with a typed error on mismatch |
| Device flow gets rate limited | Medium | Medium | `authorization_pending` and `slow_down` handled per RFC 8628, with the interval increasing as required |

## 5. Requirements

### Functional requirements (FR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | SHA-256 becomes a documented `NovaNetworkCore` API, used by the client and by auth | Client fingerprints unchanged; auth uses the same implementation | T-1.1 |
| FR-2 | PKCE generates a verifier in the RFC 7636 alphabet, 43–128 characters, and an S256 challenge | Challenge equals base64url(SHA256(verifier)) with no padding | T-2.1 |
| FR-3 | Authorization URL carries client id, redirect URI, scope, state, challenge, and method | URL query matches the configuration exactly | T-3.1 |
| FR-4 | Callback parsing returns the code, rejects a state mismatch, and maps an error redirect | Each case produces its documented result | T-3.2 |
| FR-5 | Authorization code grant exchanges a code and verifier for a token | Form body and headers match RFC 6749; token parsed | T-4.1 |
| FR-6 | Refresh grant exchanges a refresh token, preserving the old refresh token when the server omits one | Both cases verified | T-4.2 |
| FR-7 | Client credentials grant is supported | Token parsed from a client credentials response | T-4.3 |
| FR-8 | OAuth 2.0 error envelopes become typed errors carrying `error`, description, and URI | A 400 with an envelope maps to the typed case, not a generic HTTP error | T-4.4 |
| FR-9 | Device authorization grant polls, honoring `authorization_pending`, `slow_down`, `expired_token`, and `access_denied` | Interval increases on `slow_down`; each terminal case maps to its error | T-5.1 |
| FR-10 | A token knows whether it is expired, with configurable leeway | Expiry math verified against a fixed clock | T-6.1 |
| FR-11 | A token store protocol with in-memory and Keychain implementations | In-memory round-trips; Keychain compiles and is used only where `Security` exists | T-7.1 |
| FR-12 | An authenticator provides `HTTPAuthRefreshProvider` and refreshes at most once per expiry | Concurrent callers share one refresh | T-8.1 |
| FR-13 | A middleware attaches the current token to outgoing requests | Header present; requests without a token are left alone | T-8.2 |
| FR-14 | HMAC-SHA256 request signing over a documented canonical form | Signature stable for the same inputs and different for changed ones | T-9.1 |

### UX requirements (UR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Wiring OAuth2 into a client is a handful of lines | `Examples/Authentication` | Example |
| UR-2 | Every public symbol carries DocC documentation | No missing-doc warnings | DocC build |
| UR-3 | Errors say which grant failed and what the server said | Typed errors carry the server's `error` and description | T-4.4 |
| UR-4 | The article states plainly what the library does not do: present a browser, store by default, or sign for AWS | Documented | `Authentication.md` |

### Data requirements (DR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Nothing is persisted unless a persisting store is chosen | Default configuration uses the in-memory store | T-7.1 |
| DR-2 | Keychain items are scoped and do not sync by default | Item attributes verified where `Security` exists | T-7.2 |
| DR-3 | Tokens never appear in diagnostics or logs produced by this module | No `print`, and token values are excluded from error descriptions | T-4.4 |

### Analytics requirements (AR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | No new telemetry. The client's existing HTTP auth refresh telemetry already reports the single-flight lifecycle | Refresh through the authenticator emits the existing events unchanged | T-8.1 |

### Non-functional requirements (NFR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | No new package dependencies | `swift package show-dependencies` unchanged | CI |
| NFR-2 | Compiles on Linux under complete concurrency checking; Keychain is Apple-only | Linux gate extended | CI |
| NFR-3 | Additive: no existing public symbol changes shape | API breaking-changes gate passes | CI |
| NFR-4 | Unit coverage stays above 90% | Coverage gate includes the new target | CI |
| NFR-5 | The portable HMAC agrees with CryptoKit on every tested input | Equivalence test over many random inputs | T-9.2 |

### Edge cases (EC)

| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Server omits `refresh_token` on refresh | The previous refresh token is retained | T-4.2 |
| EC-2 | Server omits `expires_in` | The token is treated as non-expiring rather than immediately stale | T-6.1 |
| EC-3 | Callback URL carries `error=access_denied` | Typed error naming the server's reason | T-3.2 |
| EC-4 | Callback state does not match | Typed mismatch error; the code is not used | T-3.2 |
| EC-5 | Device flow returns `slow_down` | Interval increases by 5 seconds per RFC 8628 before the next poll | T-5.1 |
| EC-6 | Two requests need a refresh at once | One refresh runs; both get the new token | T-8.1 |
| EC-7 | Token store is empty when a request is made | The middleware sends the request unauthenticated rather than failing | T-8.2 |
| EC-8 | Verifier outside 43–128 characters | Rejected at construction with a typed error | T-2.1 |

## 6. State Machine and Flows

| From | Trigger | To | Notes |
|---|---|---|---|
| `unauthenticated` | authorization URL opened, callback parsed | `authorizing` | State validated, code extracted |
| `authorizing` | code exchanged | `authenticated` | Token stored |
| `authenticated` | token expired, request needs auth | `refreshing` | Single-flight; concurrent callers join |
| `refreshing` | refresh succeeds | `authenticated` | New token stored, refresh token retained when omitted |
| `refreshing` | refresh fails with `invalid_grant` | `unauthenticated` | Token cleared; the app must re-authorize |
| `unauthenticated` | device authorization requested | `pollingDevice` | User code shown by the app |
| `pollingDevice` | `authorization_pending` / `slow_down` | `pollingDevice` | Interval respected, increased on `slow_down` |
| `pollingDevice` | token issued | `authenticated` | Token stored |
| `pollingDevice` | `expired_token` / `access_denied` | `unauthenticated` | Typed error |

## 7. Engineering Notes

- **The client already owns the hard part.** Single-flight refresh, replay, and bounded attempts are
  existing behavior; this release fills in the closure rather than reimplementing coordination.
- **SHA-256 moves rather than multiplies.** The client had a portable implementation locked inside
  it. Auth needs the same primitive, and a second copy of cryptography in a second module is exactly
  the kind of duplication that ends with one of them being wrong. It becomes documented Core API.
- **The portable HMAC is checked against CryptoKit, not against my memory of RFC 4231.** A test
  compares both implementations over many random key and message sizes wherever CryptoKit exists.
  Asserting a vector recalled rather than looked up would be worse than not asserting one.
- **In-memory by default.** A library that persists credentials unless told otherwise is a library
  that persists credentials in the one app that forgot to look.
- **No AWS SigV4 in this release.** Its correctness needs reference vectors; an unverified signer
  would look finished and be dangerous.
- **No browser presentation.** It needs a window anchor, it differs per platform, and every app
  already has an opinion. The library supplies the URL and parses the callback.

## 8. Test Matrix

| Requirement ID | Test ID | Test type | Owner | Status |
|---|---|---|---|---|
| FR-1 | T-1.1 | unit | Engineering | done |
| FR-2, EC-8 | T-2.1 | unit | Engineering | done |
| FR-3, FR-4, EC-3, EC-4 | T-3.1, T-3.2 | unit | Engineering | done |
| FR-5, FR-6, FR-7, FR-8, EC-1 | T-4.1…T-4.4 | unit | Engineering | done |
| FR-9, EC-5 | T-5.1 | unit | Engineering | done |
| FR-10, EC-2 | T-6.1 | unit | Engineering | done |
| FR-11, DR-1, DR-2 | T-7.1, T-7.2 | unit | Engineering | done |
| FR-12, FR-13, AR-1, EC-6, EC-7 | T-8.1, T-8.2 | integration | Engineering | done |
| FR-14, NFR-5 | T-9.1, T-9.2 | unit | Engineering | done |

### Negative tests

- T-3.2 asserts a state mismatch and an `error=` redirect both fail with typed errors and no code is returned.
- T-4.4 asserts an OAuth error envelope maps to a typed case and that no token value appears in the message.
- T-5.1 asserts `slow_down` increases the interval and that `expired_token` and `access_denied` terminate.
- T-9.2 asserts the portable HMAC matches CryptoKit rather than a remembered vector.
