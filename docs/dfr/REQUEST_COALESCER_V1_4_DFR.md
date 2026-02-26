# DFR: RequestCoalescer v1.4

## 1. Metadata
- Feature name: RequestCoalescer v1.4 Reliability and Load Control
- Owner: Networking team
- Stakeholders: Product, iOS/macOS client engineering, QA, Observability
- Status: `Draft`
- Target version/build: `v1.4`
- Related links:
  - Design: N/A (library/API feature)
  - API contract: `Sources/NovaNetworkClient/Networking/*`, `Sources/NovaNetworkClient/Core/*`
  - Experiment: N/A
  - Legal/compliance: N/A

## 2. Goal and Scope
### Goal
Improve request stability under partial outages and traffic bursts while preserving deterministic behavior for coalesced callers and offering stronger telemetry for troubleshooting.

### Non-goals
- Introduce breaking API redesign for existing public interfaces.
- Add persistent distributed coordination across processes/devices.
- Add new third-party dependencies.

### Definition of Done
- [ ] DFR updated and approved
- [ ] Code implemented
- [ ] Tests added/updated per matrix
- [ ] Telemetry implemented and verified
- [ ] "What's New" added/updated
- [ ] Rollout plan documented

### MVP / V1 / Nice-to-have
- MVP:
  - Priority-aware in-memory scheduling for coalesced and non-coalesced requests.
  - Retry policy v2 (bounded exponential backoff with jitter + idempotency-aware retries).
  - Cancellation semantics for multi-subscriber coalesced requests.
  - Telemetry hooks for queueing/retry/coalescing outcomes.
- V1:
  - Circuit breaker integration with client execution path.
  - Coalescing window TTL and scope controls (fingerprint policy integration).
- Nice-to-have:
  - Dynamic queue tuning from runtime telemetry feedback.

## 3. User Value
### User problem
Library adopters face failure storms when upstream services degrade: retries amplify load, low-priority background requests block high-priority operations, and debugging is slow because telemetry lacks attempt and queueing context.

Consumers also need predictable cancellation behavior for coalesced calls so one caller cannot unintentionally cancel work still required by other callers.

### Success metrics
| Metric | Baseline | Target | Measurement method |
|---|---:|---:|---|
| Duplicate upstream calls for identical in-flight key | Existing v1.3 baseline | -30% | Telemetry counter (`coalesced_waiter_count`, upstream execution count) |
| P95 latency for high-priority requests under mixed load | Existing v1.3 baseline | -20% | Benchmark suite + integration tests |
| Retry storm incidents per 10k requests | Existing v1.3 baseline | -40% | Telemetry counters (`retry_attempted`, `retry_exhausted`) |
| Successful root-cause diagnosis time for failed requests | Ad-hoc | < 15 min in staging | Observability runbook validation |

## 4. Rollout, Dependencies, Risks
### Rollout plan
- Feature flag: `requestCoalescer.v1_4`
- Initial rollout percentage: 10% (internal apps only)
- Segments: internal + canary consumers
- Ramp plan: 10% -> 25% -> 50% -> 100% after 48h stability windows
- Rollback trigger: >5% increase in terminal error rate or >15% P95 latency regression

### Dependencies
- Internal:
  - `NetworkClient`, `RequestCoalescer`, `RetryPolicy`, `NetworkClientEvent`.
  - Existing telemetry adapters (`NetworkTelemetryHooks`).
- External:
  - Upstream APIs honoring idempotency and retry-safe behavior.

### Risks and mitigations
| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Priority queue starvation for low priority tasks | Medium | Medium | Fair-share scheduling and max consecutive high-priority dispatch cap |
| Incorrect cancellation propagation in coalesced group | High | Medium | Explicit subscriber ref-counting + dedicated cancellation tests |
| Telemetry cardinality explosion | Medium | Medium | Stable event schema, bounded tag values |
| Retry policy retries unsafe operations | High | Low | Idempotency gating and method/status allowlist |

## 5. Requirements
Use stable IDs and explicit acceptance criteria.

