### v1.3 Scope (Implemented)

This document tracks the implemented scope for `RequestCoalescer` `v1.3`.

## Must

- [x] `NetworkClient` middleware/interceptor pipeline (`beforeSend`/`afterResponse`).
- [x] Disk cache capacity controls in `DiskResponseCache` (`maxBytes`, LRU eviction).
- [x] HTTP caching directives support (`Cache-Control`, `Expires`, `Vary`) alongside `ETag` revalidation.
- [x] Benchmark regression check via `--check-baseline` and `Benchmarks/baseline.json`.

## Should

- [x] In-flight introspection APIs for diagnostics (`inFlightRequests()`).
- [x] Adaptive retry behavior (`Retry-After`, capped delay, retry budget).
- [x] Telemetry hooks for trace/metric adapters (`NetworkTelemetryHooks`).
- [x] Test utilities target (`RequestCoalescerTestSupport`).

## Could

- [x] Per-key rate limiting (`RateLimitPolicy`).
- [x] Streaming response API (`loadStream`) with fallback behavior.
- [x] Idempotency helpers (`IdempotencyPolicy`, `withIdempotencyKey`).
- [x] Typed error-mapping ergonomics (`errorMapper` overloads).

---

### Draft: What’s New in v1.3

- Added middleware pipeline in `NetworkClient` for request/response interception.
- Added bounded `DiskResponseCache` with capacity limits and predictable eviction behavior.
- Expanded HTTP cache semantics with `Cache-Control`/`Expires` handling on top of `ETag` revalidation.
- Added adaptive retry controls including `Retry-After` handling and retry budget limits.
- Added in-flight diagnostics APIs for runtime visibility into active coalesced keys and waiters.
- Added OpenTelemetry-ready observability hooks for tracing and metrics integrations.
- Added test utility helpers to simplify deterministic integration and unit tests for consumers.
- Added benchmark baseline checks to make latency/allocation regressions easier to catch.
