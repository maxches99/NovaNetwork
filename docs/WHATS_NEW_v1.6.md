### v1.6 Scope (Implemented / In Progress)

This document tracks the planned scope for `RequestCoalescer` `v1.6`.

## Must

- [x] Adaptive retry profiles by normalized failure category.
- [x] Server-driven backoff via `Retry-After` with bounded delay and budget checks.
- [x] Runtime policy update API for retry/deadline/breaker without recreating `NetworkClient`.

## Should

- [x] Per-endpoint policy registry with deterministic precedence (`endpoint` > `host` > `global`).
- [x] Circuit breaker half-open probe jitter to reduce synchronized retry/probe bursts.

## Could

- [x] Coalescing protection limits (`max waiters`) with configurable overflow behavior (`bypass` / `fail`).
- [x] Extended telemetry fields: `retry_schedule_source`, `retry_profile`, `policy_scope`, `request_retry_skipped`, `request_policy_updated`.
- [x] Deterministic stress benchmark suite for retry storms, breaker flapping, and runtime policy updates.

---

### Draft: What's New in v1.6

- Added adaptive retry behavior that selects profile by failure category.
- Added support for server-guided retry delays (`Retry-After`) with safety bounds.
- Added runtime policy tuning so retry/deadline/breaker settings can be updated on a live client.
- Added endpoint-scoped policy overrides for finer control across upstream routes.
- Improved resilience during incidents with jittered breaker probe windows.
- Expanded observability with retry schedule source, selected profile, scope, and skip-reason telemetry.
