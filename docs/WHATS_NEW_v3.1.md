# What's New in 3.1

## A trace you can read, live or after the fact

2.13 gave the diagnostics panel a waterfall per request: where did *this* request's time go. 3.1
adds the question sitting next to it — what else was running at that moment — and makes the HAR the
recorder writes something this package can open again.

### One clock instead of one row at a time

`DiagnosticsTimeline` places every retained record on a single window, from the earliest start to
the latest end, with a ruler stepped in numbers a person reads without arithmetic:

```
2.1 s total    0 ms      500 ms     1 s       1.5 s
GET /flaky     ▐█▌──▐█▌────▐█▌
775 ms
GET /profile              ▐██▌
120 ms
GET /settings                   ▐██▌
127 ms
POST /orders                          ▐█▌
62 ms
GET /slow                                  ▐████████
in flight
```

Concurrency, coalescing, and queueing are properties of requests *together*. Two callers coalesced
onto one request start on the same vertical line. A cache hit is a sliver. A retry storm is a row of
bars with the backoff visible between them. None of that is legible one request at a time.

The panel gained a **List / Timeline** switch; the list is still the default, and both read the same
snapshot. A lane opens the same detail screen a row opens.

An unfinished request is drawn up to the moment the snapshot was read, rather than to zero — a
request still running is the one you are usually looking for.

### The export became readable

`HARImporter` reads HAR 1.2 back into records. It accepts files from any producer — a browser,
Charles, Proxyman — and restores what HAR itself has no field for when the file came from
`HARExporter`: attempts, coalescing, and the cache outcome, which the exporter writes into each
entry's `comment`.

```swift
let records = try HARImporter().import(Data(contentsOf: url))
await recorder.load(records)   // now the panel reads the file exactly as it reads a session
```

A HAR cannot express *when* each attempt ran, so a retried request comes back with the right number
of attempts stamped at the request's start. The count is real; the spacing is not, and the API says
so rather than inventing intervals.

A malformed entry is skipped rather than failing the file. Support artifacts arrive truncated, and
four of five entries beats none.

### A macOS app for the file someone sent you

`Inspector/` is a separate Xcode project: drop a HAR on it, or open one with ⌘O, and read it with
the same panel a live app embeds. It is deliberately thin — a model that opens a file into a
recorder, and library code for everything else — so it cannot drift from what an embedded panel
shows.

It is a reader, not a proxy: it never attaches to a running process. `emitsSignposts` already puts
request spans into a real Instruments trace, and that remains the path for CPU and allocations.

## What was verified

- 24 new unit tests: 12 over the timeline layout and its ruler, 10 over HAR reading, and 2 over
  loading records into a recorder. All run on Linux.
- A UI test on a simulator switches the panel to the timeline and asserts the ruler and the lanes,
  because whether a lane renders is not reachable from a unit test.
- The macOS app was opened against a HAR produced from real `httpbin.org` traffic.
- The full suite: 788 tests.

## One thing writing it caught

Milliseconds derived from `Date` carry arithmetic noise: a 600 ms window came back as 600.0000238.
Invisible on screen, and not invisible to a ruler asking whether that window divides into six 100 ms
steps — it got seven and fell back to 250 ms steps. The rounding now happens once, where doubles are
derived from dates, and the fractions in public API are clean as a side effect.

## Known limitations

- No zoom or scrub. A single long request compresses everything else into slivers. The compression
  is truthful, but it is not yet navigable.
- Streaming, SSE, and transfers still have no lanes.
- No custom Instruments package; the signposts are there, the `.instrpkg` is not.
- Two traces cannot be compared side by side, beyond opening two windows.

## Migration notes

Additive. `DiagnosticsTimeline`, `HARImporter`, and `DiagnosticsRecorder.load(_:)` are new; the
panel defaults to the list it always showed. No existing call site changes.

## Source traceability

- DFR: `docs/dfr/NOVA_NETWORK_V3_1_DFR.md`
- Traceability pack: `docs/TRACEABILITY_PACK_v3.1.md`
