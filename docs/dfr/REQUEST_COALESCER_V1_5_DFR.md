# DFR: RequestCoalescer v1.5

## 1. Metadata
- Feature name: RequestCoalescer v1.5 Timeout Budget and Circuit Control
- Owner: Networking team
- Stakeholders: Product, iOS/macOS client engineering, QA, Observability
- Status: `Draft`
- Target version/build: `v1.5`
- Related links:
  - Design: N/A (library/API feature)
  - API contract: `Sources/NovaNetworkClient/Networking/*`, `Sources/NovaNetworkClient/Core/*`
  - Experiment: N/A
  - Legal/compliance: N/A

## 2. Goal and Scope
### Goal
Reduce wasted request work and failure amplification under degraded upstream conditions by enforcing request deadlines, adding endpoint-aware circuit protection, and improving retry/coalescing controls.

### Non-goals
- Introduce distributed circuit state shared across processes/devices.
- Add adaptive ML-based retry tuning in this release.
- Change default public APIs in a source-breaking way.

### Definition of Done
- [ ] DFR updated and approved
- [ ] Code implemented
- [ ] Tests added/updated per matrix
- [ ] Telemetry implemented and verified
- [ ] "What's New" added/updated
- [ ] Rollout plan documented

### MVP / V1 / Nice-to-have
- MVP:
  - Per-request deadline budget enforced across all attempts.
  - Retry policy v2.1 with bounded exponential backoff and jitter strategy controls.
  - Per-request coalescing policy (`default`, `custom key`, `disabled`).
  - Telemetry additions for timeout and retry exhaustion reasons.
- V1:
  - Circuit breaker by host/endpoint (`closed`, `open`, `half_open`) with configurable thresholds.
  - Fast-fail behavior while breaker is open.
  - Breaker state transition telemetry.
- Nice-to-have:
  - Adaptive retry profile by failure category/network conditions.

## 3. User Value
### User problem
When upstream services are unstable, clients often spend too long retrying requests that are unlikely to recover quickly. This creates poor tail latency, wasted network usage, and noisy failures for app features that need predictable response windows.

Library consumers also need explicit control over coalescing behavior per request and clearer event data to distinguish timeout, retry exhaustion, breaker rejection, and transport failures.

### Success metrics
| Metric | Baseline | Target | Measurement method |
|---|---:|---:|---|
| Requests exceeding caller-defined SLA windows | Existing v1.4 baseline | -35% | Integration tests + telemetry (`failure_reason=timeout_budget_exhausted`) |
| Retry attempts on requests already outside budget | Existing v1.4 baseline | -80% | Retry telemetry counters and contract tests |
| Error amplification during upstream incident windows | Existing v1.4 baseline | -25% | Breaker open/close telemetry and incident replay tests |
| Time to identify root failure category | Ad-hoc | < 10 min in staging | Observability runbook validation |

## 4. Rollout, Dependencies, Risks
### Rollout plan
- Feature flag: `requestCoalescer.v1_5`
- Initial rollout percentage: 10% (internal apps and canary SDK consumers)
- Segments: internal, canary, production cohorts
- Ramp plan: 10% -> 25% -> 50% -> 100% after 48h stability windows
- Rollback trigger: >5% increase in terminal failure rate or >5% p95 latency regression vs v1.4

### Dependencies
- Internal:
  - `NetworkClient`, `RequestCoalescer`, `RetryPolicy`, `NetworkClientEvent`.
  - Existing telemetry adapters (`NetworkTelemetryHooks`).
- External:
  - Upstream APIs with stable host identity and predictable error semantics.

### Risks and mitigations
| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Deadline budget too aggressive for slow-but-valid endpoints | High | Medium | Per-request budget overrides and safe defaults |
| Breaker thresholds misconfigured causing false opens | High | Medium | Conservative defaults, staged rollout, transition telemetry |
| Custom coalescing key misuse causes under-coalescing/over-coalescing | Medium | Medium | Validation, docs, and targeted tests for key behavior |
| Telemetry cardinality growth from failure reasons/keys | Medium | Low | Enumerated reason taxonomy and bounded payload fields |

