# What's New in 2.7

## NovaNetworkClientTestSupport: a fuller testing DSL

Grew the existing `NovaNetworkClientTestSupport` product (previously `MockTransport`,
`ScriptedTransport`, `TestRetryClock`, `TestRetryRandom`) into a fuller testing toolkit for code
that uses `NovaNetworkClient`. All additions are new types alongside the existing ones; nothing
was removed or changed.

- Added `RequestMatcher`, a composable predicate over `APIRequest` (`.method`, `.path`,
  `.pathPrefix`, `.host`, `.header`, `.bodyContains`, `.url`, `.any`, combined with `&&`/`||`).
- Added `RoutingTransport`, a mock transport dispatching each request to the first registered
  route whose matcher matches (fixed response or a closure computing one from the request, with
  an optional use-count limit before falling through to the next route). A request matching no
  route throws `RoutingTransportError`, naming the unmatched method and URL, instead of hanging
  or returning a misleading default.
- Added `ChaosTransport` and `ChaosPolicy`, wrapping any transport with configurable randomized
  failures and latency, for exercising retry, circuit breaker, and offline queue code paths.
  Deterministic with a seeded `RetryRandomGenerator` such as the existing `TestRetryRandom`.
- Added `VirtualClock`, a `RetryClock` that genuinely suspends callers of `sleep(nanoseconds:)`
  until virtual time is explicitly advanced (`advance(by:)`, `advanceToNextDeadline()`), so tests
  can assert on state *between* two scheduled events instead of only "did it eventually happen."
  Unlike `TestRetryClock`, which never blocks, this preserves real suspend/resume ordering across
  multiple concurrent sleeps and responds correctly to task cancellation.
- Added `TelemetryRecorder`, which builds a `NetworkTelemetryHooks` recording every one of its 15
  event types, with typed accessors instead of hand-rolling a recorder per test file. Added
  `waitUntil(timeoutNanoseconds:_:)`, a short-poll helper for asserting on telemetry that is
  recorded asynchronously relative to the operation that triggered it.
- Added a new `NovaNetworkClientTestSupportTests` test target exercising this module as a real
  external dependency, alongside the package's existing test targets.

## Migration notes

- Additive only; no existing public API changed.