### Functional requirements (FR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | Support request priority (`high`, `normal`, `low`) in execution scheduling | Given mixed queue load, dispatcher executes high before normal/low while preserving FIFO within same priority | `NetworkClient`, `RequestExecutionOptions`, tests T-FR-1.* |
| FR-2 | Implement fairness to prevent low-priority starvation | Low-priority request executes within bounded turns under sustained high-priority traffic | Scheduler tests T-FR-2.* |
| FR-3 | Retry policy v2 with exponential backoff + jitter | Retry intervals follow configured bounds and stop after attempt limit | `RetryPolicy`, tests T-FR-3.* |
| FR-4 | Idempotency-aware retries | Non-idempotent requests are not retried unless explicit override is enabled | `IdempotencyPolicy`, tests T-FR-4.* |
| FR-5 | Coalesced cancellation uses subscriber semantics | Cancelling one waiter does not cancel upstream if other waiters remain; upstream cancels when last waiter cancels | `RequestCoalescer`, tests T-FR-5.* |
| FR-6 | Emit telemetry for queue, retry, and coalescing outcomes | Required events fire once per lifecycle stage with stable payload schema | `NetworkTelemetryHooks`, tests T-FR-6.* |

### UX requirements (UR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | API ergonomics remain source-compatible for default usage | Existing v1.3 consumer code compiles without migration changes for defaults | Compile compatibility tests T-UR-1.1 |
| UR-2 | New options are discoverable and documented | README and doc comments include priority/retry/cancellation examples | Docs tests T-UR-2.1 |

### Data requirements (DR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Event payload includes deterministic identifiers | Payload contains request fingerprint hash, attempt index, priority, and outcome enum | Telemetry contract tests T-DR-1.* |
| DR-2 | Queue metrics are aggregatable | Queue wait time and queue depth are emitted as numeric fields with consistent units (ms/count) | Telemetry schema tests T-DR-2.* |

### Analytics requirements (AR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | Emit `request_coalesced_joined` when request joins existing in-flight key | Event fires exactly once per joining waiter | T-AR-1.1 |
| AR-2 | Emit `request_retry_attempted` before each retry delay | Event count equals retry attempt count | T-AR-2.1 |
| AR-3 | Emit `request_succeeded` only on terminal success | No success event on terminal failure/cancelled | T-AR-3.1 |
| AR-4 | Emit `request_cancelled` with `reason` on terminal cancellation | Contains reason enum (`caller_cancelled`, `group_cancelled`, `timeout`) | T-AR-4.1 |

### Non-functional requirements (NFR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | Maintain unit test coverage > 90% | Coverage report remains above 90% after merge | CI + local coverage gate |
| NFR-2 | Scheduling overhead remains bounded | Additional scheduler overhead under 5% in benchmark harness | Benchmarks T-NFR-2.1 |
| NFR-3 | Thread-safety remains intact under concurrency | No data races or crashes in stress tests with high concurrency | Concurrency tests T-NFR-3.* |

### Edge cases (EC)
| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | High-priority flood with queued low-priority requests | Low-priority requests continue to make forward progress due to fairness cap | T-EC-1.1 |
| EC-2 | Last remaining waiter cancels during retry backoff | Retry timer is cancelled and upstream operation is terminated cleanly | T-EC-2.1 |
| EC-3 | Retry receives `Retry-After` beyond max bound | Delay is clamped to configured max backoff | T-EC-3.1 |
| EC-4 | Telemetry hook throws or fails | Core request flow continues; telemetry failures are isolated | T-EC-4.1 |

## 6. State Machine and Flows
### States
- `queued`
- `coalesced_waiting`
- `executing`
- `retry_backoff`
- `succeeded`
- `failed`
- `cancelled`

### Transitions
| From | Trigger | To | Notes |
|---|---|---|---|
| `queued` | matching in-flight key found | `coalesced_waiting` | caller joins existing execution |
| `queued` | scheduler dispatch | `executing` | priority + fairness policy applied |
| `coalesced_waiting` | upstream success | `succeeded` | all active waiters resolved |
| `coalesced_waiting` | caller cancellation with remaining waiters | `coalesced_waiting` | only subscriber removed |
| `executing` | retry-eligible failure | `retry_backoff` | retry policy v2 computes delay |
| `retry_backoff` | delay elapsed and still active | `executing` | next attempt |
| `executing` | terminal success | `succeeded` | telemetry success event |
| `executing` | terminal failure | `failed` | telemetry failure event |
| `executing` | terminal cancellation | `cancelled` | cancellation reason recorded |
| `retry_backoff` | last waiter cancelled | `cancelled` | pending retry cancelled |

### State to UI/Actions/Analytics mapping
| State | UI | Allowed actions | Analytics |
|---|---|---|---|
| `queued` | N/A (library) | reprioritize/cancel | `request_queued` |
| `coalesced_waiting` | N/A | cancel waiter | `request_coalesced_joined` |
| `executing` | N/A | cancel waiter / observe progress | `request_started`, `request_attempt_started` |
| `retry_backoff` | N/A | cancel, await retry | `request_retry_attempted` |
| `succeeded` | N/A | read response | `request_succeeded` |
| `failed` | N/A | inspect error | `request_failed` |
| `cancelled` | N/A | inspect cancellation reason | `request_cancelled` |