## 5. Requirements
Use stable IDs and explicit acceptance criteria.

### Functional requirements (FR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | Enforce deadline budget across request lifecycle | If remaining budget <= 0 before attempt start, request fails immediately with timeout budget error and no new attempt starts | `NetworkClient`, tests T-FR-1.* |
| FR-2 | Retry policy must respect remaining budget | Retry delay/attempt is skipped when remaining deadline budget cannot accommodate next attempt start | `RetryPolicy`, tests T-FR-2.* |
| FR-3 | Provide configurable jitter strategy for backoff | Backoff supports default jitter with bounded min/max delay and deterministic behavior in tests via injectable RNG | `RetryPolicy`, tests T-FR-3.* |
| FR-4 | Support per-request coalescing policy overrides | Caller can use default coalescing, provide custom fingerprint key, or disable coalescing for that request | `RequestExecutionOptions`, `RequestCoalescer`, tests T-FR-4.* |
| FR-5 | Circuit breaker fast-fail when open | Requests targeting open circuit fail without upstream call and return explicit breaker-open error | `NetworkClient`, breaker component, tests T-FR-5.* |
| FR-6 | Circuit breaker state transitions are deterministic | Breaker transitions `closed -> open -> half_open -> closed` follow configured thresholds and probe success/failure rules | breaker component, tests T-FR-6.* |
| FR-7 | Coalesced cancellation preserves active subscribers | Cancelling one waiter does not terminate shared execution while other waiters remain active | `RequestCoalescer`, tests T-FR-7.* |

### UX requirements (UR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Default call sites remain source-compatible | Existing v1.4 integrations compile without mandatory migration | Compile compatibility tests T-UR-1.1 |
| UR-2 | New controls are documented with examples | README/doc comments include deadline budget, coalescing override, and breaker behavior examples | Docs tests T-UR-2.1 |

### Data requirements (DR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Failure payload contains normalized failure reason | Terminal failure telemetry includes enum reason (`timeout_budget_exhausted`, `retry_exhausted`, `circuit_open`, `transport_error`, `cancelled`) | Telemetry schema tests T-DR-1.* |
| DR-2 | Breaker events include stable dimensions | Breaker telemetry includes `circuit_key`, `from_state`, `to_state`, `failure_window_count`, `open_duration_ms` | Telemetry schema tests T-DR-2.* |
| DR-3 | Coalescing mode is captured in request lifecycle events | Lifecycle payload includes `coalescing_mode` (`default`, `custom`, `disabled`) | Telemetry schema tests T-DR-3.* |

### Analytics requirements (AR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | Emit `request_failed` with reason and attempt metadata | Event contains `failure_reason`, `attempt_count`, and `remaining_budget_ms` at terminal failure | T-AR-1.1 |
| AR-2 | Emit breaker state transition events | `circuit_opened`, `circuit_half_opened`, `circuit_closed` fire exactly once per transition | T-AR-2.1 |
| AR-3 | Do not emit success on timeout/retry exhaustion/breaker-open failure | `request_succeeded` is absent for all terminal non-success outcomes | T-AR-3.1 |
| AR-4 | Emit retry exhaustion event | `request_retry_exhausted` is emitted once when retries are exhausted before terminal failure return | T-AR-4.1 |

### Non-functional requirements (NFR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | Maintain unit test coverage > 90% | Coverage report remains above 90% after merge | CI + local coverage gate |
| NFR-2 | Deadline/breaker checks add bounded overhead | p95 latency regression <= 5% relative to v1.4 in benchmark harness | Benchmarks T-NFR-2.1 |
| NFR-3 | Thread-safe behavior under concurrency | No races/crashes in stress tests with concurrent coalesced and non-coalesced traffic | Concurrency tests T-NFR-3.* |

