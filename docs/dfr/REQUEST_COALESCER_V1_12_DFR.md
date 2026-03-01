# RequestCoalescer v1.12 Platform Hardening DFR

## 1. Metadata
- Feature name: Platform Hardening
- Owner: Networking SDK
- Stakeholders: Product, QA, SDK Integrations
- Status: Approved
- Target version/build: v1.12
- Definition of Done:
  - [x] DFR updated
  - [x] Code implemented
  - [x] Tests updated per matrix
  - [x] Telemetry contracts updated
  - [x] `docs/WHATS_NEW_v1.12.md` added
  - [x] Rollout and monitoring notes documented
- Rollout plan: direct rollout on release tag `1.12` with benchmark and E2E gates required in CI.
- Dependencies: SwiftPM, public E2E APIs, benchmark baseline files.

## 2. Goal and Non-goals
### Goal
Make SDK runtime behavior more predictable under load by hardening coalescing policy controls, runtime tuning hooks, deterministic telemetry contracts, and stress guardrails.

### Non-goals
- WebSocket delivery semantic changes.
- New transport types/platform ports.
- Product-level sync workflows (moved to v1.14).

## 3. User Value
### Problem statement
Consumers need deterministic runtime controls under load without client recreation and without policy ambiguity across global, host, and endpoint scopes.

### Success metrics
| Metric | Baseline | Target | Measurement |
|---|---:|---:|---|
| Retry-exhausted share under degraded tests | current stress suite | reduce vs baseline | stress retry scenario telemetry |
| Mixed-load p95/p99 stability | no explicit v1.11 gate | bounded by stress baseline | stress suite + baseline check |
| Flaky rate in concurrency suites | intermittent race risk | no flaky regressions | repeated CI/unit runs |

## 4. Requirements
### Functional (FR)
| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-1 | Coalescing TTL window for dedupe sharing | Runtime policy supports `coalescingPolicy.dedupeTTLSeconds`; same request shares only inside active TTL bucket. |
| FR-2 | Scope controls for dedupe policy | `global`, `host`, `endpoint` scopes supported with precedence `endpoint > host > global`. |
| FR-3 | Runtime fairness scheduler tuning | Public API updates queue fairness weights without recreating `NetworkClient`. |
| FR-4 | Runtime breaker tuning | Runtime updates support breaker threshold/cooldown/probe policy. |

### Data/Analytics (DR/AR)
| ID | Requirement | Acceptance criteria |
|---|---|---|
| DR-1 | Deterministic runtime update payload | Policy update telemetry includes stable `source`, `scope`, sorted `changedFields`, deterministic `effectiveValues`. |
| AR-1 | No false success in negative paths | Existing retry/offline/circuit telemetry contracts preserved; no success events on terminal failure. |

### Non-functional (NFR)
| ID | Requirement | Acceptance criteria |
|---|---|---|
| NFR-1 | Stress/soak reproducibility | Stress scenarios include retry storm, circuit flapping, mixed priorities under pressure, cancellation burst with reproducible outcomes. |
| NFR-2 | Benchmark guardrails | Baselines gate latency, allocation delta, and regression indicators. |
| NFR-3 | Deterministic time/concurrency tests | New tests avoid unbounded waits and validate concurrency-sensitive logic deterministically. |

### Edge cases (EC)
| ID | Scenario | Expected behavior |
|---|---|---|
| EC-1 | TTL = 0 | Coalescing sharing disabled for default/custom key modes. |
| EC-2 | Endpoint overrides host/global | Endpoint policy is authoritative for matching path prefix. |
| EC-3 | Half-open probe burst | Probe policy limits concurrent probes in half-open state. |

## 5. State/Flow Mapping
| State | Runtime policy source | Action | Analytics |
|---|---|---|---|
| `policy_update_requested` | runtime update API | apply store update and emit event | `onPolicyUpdated` with source/scope/effective values |
| `coalescing_key_resolved` | endpoint/host/global | build key with TTL bucket or disable-sharing key | request/retry telemetry unchanged, policy scope preserved |
| `breaker_half_open` | runtime breaker policy | allow probes per probe policy | existing circuit transition telemetry |
| `queue_pressure` | fairness scheduler runtime policy | weighted dequeue order applied | queue metrics and policy update telemetry |

## 6. Risks and Mitigations
| Risk | Mitigation |
|---|---|
| Runtime tuning complexity | Limit exposed knobs to validated set; clamp invalid values. |
| Telemetry cardinality growth | Stable schema with bounded field set and sorted values. |
| Stress-test flakiness | Deterministic deadlines, fixed parameters, baseline gates. |

## 7. Test Matrix
| Requirement ID | Test ID | Type | Owner | Status |
|---|---|---|---|---|
| FR-1, FR-2, EC-1, EC-2 | `T-1.12-COALESCING-SCOPE` (`runtimeCoalescingTTLResolvesByEndpointHostGlobalPriority`) | integration | SDK | implemented |
| FR-3 | `T-1.12-FAIRNESS-RUNTIME` (`runtimeFairnessPolicyCanFavorLowPriorityWhenConfigured`) | unit | SDK | implemented |
| FR-4, EC-3 | `T-1.12-BREAKER-PROBE` (`circuitBreakerParallelProbePolicyAllowsConfiguredHalfOpenProbes`) | unit | SDK | implemented |
| DR-1, AR-1 | `T-1.12-TELEMETRY-RUNTIME` (`telemetryPolicyUpdateIncludesSourceScopeAndDeterministicEffectiveValues`) | integration | SDK | implemented |
| NFR-1, NFR-2 | `B-1.12-STRESS` (`--stress-suite`, `--check-stress-baseline`) | benchmark/stress | SDK | implemented |
| NFR-3 | Existing deterministic retry/time tests + new runtime policy tests | unit/integration | SDK | implemented |

### Negative tests
- Terminal failures still do not emit false success telemetry.
- `coalescingPolicy.dedupeTTLSeconds = 0` disables sharing.
- Half-open probe count never exceeds configured `parallelProbes(maxConcurrent:)`.

### Regression risks
- Runtime policy schema drift.
- Queue fairness starvation if weights misconfigured.
- Circuit breaker open/half-open transitions under concurrent probes.

## 8. Release Notes Input
### Customer impact
Runtime controls for coalescing and breaker/fairness tuning are now configurable live with deterministic telemetry contracts.

### User-facing changes
- Coalescing TTL scope controls.
- Runtime fairness scheduler update API.
- Runtime breaker probe policy tuning.
- Expanded stress guardrails.

### Behavior changes / migration notes
- Coverage policy gate is now consistently documented as `>= 90%`.
- Runtime policy telemetry payloads now include `source` and `effectiveValues`.

### Known limitations
- Runtime fairness tuning is client-wide (not host/endpoint-scoped).
