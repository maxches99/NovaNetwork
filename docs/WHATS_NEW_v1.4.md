### v1.4 Scope (Implemented)

This document tracks the implemented scope for `RequestCoalescer` `v1.4`.

## Must

- [x] Priority-aware scheduling for requests (`high` / `normal` / `low`) with fairness guarantees.
- [x] Retry policy v2 (bounded exponential backoff + jitter) with idempotency-aware retry gating.
- [x] Coalesced cancellation semantics where one waiter cancellation does not cancel active peers.
- [x] Expanded telemetry lifecycle events for queueing, retries, coalescing, success/failure/cancellation.

## Should

- [x] Deterministic telemetry payload schema (`fingerprint`, `attempt`, `priority`, `outcome`).
- [x] Queue telemetry payload schema (`queueDepth`, `waitMilliseconds`) with numeric contract.
- [x] Concurrency stress-test coverage for scheduler and cancellation behavior.
- [x] Benchmark guard for scheduler overhead regression.

## Could

- [x] Circuit breaker integration into request execution flow.
- [ ] Coalescing TTL and scope controls for deduplication windows.
- [ ] Runtime tuning hooks for queue fairness parameters.

---

### Draft: What's New in v1.4

- Added request priority controls and fair scheduling to reduce latency for critical calls.
- Added retry policy v2 with bounded backoff/jitter and safer idempotency-aware retry decisions.
- Improved coalesced cancellation behavior so one caller can unsubscribe without interrupting remaining consumers.
- Expanded telemetry hooks and payloads for coalescer lifecycle, queue metrics (`queueDepth`, `waitMilliseconds`), retries, and cancellation reasons.
- Added stronger observer/event contract validation so retry and terminal states emit consistent analytics events.
- Added deeper reliability coverage for race conditions, retry storms, cancellation edge cases, and scheduler overhead bounds.