### Edge cases (EC)
| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Single coalesced waiter cancels while others continue | Only cancelled waiter receives cancellation; shared upstream task continues | T-EC-1.1 |
| EC-2 | Deadline budget expires during backoff wait | Pending retry is aborted and request fails as timeout budget exhausted | T-EC-2.1 |
| EC-3 | Breaker probe in half-open fails | Circuit re-opens immediately and subsequent requests fast-fail until next probe window | T-EC-3.1 |
| EC-4 | Coalescing disabled on identical concurrent requests | Requests execute independently without joining the same in-flight entry | T-EC-4.1 |
| EC-5 | Telemetry hook throws during breaker transition | Request flow is unaffected; telemetry failure is isolated | T-EC-5.1 |

## 6. State Machine and Flows
### States
- `queued`
- `coalesced_waiting`
- `executing`
- `retry_backoff`
- `breaker_open_rejected`
- `timed_out`
- `succeeded`
- `failed`
- `cancelled`

### Transitions
| From | Trigger | To | Notes |
|---|---|---|---|
| `queued` | matching in-flight key found and coalescing enabled | `coalesced_waiting` | joins existing execution |
| `queued` | circuit is open for target key | `breaker_open_rejected` | fast-fail without upstream call |
| `queued` | scheduler dispatch with budget remaining | `executing` | attempt starts |
| `queued` | no budget remaining before first attempt | `timed_out` | immediate timeout budget failure |
| `coalesced_waiting` | upstream success | `succeeded` | all active waiters resolved |
| `executing` | retry-eligible failure and budget allows retry | `retry_backoff` | compute bounded jitter delay |
| `retry_backoff` | delay elapsed with budget remaining | `executing` | next attempt starts |
| `retry_backoff` | budget exhausted before delay completion | `timed_out` | stop retry loop |
| `executing` | terminal success | `succeeded` | success event emitted |
| `executing` | terminal failure (non-timeout) | `failed` | failure event emitted |
| `executing` | caller/group cancellation | `cancelled` | cancellation reason recorded |
| `breaker_open_rejected` | immediate completion | `failed` | failure reason `circuit_open` |
| `timed_out` | immediate completion | `failed` | failure reason `timeout_budget_exhausted` |

### State to UI/Actions/Analytics mapping
| State | UI | Allowed actions | Analytics |
|---|---|---|---|
| `queued` | N/A (library) | cancel/request option overrides | `request_queued` |
| `coalesced_waiting` | N/A | cancel waiter | `request_coalesced_joined` |
| `executing` | N/A | cancel waiter / observe | `request_started`, `request_attempt_started` |
| `retry_backoff` | N/A | cancel, await retry | `request_retry_attempted` |
| `breaker_open_rejected` | N/A | inspect error, retry later | `circuit_opened` (if transition), `request_failed` |
| `timed_out` | N/A | inspect error | `request_failed` |
| `succeeded` | N/A | read response | `request_succeeded` |
| `failed` | N/A | inspect failure reason | `request_failed`, `request_retry_exhausted` (if applicable) |
| `cancelled` | N/A | inspect cancellation reason | `request_cancelled` |

## 7. Engineering Notes
- Deadline budget should use a monotonic clock source to avoid wall-clock skew issues.
- Breaker key granularity defaults to host; endpoint-level keying is optional for finer isolation.
- Breaker configuration should support safe defaults and explicit tuning (`failureThreshold`, `openInterval`, `halfOpenProbeCount`).
- Retry jitter strategy must remain testable with injectable deterministic random source.
- Telemetry dispatch remains non-blocking and isolated from core request completion.

