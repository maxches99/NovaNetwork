## What's New in v1.12

### Platform Hardening

#### Coalescing controls
- Added runtime coalescing dedupe TTL windows via `NetworkClientRuntimePolicy.coalescingPolicy`.
- Added scoped coalescing policy resolution across `global`, `host`, and `endpoint` with explicit priority: `endpoint > host > global`.
- Added tests validating TTL disable mode and scope-precedence behavior.

#### Runtime tuning hooks
- Added runtime fairness scheduler tuning API:
  - `updateCoalescerSchedulerPolicy(_:)`
- Added runtime circuit-breaker tuning wrapper:
  - `updateCircuitBreakerRuntimePolicy(_:scope:)`
- Added circuit-breaker probe policy support:
  - `CircuitBreakerProbePolicy.singleProbe`
  - `CircuitBreakerProbePolicy.parallelProbes(maxConcurrent:)`
- Runtime policy update telemetry now emits deterministic payloads with:
  - `source`
  - `scope`
  - sorted `changedFields`
  - deterministic `effectiveValues`

#### Reliability and load hardening
- Expanded stress suite coverage to include:
  - retry storm
  - circuit flapping
  - mixed priorities under queue pressure
  - cancellation burst
- Added benchmark/stress guardrails for latency and regression checks.

#### Governance and consistency
- Synchronized unit-test coverage documentation to a consistent `>= 90%` gate.
- Updated PR template with additional QA sign-off fields and explicit test-matrix traceability rows.
- Added DFR and v1.12 test-matrix traceability: `docs/dfr/REQUEST_COALESCER_V1_12_DFR.md`.

### Compatibility notes
- Existing runtime policy APIs remain supported.
- Telemetry policy update payloads now include additional fields (`source`, `effectiveValues`).
