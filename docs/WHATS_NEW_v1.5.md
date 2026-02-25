### v1.5 Scope (Implemented / In Progress)

This document tracks the planned scope for `RequestCoalescer` `v1.5`.

## Must

- [x] Deadline budget enforcement across full request + retry lifecycle.
- [x] Budget-aware retry behavior that skips attempts when remaining budget is insufficient.
- [x] Per-request coalescing mode override (`default` / `custom` / `disabled`).
- [x] Telemetry contract updates for terminal failure reasons and retry exhaustion.

## Should

- [x] Circuit breaker by host/endpoint with `closed/open/half_open` states.
- [x] Fast-fail behavior for requests while circuit is open.
- [x] Deterministic breaker transition telemetry payload (`circuit_key`, state transition, counters, open duration).
- [x] Documentation updates with deadline/coalescing/breaker examples.

## Could

- [ ] Adaptive retry profile by failure category/network condition.
- [ ] Runtime tuning hooks for breaker thresholds.

---

### Draft: What's New in v1.5

- Added request deadline budget support so operations stop retrying when caller time budget is exhausted.
- Added budget-aware retry behavior with bounded backoff and jitter controls.
- Added per-request coalescing policy override with default/custom/disabled modes.
- Added circuit breaker protection with fast-fail behavior for unhealthy targets.
- Expanded telemetry to include normalized failure reasons, retry exhaustion, and breaker state transitions.
- Improved diagnostics for incident triage by separating timeout, breaker-open, retry-exhausted, and transport failures.