## 8. Test Matrix
| Requirement ID | Test ID | Test type (`unit/integration/ui`) | Owner | Status |
|---|---|---|---|---|
| FR-1 | T-FR-1.1 Deadline exhausted before first attempt | unit | Networking | planned |
| FR-1 | T-FR-1.2 Deadline exhaustion after partial attempts | integration | Networking | planned |
| FR-2 | T-FR-2.1 Retry skipped when budget insufficient | unit | Networking | planned |
| FR-3 | T-FR-3.1 Backoff jitter bounds and determinism | unit | Networking | planned |
| FR-4 | T-FR-4.1 Custom coalescing key joins expected requests | integration | Networking | planned |
| FR-4 | T-FR-4.2 Disabled coalescing executes independently | integration | Networking | planned |
| FR-5 | T-FR-5.1 Open breaker fast-fail without upstream call | integration | Networking | planned |
| FR-6 | T-FR-6.1 Breaker state transition contract | integration | Networking | planned |
| FR-7 | T-FR-7.1 Single waiter cancel preserves shared execution | integration | Networking | planned |
| UR-1 | T-UR-1.1 Source compatibility compile test | unit | Networking | planned |
| UR-2 | T-UR-2.1 Documentation snippets compile/verify | unit | Networking | planned |
| DR-1 | T-DR-1.1 Failure reason schema validation | integration | Observability | planned |
| DR-2 | T-DR-2.1 Breaker payload field/type validation | integration | Observability | planned |
| DR-3 | T-DR-3.1 Coalescing mode payload validation | integration | Observability | planned |
| AR-1 | T-AR-1.1 Failure event contains reason/attempt/budget | integration | Observability | planned |
| AR-2 | T-AR-2.1 Breaker transition event cardinality | integration | Observability | planned |
| AR-3 | T-AR-3.1 No success event on non-success terminal paths | integration | Observability | planned |
| AR-4 | T-AR-4.1 Retry exhaustion emits once | integration | Observability | planned |
| NFR-1 | T-NFR-1.1 Coverage gate > 90% | unit | QA | planned |
| NFR-2 | T-NFR-2.1 p95 overhead benchmark | integration | Networking | planned |
| NFR-3 | T-NFR-3.1 Concurrency stress and race safety | integration | Networking | planned |
| EC-1 | T-EC-1.1 Cancel one coalesced waiter | integration | Networking | planned |
| EC-2 | T-EC-2.1 Budget expires in retry backoff | integration | Networking | planned |
| EC-3 | T-EC-3.1 Half-open probe failure re-opens breaker | integration | Networking | planned |
| EC-4 | T-EC-4.1 Disabled coalescing for identical requests | integration | Networking | planned |
| EC-5 | T-EC-5.1 Telemetry failure isolation on transitions | integration | Networking | planned |

### Negative tests
- T-FR-2.1: verify no retry attempt starts when deadline budget cannot cover next attempt.
- T-AR-3.1: verify `request_succeeded` is never emitted for timeout, breaker-open, cancellation, or retry exhaustion outcomes.
- T-EC-5.1: verify telemetry callback errors do not alter request completion result.

### Regression risks
- Retry behavior regressions from budget checks affecting legacy defaults; mitigated by T-UR-1.1 and T-FR-1.*.
- False-positive circuit opens under transient spikes; mitigated by T-FR-6.1 and staged rollout.
- Coalescing behavior drift with per-request overrides; mitigated by T-FR-4.* and T-EC-4.1.

## 9. Release Notes Input ("What's New")
### Customer impact
- More predictable request completion windows and safer behavior during upstream incidents.

### User-facing changes
- Added deadline budget enforcement across request/retry lifecycle.
- Added configurable retry jitter controls and budget-aware retry stop behavior.
- Added per-request coalescing policy override (default/custom/disabled).
- Added circuit breaker states and fast-fail protection for unhealthy targets.
- Expanded telemetry for failure reasons, retry exhaustion, and breaker transitions.

### Behavior changes / migration notes
- Defaults remain source-compatible with v1.4; new controls are additive.
- Consumers can opt in to stricter budgets and breaker thresholds per client/request.

### Known limitations
- Circuit state is process-local and not shared across app/process boundaries.
- Adaptive retry remains out of scope for this release.
