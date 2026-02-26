# RequestCoalescer v1.5 Implementation Task Decomposition

## Metadata
- DFR: `docs/dfr/REQUEST_COALESCER_V1_5_DFR.md`
- Target version: `v1.5`
- Scope type: DFR-derived engineering, test, telemetry, and release tasks

## 1) Domain/Core Tasks

1. `TASK-DOM-1` Deadline budget model and clock abstraction  
Requirements: `FR-1`, `FR-2`, `NFR-3`, `EC-2`  
Deliverables:
- Introduce deadline budget value object with monotonic time support.
- Add remaining-budget calculations reusable by execution and retry paths.
- Add deterministic test clock support.

2. `TASK-DOM-2` Circuit breaker state machine  
Requirements: `FR-5`, `FR-6`, `EC-3`, `NFR-3`  
Deliverables:
- Implement state machine (`closed/open/half_open`) with threshold config.
- Implement probe gating rules and transition bookkeeping.
- Expose deterministic state transition API for tests.

3. `TASK-DOM-3` Coalescing policy model  
Requirements: `FR-4`, `EC-4`, `DR-3`  
Deliverables:
- Add coalescing mode enum (`default/custom/disabled`) and validation rules.
- Define custom fingerprint integration contract.

## 2) Networking/Execution Tasks

1. `TASK-NET-1` Deadline-aware request execution  
Requirements: `FR-1`, `FR-2`, `EC-2`  
Deliverables:
- Check budget before first and subsequent attempts.
- Return terminal timeout-budget error when exhausted.
- Prevent starting new attempts with non-positive remaining budget.

2. `TASK-NET-2` Retry policy v2.1 jitter and budget integration  
Requirements: `FR-2`, `FR-3`, `NFR-2`  
Deliverables:
- Add jitter strategy controls with bounded min/max delay.
- Inject random source for deterministic tests.
- Skip retry delay/attempt when budget is insufficient.

3. `TASK-NET-3` Coalescer execution override wiring  
Requirements: `FR-4`, `FR-7`, `EC-1`, `EC-4`  
Deliverables:
- Route request through coalescer by selected mode.
- Preserve subscriber-aware cancellation semantics for shared tasks.
- Ensure disabled mode executes isolated request tasks.

4. `TASK-NET-4` Circuit breaker fast-fail in client pipeline  
Requirements: `FR-5`, `FR-6`, `EC-3`  
Deliverables:
- Gate upstream attempt by breaker state per circuit key.
- Return explicit breaker-open error for rejected requests.
- Feed attempt outcomes back into breaker for transitions.

## 3) Telemetry/Analytics Tasks

1. `TASK-OBS-1` Failure reason taxonomy and payload contract  
Requirements: `DR-1`, `AR-1`, `AR-3`  
Deliverables:
- Add normalized `failure_reason` enum in terminal failure events.
- Include `attempt_count` and `remaining_budget_ms`.
- Guarantee no success event on non-success terminal paths.

2. `TASK-OBS-2` Breaker transition events  
Requirements: `DR-2`, `AR-2`, `EC-5`  
Deliverables:
- Emit `circuit_opened`, `circuit_half_opened`, `circuit_closed`.
- Include stable transition payload fields.
- Isolate telemetry failures from request completion path.

3. `TASK-OBS-3` Retry exhaustion and coalescing mode analytics  
Requirements: `AR-4`, `DR-3`  
Deliverables:
- Emit `request_retry_exhausted` exactly once on exhaustion path.
- Include coalescing mode in lifecycle payloads.

## 4) Documentation/API Tasks

1. `TASK-DOC-1` Public API docs and README updates  
Requirements: `UR-2`  
Deliverables:
- Add examples for deadline budget usage.
- Add coalescing mode override examples.
- Document breaker behavior and safe default guidance.

2. `TASK-DOC-2` Release notes alignment  
Requirements: DoD release requirement + DFR section 9  
Deliverables:
- Keep `docs/WHATS_NEW_v1.5.md` aligned with implemented scope.
- Mark shipped items as implemented and carry over deferred scope.

## 5) Test Tasks (DFR Traceability)

1. `TASK-TEST-1` Functional tests  
Requirements: `FR-1`..`FR-7`, `EC-1`..`EC-4`  
Test IDs:
- `T-FR-1.1`, `T-FR-1.2`, `T-FR-2.1`, `T-FR-3.1`, `T-FR-4.1`, `T-FR-4.2`, `T-FR-5.1`, `T-FR-6.1`, `T-FR-7.1`
- `T-EC-1.1`, `T-EC-2.1`, `T-EC-3.1`, `T-EC-4.1`

2. `TASK-TEST-2` Analytics/data contract tests  
Requirements: `DR-1`, `DR-2`, `DR-3`, `AR-1`..`AR-4`, `EC-5`  
Test IDs:
- `T-DR-1.1`, `T-DR-2.1`, `T-DR-3.1`, `T-AR-1.1`, `T-AR-2.1`, `T-AR-3.1`, `T-AR-4.1`, `T-EC-5.1`

3. `TASK-TEST-3` Compatibility and non-functional tests  
Requirements: `UR-1`, `NFR-1`, `NFR-2`, `NFR-3`  
Test IDs:
- `T-UR-1.1`, `T-NFR-1.1`, `T-NFR-2.1`, `T-NFR-3.1`

## 6) Flow-Based Implementation Sequencing

1. `FLOW-1` Happy path (single request, budget valid, success)  
Tasks: `TASK-DOM-1`, `TASK-NET-1`, `TASK-OBS-1`

2. `FLOW-2` Retry path with bounded jitter and eventual success/failure  
Tasks: `TASK-NET-2`, `TASK-OBS-3`

3. `FLOW-3` Coalesced path with per-request override and cancellation semantics  
Tasks: `TASK-DOM-3`, `TASK-NET-3`

4. `FLOW-4` Circuit-protected path with fast-fail and recovery probe  
Tasks: `TASK-DOM-2`, `TASK-NET-4`, `TASK-OBS-2`

5. `FLOW-5` Regression/performance hardening and release readiness  
Tasks: `TASK-TEST-1`, `TASK-TEST-2`, `TASK-TEST-3`, `TASK-DOC-1`, `TASK-DOC-2`

## 7) Release Tasks

1. Enable feature flag `requestCoalescer.v1_5` for internal canary.
2. Validate telemetry dashboards for failure reasons and breaker transitions.
3. Execute rollout increments: `10% -> 25% -> 50% -> 100%` after stability windows.
4. Apply rollback trigger if terminal error rate increases by >5% or p95 latency regresses by >5%.