## 7. Engineering Notes
- Priority model should default to `normal` to preserve current behavior for existing callers.
- Fairness can be implemented with weighted round-robin (suggested default ratio: `high:normal:low = 4:2:1`).
- Cancellation management should use group-scoped bookkeeping to avoid leaked tasks or orphaned continuations.
- Telemetry dispatch must be non-blocking and failure-isolated.
- V1 features (circuit breaker + coalescing TTL scope controls) should be guarded by feature toggles if delivered incrementally.

## 8. Test Matrix
| Requirement ID | Test ID | Test type (`unit/integration/ui`) | Owner | Status |
|---|---|---|---|---|
| FR-1 | T-FR-1.1 Priority ordering under load | unit | Networking | passing |
| FR-1 | T-FR-1.2 FIFO within same priority | unit | Networking | passing |
| FR-2 | T-FR-2.1 Fairness forward-progress guarantee | integration | Networking | passing |
| FR-3 | T-FR-3.1 Backoff sequence and jitter bounds | unit | Networking | passing |
| FR-3 | T-FR-3.2 Retry stops at max attempts | unit | Networking | passing |
| FR-4 | T-FR-4.1 Non-idempotent request no retry by default | unit | Networking | passing |
| FR-5 | T-FR-5.1 Single waiter cancel does not cancel group | integration | Networking | passing |
| FR-5 | T-FR-5.2 Last waiter cancel terminates upstream | integration | Networking | passing |
| FR-6 | T-FR-6.1 Telemetry event lifecycle contract | integration | Networking | passing |
| UR-1 | T-UR-1.1 Source compatibility compile test | unit | Networking | passing |
| UR-2 | T-UR-2.1 Documentation snippets compile/verify | unit | Networking | passing |
| DR-1 | T-DR-1.1 Payload schema completeness | integration | Observability | passing |
| DR-2 | T-DR-2.1 Queue metric field/type validation | integration | Observability | passing |
| AR-1 | T-AR-1.1 Coalesced joined count correctness | integration | Observability | passing |
| AR-2 | T-AR-2.1 Retry event count parity | integration | Observability | passing |
| AR-3 | T-AR-3.1 No success event on failure/cancelled | integration | Observability | passing |
| AR-4 | T-AR-4.1 Cancel reason enum validation | integration | Observability | passing |
| NFR-1 | T-NFR-1.1 Coverage gate > 90% | unit | QA | passing |
| NFR-2 | T-NFR-2.1 Scheduler overhead benchmark | integration | Networking | passing |
| NFR-3 | T-NFR-3.1 Concurrency stress and race safety | integration | Networking | passing |
| EC-1 | T-EC-1.1 Low priority progress under flood | integration | Networking | passing |
| EC-2 | T-EC-2.1 Cancel during backoff | integration | Networking | passing |
| EC-3 | T-EC-3.1 Retry-After clamp | unit | Networking | passing |
| EC-4 | T-EC-4.1 Telemetry failure isolation | integration | Networking | passing |

### Negative tests
- T-FR-4.1: Ensure non-idempotent request failure does not trigger retry without explicit override.
- T-AR-3.1: Ensure no `request_succeeded` event is emitted in terminal failure and cancellation paths.
- T-EC-4.1: Validate telemetry callback failures/cancellation paths do not block or corrupt core request completion.

### Regression risks
- Request ordering regressions under high concurrency; mitigated by T-FR-1.1, T-FR-2.1, T-NFR-3.1.
- Cancellation behavior regressions for existing coalescer consumers; mitigated by T-FR-5.1, T-FR-5.2.
- Telemetry schema drift across patch releases; mitigated by T-DR-1.1, T-DR-2.1.

## 9. Release Notes Input ("What's New")
### Customer impact
- More reliable request execution under partial outages and mixed-priority traffic.

### User-facing changes
- Added priority-aware scheduling and fairness controls.
- Added retry policy v2 with idempotency-aware behavior.
- Improved cancellation semantics for coalesced requests.
- Added richer telemetry events and payload fields for diagnostics.

### Behavior changes / migration notes
- Default behavior remains source-compatible; new controls are opt-in or default-safe.

### Known limitations
- Circuit breaker and coalescing TTL scope controls are planned for V1 phase if not included in MVP cut.
