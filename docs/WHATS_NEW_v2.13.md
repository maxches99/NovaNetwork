# What's New in 2.13

## Diagnostics you can see

The client has always reported everything worth knowing through its telemetry hooks and event
stream. What was missing is somewhere for it to land.

```swift
import NovaNetworkDiagnostics

let recorder = DiagnosticsRecorder()
var configuration = NetworkClientConfiguration()
configuration.telemetryHooks = recorder.hooks
let client = NetworkClient(configuration: configuration)
recorder.startConsuming(client.events())
```

That is the whole installation. Diagnostics is a *consumer* of the existing contract — no telemetry
surface changed shape, and the client behaves identically with or without a recorder attached.

### One record per request, not per attempt

The client reports a start and an end for every attempt, and announces a retry only after the failed
attempt has already ended. Recording that literally would turn one flaky request into three
unrelated rows. Attempt numbers tie the pieces back together, so what you see is the request a
person actually made:

```
GET /flaky — 200 in 598 ms
  █████████████ Attempt 1
  ············ Backoff 185 ms
               ██████████████████████████ Attempt 2
               ·························· Backoff 399 ms
                                         █ Attempt 3
```

`durationMilliseconds` is total elapsed time, backoff included, because that is the wait someone
actually experienced. A record also carries the status or error, whether the request was coalesced,
how the cache answered, redacted headers, and body sizes.

### Failure means failure

A transport that returns a 500 as a response has *completed* the exchange — nothing threw. The
outcome case is therefore `completed(status:)`, and `isFailure` decides whether the status was bad
news: anything from 400 up, a transport error, or a cancellation. `DiagnosticsSummary.failureRate`
counts HTTP errors, because a summary reading "0% failed" beside a list of 500s would be worse than
no summary at all.

The cache-hit rate is measured only against requests where a cache outcome was observed, so a client
with caching switched off reports nothing rather than a misleading zero.

### Bounded by construction

An unbounded diagnostics buffer is a leak in any app that runs for a while. Capacity is a
construction parameter — 200 records by default, oldest dropped first — and body capture is capped at
64 KB with a flag on anything truncated. Credentials are removed as a record is built, not as it is
exported: a buffer holding a live token is one screenshot away from leaking it. The default set
matches the cassette module's.

### A HAR for the bug report, and spans in Instruments

`exportHAR()` produces HAR 1.2, which every browser's network inspector, Charles, and Proxyman
already open — a support artifact that needs no new viewer. What HAR has no field for (attempts,
coalescing, cache outcome, truncation) goes in each entry's `comment`.

With `emitsSignposts` enabled, each request becomes an `os_signpost` interval with retries as point
events inside it, so request spans line up with CPU and allocations in a trace. Where `os` is
unavailable, the calls compile away.

### A panel, kept thin

`NetworkDiagnosticsView` shows the summary, the request list, and one request's timeline on Apple
platforms. Everything it displays is computed by `DiagnosticsPanelState`, which is plain Swift and
testable anywhere — the UI must not become the only way to read the data, and Linux and
command-line consumers keep the whole feature.

## What was verified

- 615 tests pass; 68 are new and cover the record model, every hook path, retry stitching, bounded
  storage, capture policies, redaction, the summary, HAR export, signposting, and the panel state.
- `Sources/NovaNetworkDiagnostics` joins the ≥90% coverage gate at 97.23% line coverage, with
  `NetworkDiagnosticsView.swift` excluded and the reason stated in the workflow: a SwiftUI view is
  not executed by unit tests, and its logic lives in the covered `DiagnosticsPanelState`.
- The Linux build gate compiles the new target; the SwiftUI panel is behind `canImport`.
- `Examples/Diagnostics` produces the waterfall above from a scripted transport, and asserts the
  credential did not reach the exported HAR.

## Three things running it caught

All three were bugs in this release's own code, found by running the example and stressing the tests
rather than by reading either:

- A 500 recorded as `succeeded`, so the summary reported "0% failed" next to a failing request. That
  is what renamed the case to `completed(status:)` and made `failureRate` count HTTP errors.
- Each retry attempt became its own record, because the recorder completed a record on the first
  end. Retried attempts now reopen the record their predecessor closed.
- Handlers assumed hooks arrive in order. They do not: each hook hands its work off through its own
  task, so a cancellation could be processed before the request it cancelled and dropped entirely.
  Every handler is now order-independent — a late start does not reopen a finished request, early
  coalescing and cache events are held by key until their record exists, and a cancellation with no
  record creates one. Six tests deliver events in the worst order to keep it that way.

## Known limitations

- A development and support tool, not production monitoring. It holds memory, not a pipeline;
  `OpenTelemetryAdapter` remains the path to a backend.
- Streaming responses, Server-Sent Events, and managed transfers are not in the timeline.
- Hooks hand work to the recorder asynchronously, so a record lands shortly after the request ends.
  Tests that assert on a record should wait for it rather than assume it is already there.

## Migration notes

Additive. New product `NovaNetworkDiagnostics`; no existing API changed shape or behavior, and the
API breaking-changes gate passes with no new allowlist entries.

## Source traceability

- DFR: [NovaNetwork 2.13 DFR](dfr/NOVA_NETWORK_V2_13_DFR.md)
- Traceability pack: [v2.13](TRACEABILITY_PACK_v2.13.md)
- Requirement IDs: FR-1…FR-12, UR-1…UR-4, DR-1…DR-3, AR-1, NFR-1…NFR-5, EC-1…EC-8
