# Traceability Pack v2.14

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V2_14_DFR.md`
- Scope: PKCE, the authorization code, refresh, client credentials, and device grants, OAuth 2.0
  error envelopes, the token model and stores, single-flight integration with the client's HTTP auth
  refresh, HMAC-SHA256 request signing, and SHA-256 as shared Core API.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-1 | `Sources/NovaNetworkCore/SHA256Util.swift`, `PortableSHA256.swift` (moved from the client) |
| FR-2, EC-8 | `Sources/NovaNetworkAuth/OAuth2Configuration.swift` (`PKCEChallenge`) |
| FR-3, FR-4, EC-3, EC-4 | `OAuth2Client.authorizationURL(state:challenge:)`, `authorizationCode(from:expectedState:)` |
| FR-5, FR-6, FR-7, EC-1 | `OAuth2Client.exchange(code:verifier:)`, `refresh(_:)`, `clientCredentialsToken()`, `OAuth2Token.retainingRefreshToken(from:)` |
| FR-8, UR-3, DR-3 | `Sources/NovaNetworkAuth/OAuth2Error.swift` |
| FR-9, EC-5 | `OAuth2Client.requestDeviceAuthorization()`, `pollForToken(_:sleep:)` |
| FR-10, EC-2 | `OAuth2Token.isExpired(now:leeway:)` |
| FR-11, DR-1, DR-2 | `TokenStore.swift`, `KeychainTokenStore.swift` |
| FR-12, FR-13, EC-6, EC-7, AR-1 | `OAuth2Authenticator.swift` (`refreshProvider`, `middleware`) |
| FR-14, NFR-5 | `RequestSigning.swift` (`HMACSHA256`, `HMACRequestSigner`) |
| UR-1 | `Examples/Authentication` |
| UR-2, UR-4 | DocC comments, `Authentication.md` |
| NFR-2 | Linux CI gate extended; Keychain behind `canImport(Security)` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-1.1 | FR-1 | unit | `PKCETests.theSharedSHA256IsTheOneCoreExposes` |
| T-2.1 | FR-2, EC-8 | unit | `PKCETests` |
| T-3.1, T-3.2 | FR-3, FR-4, EC-3, EC-4 | unit | `AuthorizationURLTests` |
| T-4.1…T-4.4 | FR-5…FR-8, EC-1 | unit | `GrantTests` |
| T-5.1 | FR-9, EC-5 | unit | `DeviceFlowTests` |
| T-6.1 | FR-10, EC-2 | unit | `OAuth2TokenTests` |
| T-7.1, T-7.2 | FR-11, DR-1, DR-2 | unit | `TokenStoreTests` |
| T-8.1, T-8.2 | FR-12, FR-13, EC-6, EC-7, AR-1 | unit/integration | `OAuth2AuthenticatorTests` |
| T-9.1, T-9.2 | FR-14, NFR-5 | unit | `RequestSigningTests` |
| — | UR-3, DR-3 | unit | `OAuth2ErrorTests` |
| T-GATE-1…4 | NFR-1…NFR-4 | CI | zero-dependency check, coverage gate, Linux gate, API breakage gate |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `Sources/NovaNetworkAuth`, excluding the Keychain store | 96.62% |
| `KeychainTokenStore.swift` | excluded from the gate, see below |

`KeychainTokenStore.swift` is excluded because its read and write paths need a real Keychain, which a
headless CI process cannot use reliably — an attempt can block on a UI prompt or fail on
entitlements, either of which would make the suite flaky for reasons unrelated to the code. Its query
construction, the part with logic worth checking, is unit tested.

## Security and data contract

- The `state` parameter is validated before the authorization code is read, and a mismatch throws
  without returning the code (`aStateMismatchIsRejectedBeforeTheCodeIsEvenRead`).
- PKCE verifiers come from `SystemRandomNumberGenerator` over RFC 7636's unreserved alphabet; a test
  asserts fifty generated verifiers are all distinct and correctly shaped.
- No error description contains a token, a verifier, or a state value; asserted across every case.
- Nothing is persisted unless a persisting store is chosen; the default is memory.
- Keychain items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are neither synced
  nor included in backups.
- The portable HMAC is verified against CryptoKit rather than a remembered vector.

## Verification gaps

- Keychain I/O is compiled but never executed in CI, for the reason above.
- No live provider is contacted; every grant is exercised against a scripted transport.
- AWS Signature Version 4 is deliberately absent, so there is nothing to verify for it.
