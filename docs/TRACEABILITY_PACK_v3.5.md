# Traceability Pack v3.5

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_5_DFR.md`
- Scope: excluding unsafe methods from the response cache with an explicit opt-in, a configurable
  OAuth token-request shape, an injectable token exchange, and the four documentation gaps named in
  issue #48.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-CACHE-SAFE-1, DX-METHOD-1 | `Sources/NovaNetworkCore/URLMethod.swift` |
| FR-CACHE-SAFE-3, EC-CACHE-SAFE-2 | `Sources/NovaNetworkClient/Networking/Cache/CachePolicy.swift` |
| FR-CACHE-SAFE-2, EC-CACHE-SAFE-1 | `NetworkClient+CacheInternals.swift` |
| FR-CACHE-SAFE-2, FR-CACHE-SAFE-4 | `NetworkClient.swift` (`load`, `preload`, `fetchNetworkAndOptionallyStore`) |
| FR-OAUTH-SHAPE-1…3, FR-OAUTH-EXCHANGE-2 | `Sources/NovaNetworkAuth/OAuth2TokenRequest.swift` |
| FR-OAUTH-SHAPE-1…3, FR-OAUTH-EXCHANGE-1 | `Sources/NovaNetworkAuth/OAuth2Client.swift` |
| FR-OAUTH-SHAPE-1 | `Sources/NovaNetworkAuth/OAuth2Configuration.swift` |
| FR-OAUTH-EXCHANGE-3 | `Sources/NovaNetworkAuth/OAuth2Authenticator.swift` |
| DOC-1 | `NovaNetworkClient.docc/ProductionChecklist.md` |
| DOC-2 | `NovaNetworkClient.docc/GettingStarted.md` |
| DOC-3 | `NovaNetworkClient.docc/OfflineFirst.md` |
| DOC-4 | `NovaNetworkClient.docc/QueryLayer.md` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-15.1…T-15.5 | FR-CACHE-SAFE-1 | unit | `URLMethodTests` |
| T-15.6 | DX-METHOD-1 | unit | `URLMethodTests.httpMethodNamesTheSameType` |
| T-15.7 | FR-CACHE-SAFE-2 | unit | `UnsafeMethodCacheTests.unsafeMethodsBypassTheCacheEvenWhenTheServerMarksTheResponseCacheable` |
| T-15.8 | FR-CACHE-SAFE-2 | unit | `UnsafeMethodCacheTests.staleWhileRevalidateAlsoLeavesUnsafeMethodsAlone` |
| T-15.9 | FR-CACHE-SAFE-3 | unit | `UnsafeMethodCacheTests.includingUnsafeMethodsOptsPostBackIn` |
| T-15.10 | FR-CACHE-SAFE-3 | unit | `UnsafeMethodCacheTests.aClientConfiguredToCacheUnsafeMethodsDoesSoWithoutAPerCallPolicy` |
| T-15.11 | FR-CACHE-SAFE-4 | unit | `UnsafeMethodCacheTests.preloadDoesNotStoreAnUnsafeMethod` |
| T-15.12 | EC-CACHE-SAFE-1 | unit | `UnsafeMethodCacheTests.noStoreStillWinsOverTheOptIn` |
| T-15.13, T-15.14 | EC-CACHE-SAFE-2 | unit | `UnsafeMethodCacheTests` (`normalizing…`, `policyReportsItsStrategyAndOptIn`) |
| T-16.1 | FR-OAUTH-SHAPE-1 | unit | `OAuth2TokenRequestStyleTests.theDefaultStyleIsStillRFC6749` |
| T-16.2 | FR-OAUTH-SHAPE-1 | unit | `OAuth2TokenRequestStyleTests.aJSONBodyWithGrantTypeInTheQueryMatchesGoTrue` |
| T-16.3 | FR-OAUTH-SHAPE-2 | unit | `OAuth2TokenRequestStyleTests.additionalHeadersAreAppliedAfterTheOnesThisClientSets` |
| T-16.4 | FR-OAUTH-SHAPE-3 | unit | `OAuth2TokenRequestStyleTests.theDeviceAuthorizationRequestUsesTheSameStyle` |
| T-16.5 | EC-OAUTH-1 | unit | `OAuth2TokenRequestStyleTests.aStyleWithGrantTypeInTheQueryLeavesARequestThatHasNoneAlone` |
| T-16.6 | FR-OAUTH-EXCHANGE-1, FR-OAUTH-EXCHANGE-2 | unit | `OAuth2TokenExchangeTests.anInjectedExchangeReplacesTheTokenRequestEntirely` |
| T-16.7 | EC-OAUTH-2 | unit | `OAuth2TokenExchangeTests.anInjectedExchangeStillKeepsARefreshTokenTheProviderOmitted` |
| T-16.8 | FR-OAUTH-EXCHANGE-1 | unit | `OAuth2TokenExchangeTests.everyOtherGrantReachesTheExchangeToo` |
| T-16.9 | FR-OAUTH-EXCHANGE-3 | unit | `OAuth2TokenExchangeTests.theAuthenticatorRefreshesOnceThroughAnInjectedExchange` |

## Coverage at merge

| Scope | Covered |
|---|---|
| `URLMethod.swift` | both properties across all seven methods |
| `CachePolicy.swift` | every strategy through `normalized`, `strategy`, `freshness`, and the opt-in |
| `NetworkClient+CacheInternals.swift` | the method gate on both the lookup and the storage path |
| `OAuth2TokenRequest.swift` | both encodings, both placements, additional headers |
| `OAuth2Client.swift` | styled requests and the injected exchange, on every grant |

## Verification gaps

- **No live provider.** The GoTrue shape is asserted against the request this client produces, not
  against Supabase. The claim is "this is the documented shape", not "this was accepted by a server".
- **The `password` grant is still absent.** A GoTrue sign-in goes through an injected exchange or
  through the app's own code and `setToken(_:)`; nothing here tests a password grant because there
  is none to test.
- **RFC 9111's `POST` caching rules are not implemented.** The opt-in is per policy, not per the
  spec's conditions on cacheable `POST` responses, and no test claims otherwise.
- **The added enum case is a source break for an exhaustive switch** over `CachePolicy` in adopter
  code. It is deliberate, stated in the release notes, and carried in
  `docs/api-breakage-allowlist.txt` with its reasoning in `CONTRIBUTING.md` — the only entry there
  that is not merely a defaulted parameter.
