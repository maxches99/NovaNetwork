# Diagnostics

See what the client has been doing: live requests with their retries and timings, an Instruments
trace, and a HAR file you can attach to a bug report.

## Overview

`NetworkClient` already reports everything worth knowing — through its telemetry hooks
and its event stream. What has been missing is somewhere for it to land. `DiagnosticsRecorder`
is that place:

```swift
import NovaNetworkDiagnostics

let recorder = DiagnosticsRecorder()
var configuration = NetworkClientConfiguration()
configuration.telemetryHooks = recorder.hooks
let client = NetworkClient(configuration: configuration)
recorder.startConsuming(client.events())
```

That is the whole installation. Nothing about the client changes: diagnostics is a *consumer* of the
existing contract, not an addition to it.

## What a record holds

One record per logical request — not per attempt. The client reports a start and an end for every
attempt, and announces a retry only after the failed attempt has ended; the recorder stitches those
back into the request a person actually made:

```
GET /flaky — 200 in 598 ms
  █████████████ Attempt 1
  ············ Backoff 185 ms
               ██████████████████████████ Attempt 2
               ·························· Backoff 399 ms
                                         █ Attempt 3
```

Alongside the waterfall, a record carries the method and URL, the status or the error, whether the
request was coalesced with another, how the cache answered, redacted headers, and body sizes.

`durationMilliseconds` is total elapsed time, backoff included, because that is the wait someone
actually experienced.

## Failure means failure

A transport that hands back a 500 as a response has *completed* the exchange — nothing threw. The
outcome case is therefore `completed(status:)`, and `isFailure` is what decides whether the status
was bad news: any status from 400 up, a transport error, or a cancellation.

`DiagnosticsSummary.failureRate` counts HTTP errors too. A summary reading "0% failed" next to a
list of 500s would be worse than no summary at all.

```swift
let summary = await recorder.summary()
print(summary.shortDescription)
// 4 requests · 50% failed · 25% coalesced · 66% cache hits
```

The cache-hit rate is measured against requests where a cache outcome was actually observed, so a
client with caching switched off reports nothing rather than a misleading zero.

## Bounded by construction

An unbounded diagnostics buffer is a leak in any app that runs for a while, so capacity is a
construction parameter — 200 records by default, oldest dropped first — and body capture is capped
at 64 KB with a flag on anything truncated:

```swift
DiagnosticsRecorder(options: DiagnosticsOptions(
    capacity: 500,
    bodyCapture: .sizeOnly,
    redaction: .default.redacting(headers: "X-Tenant-Signature"),
    emitsSignposts: true
))
```

Credentials are removed as a record is built, not as it is exported: a buffer holding a live token
is one screenshot away from leaking it. The default set matches the cassette module's —
`Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `X-API-Key`, `X-Auth-Token`.

## Instruments

With `emitsSignposts` enabled, every request becomes an `os_signpost` interval under the
`com.novanetwork.diagnostics` subsystem, with retries as point events inside it. Record a trace in
Instruments' os_signpost instrument and request spans appear alongside CPU, allocations, and your
app's own signposts. Where `os` is unavailable, the calls compile away.

## A HAR for the bug report

```swift
let har = try await recorder.exportHAR()
try har.write(to: url)
```

HAR 1.2, because it is already understood: every browser's network inspector, Charles, and Proxyman
open it, so a support artifact needs no new viewer. What HAR has no field for — attempts, coalescing,
cache outcome, truncation — goes in each entry's `comment`.

## The panel

`NetworkDiagnosticsView` presents the same data on Apple platforms: a summary line, a list of
requests with status colouring and badges, and a detail screen with the timeline and headers.

```swift
.sheet(isPresented: $showsDiagnostics) {
    NetworkDiagnosticsView(recorder: recorder) { har in
        // The app knows where its files go; the panel does not.
    }
}
```

The view is deliberately thin. Everything it displays is computed by `DiagnosticsPanelState`, which
is plain Swift and testable anywhere — the UI must not become the only way to read the data, and
Linux and command-line consumers keep the whole feature.

## What this is not

A development and support tool, not production monitoring. It holds memory, not a pipeline; for a
backend, `OpenTelemetryAdapter` remains the path. Streaming responses, Server-Sent Events, and
managed transfers are not in the timeline yet.

## The symbols

`DiagnosticsRecorder` collects; `DiagnosticsOptions`, `BodyCapturePolicy`, and
`DiagnosticsRedaction` configure it. `RequestDiagnostic`, its `Outcome` and `Attempt`, `BodySummary`,
and `CacheOutcome` are what it collects. `DiagnosticsSummary` aggregates, `HARExporter` exports, and
`DiagnosticsPanelState` and `NetworkDiagnosticsView` display.

They live in the `NovaNetworkDiagnostics` module.

## See Also

- <doc:ProductionChecklist>
- <doc:ChoosingAnAPI>
