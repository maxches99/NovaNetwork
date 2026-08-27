# Traceability Pack v2.12

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V2_12_DFR.md`
- Scope: the cassette model and JSON format, the recording and replaying transport, request
  matching, redaction, the scoped `withCassette` helper, and the standalone `NovaNetworkCassette`
  product.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-1, FR-2, FR-10, DR-1, UR-2 | `Sources/NovaNetworkCassette/Cassette.swift` |
| FR-3, FR-4, FR-5, FR-7, FR-8, FR-12 | `Sources/NovaNetworkCassette/CassetteTransport.swift` |
| FR-6, EC-2, EC-3 | `Sources/NovaNetworkCassette/CassetteMatchRule.swift` |
| FR-9, DR-2, EC-8 | `Sources/NovaNetworkCassette/CassetteRedaction.swift` |
| FR-11, UR-1 | `Sources/NovaNetworkCassette/WithCassette.swift` |
| FR-13 | `Sources/NovaNetworkCassette/CassetteError.swift`, `Cassette.load(from:)` |
| FR-14, NFR-2 | `Package.swift` (`NovaNetworkCassette` depends on `NovaNetworkCore` only), Linux CI gate |
| UR-3 | DocC comments on every public symbol, `RecordAndReplay.md` |
| UR-4 | `CassetteError.errorDescription` |
| AR-1, DR-3 | no telemetry, persistence, or existing code path changed |
| NFR-4 | coverage gate scope extended to `Sources/NovaNetworkCassette` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-1.1, T-1.2 | FR-1, FR-2, EC-4 | unit | `CassetteFormatTests` |
| T-3.1, T-3.2, T-3.3 | FR-3, FR-12, EC-1, EC-7 | unit | `CassetteReplayTests` |
| T-4.1, T-4.2 | FR-4, EC-5 | unit | `CassetteRecordingTests` |
| T-5.1 | FR-5 | unit | `CassetteRecordingTests` |
| T-6.1…T-6.4 | FR-6, FR-7, FR-8, EC-2, EC-3, NFR-5 | unit | `CassetteMatchingTests` |
| T-7.1, T-7.2 | FR-9, DR-2, EC-8 | unit | `CassetteRedactionTests` |
| T-8.1 | FR-10, UR-2 | unit | `CassetteFormatTests` |
| T-9.1 | FR-11 | unit | `WithCassetteTests` |
| T-10.1 | AR-1 | integration | `CassetteClientIntegrationTests` |
| T-11.1 | EC-6 | unit (concurrency) | `CassetteClientIntegrationTests` |
| T-12.1, T-12.2 | FR-13, DR-1 | unit | `CassetteFormatTests` |
| T-GATE-1…4 | NFR-1…NFR-4 | CI | zero-dependency check, coverage gate, Linux gate, API breakage gate |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `Sources/NovaNetworkCassette` (added to the gate) | 95.47% |
| Combined gate scope (client, core, generator, cassette) | see the pull request; above the 90% floor |

## Security and data contract

- Redaction runs at capture time, before an interaction is stored, so a credential never exists in a
  persisted value. Asserted by `credentialHeadersNeverReachTheRecording`, which searches the
  serialized bytes for the secret.
- The default policy covers `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`,
  `X-API-Key`, and `X-Auth-Token`; it is documented as a floor, not a guarantee for every API.
- Cassette files carry no timestamps and no environment data — only what the request and response
  contained after redaction.
- No existing persisted format changed.

## Verification gaps

- The example target performs one live request against a public API on its first run; it is built in
  CI but not executed there.
- Streaming responses, Server-Sent Events, and managed transfers are out of scope for this release
  and have no cassette coverage.
