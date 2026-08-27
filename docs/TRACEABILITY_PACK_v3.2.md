# Traceability Pack v3.2

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_2_DFR.md`
- Scope: the adaptive concurrency policy and its algorithm, the admission actor, the wiring into the
  client's execution path, and the telemetry hook that reports limit movements.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-19, FR-20, FR-21, EC-17…EC-19 | `Sources/NovaNetworkClient/Networking/Policies/AdaptiveConcurrencyPolicy.swift` |
| FR-22, FR-23, EC-20, EC-21 | `Sources/NovaNetworkClient/Networking/Policies/AdaptiveConcurrencyLimiter.swift` |
| FR-24, FR-25 | `NetworkClient+AdaptiveConcurrency.swift`, `NetworkClient.swift` (inside `coalescer.run`) |
| FR-26 | `NetworkClientConfiguration.adaptiveConcurrency` |
| AR-2 | `TelemetryConcurrencyLimitContext`, `NetworkTelemetryHooks.onConcurrencyLimitChanged` |
| NFR-7 | additive parameters with defaults; API-breakage gate reports no breaking changes |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-11.1, T-11.2 | EC-17 | unit | `AdaptiveConcurrencyPolicyTests` |
| T-11.3…T-11.5 | FR-19 | unit | `AdaptiveConcurrencyStateTests` |
| T-11.6, T-11.7 | FR-20 | unit | `AdaptiveConcurrencyStateTests` |
| T-11.8…T-11.10 | FR-21, EC-18 | unit | `AdaptiveConcurrencyStateTests` |
| T-11.11, T-11.12 | EC-19 | unit | `AdaptiveConcurrencyStateTests` |
| T-11.13, T-11.14 | FR-22 | unit | `AdaptiveConcurrencyLimiterTests` |
| T-11.15, T-11.16 | FR-23, EC-20, EC-21 | unit | `AdaptiveConcurrencyLimiterTests` |
| T-12.1, T-12.2 | FR-24, FR-26 | integration | `AdaptiveConcurrencyClientTests` |
| T-12.3 | FR-25 | integration | `AdaptiveConcurrencyClientTests` |
| T-12.4, T-12.5 | FR-21, EC-22 | unit | `AdaptiveConcurrencyClientTests` |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `AdaptiveConcurrencyPolicy.swift` | every branch of `record`, both clamping paths |
| `AdaptiveConcurrencyLimiter.swift` | admission, waiting, cancellation, timeout, growth-driven admit |
| `NetworkClient+AdaptiveConcurrency.swift` | every signal-mapping branch, and both configured and unconfigured paths |

## Verification gaps

- The limiter is exercised against a scripted transport, not a real server under load. The peak
  concurrency assertions prove the ceiling holds; they do not prove the limit converges to a good
  value against real traffic.
- Latency degradation is tested by feeding samples to the state machine directly. No test drives it
  through the client with a transport that gets progressively slower.
- One limiter per client is a stated limitation, not a tested behaviour: nothing asserts what
  happens when a client talks to two hosts with different capacity.
- Warm start, per-host limits, and cross-process sharing are out of scope, so nothing tests them.
