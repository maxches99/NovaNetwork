# NovaNetwork 3.1 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.1 — A trace you can read, live or after the fact
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, Support
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 3.1.0
- Source baseline: 3.0 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.1.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.1.md`
  - Demo app: `DemoApp/README.md`
  - macOS inspector: `Inspector/README.md`

## 2. Goal and Scope

### Goal

Close the two gaps 2.13 left open in its own "nice-to-have after MVP" list: show every request on
one clock rather than one request at a time, and make an exported HAR something you can open rather
than only forward.

### User value

2.13's panel answers "where did this request's time go". It cannot answer the question sitting next
to it — what else was running at that moment. Concurrency, coalescing, and queueing are properties
of requests *together*, and a list of per-request waterfalls hides exactly those.

The export has the mirror-image gap. A recorder can write a HAR, and support can attach it to a
ticket, but nothing in this package can read one back. The person who receives the file has to open
a browser's network inspector, which knows nothing about attempts, coalescing, or the cache.

### Scope split

- MVP / required for 3.1:
  - a timeline model placing every retained record on one shared clock, with a readable ruler;
  - a timeline mode in the existing panel, switchable against the same snapshot;
  - a HAR reader that accepts files from any producer and restores what our own exporter recorded;
  - loading records into a recorder, so the panel can read a file exactly as it reads a session;
  - a macOS app that opens a HAR and shows it with that panel.
- Nice-to-have after MVP:
  - zoom and scrub on the timeline, and a selected time range;
  - a custom Instruments package definition over the existing signposts;
  - streaming, SSE, and transfer records as lanes;
  - comparing two traces side by side.

### Non-goals

- Attaching to a running process. The artifact is the file; this is not a proxy or a debugger.
- Replacing Instruments. `emitsSignposts` already puts request spans in a real Instruments trace,
  and that remains the path for CPU, allocations, and everything else the OS measures.
- Editing or replaying a trace. `NovaNetworkCassette` is the product for replay.
- Live network capture from other processes.

### Definition of Done

- Timeline layout and HAR reading are covered by unit tests that run on Linux.
- The panel's timeline mode is exercised by a UI test on a simulator, because whether a lane renders
  is not reachable from a unit test.
- The macOS app builds in CI.
- DFR, traceability pack, release notes, README, and CHANGELOG are updated together.

## 3. User Value

### User problem

Two requests that overlap look identical to two requests that ran back to back, if all you have is a
list with durations. The moment a screen fires four requests at once, the question is which of them
were actually concurrent, which waited, and which were served without touching the network — and
none of that is legible one row at a time.

Separately, a HAR arrives from a user and there is nothing in the package that opens it. The
information the recorder took care to capture — attempts, coalescing, cache outcome — is written
into the file and then read by nothing.

### Success metrics

- A retry storm, a coalesced pair, a cache hit, and a cancelled request are each identifiable in the
  timeline without opening a detail screen.
- A HAR written by this package and read back yields the same attempt count, coalescing flag, cache
  outcome, and outcome kind.
- A HAR from a browser opens without error and without inventing data it does not contain.

## 4. Rollout, Dependencies, Risks

### Rollout plan

Additive. `DiagnosticsTimeline`, `HARImporter`, and `DiagnosticsRecorder.load(_:)` are new public
API; the panel gains a mode switch and defaults to the list it has always shown. No existing call
site changes.

### Dependencies

None added. The timeline and the reader are Foundation only; the panel is still behind
`#if canImport(SwiftUI)`; the two apps live outside the package and consume it locally.

### Risks and mitigations

- **A shared clock compresses short requests.** A single long request makes everything else a
  sliver. Mitigated by a minimum bar width and by keeping the list mode as the default; not
  eliminated — zoom is follow-up work, and the compression is truthful.
- **HAR cannot express attempts.** Reading a retried request back gives the right count with wrong
  spacing. Mitigated by stamping restored attempts at the request's start rather than inventing
  intervals, and by saying so in the API documentation.
- **A foreign HAR may omit almost anything.** Mitigated by reading every field defensively and by
  skipping a malformed entry rather than failing the file.
- **`Date` arithmetic noise.** Milliseconds derived from `Date` carry error that broke a ruler step
  before it was found. Mitigated by rounding at the one place doubles are derived from dates.

## 5. Requirements

### Functional requirements (FR)

- **FR-13** Every retained record with a start time is placed on one window spanning the earliest
  start to the latest end. Acceptance: two overlapping requests produce intersecting spans.
- **FR-14** The window carries a ruler whose step is a number a person reads without arithmetic, at
  most six gridlines wide. Acceptance: a 600 ms window is ruled in 100 ms steps.
- **FR-15** A HAR 1.2 log is read into records, from any producer. Acceptance: a browser-shaped HAR
  with no `comment` and whole-second timestamps imports.
- **FR-16** A HAR written by `HARExporter` restores attempts, coalescing, cache outcome, and outcome
  kind. Acceptance: round-tripping a retried, coalesced, cache-served record preserves all four.
- **FR-17** Records can be loaded into a recorder, replacing what it holds and respecting capacity.
- **FR-18** An unfinished request is drawn up to the moment the snapshot was read, not to zero.

### UX requirements (UR)

- **UR-5** The panel switches between list and timeline against the same snapshot, without reloading.
- **UR-6** A lane opens the same detail screen a list row opens.
- **UR-7** The macOS app states what it wants before anything is open, and names the file once one is.
- **UR-8** A file that cannot be read produces a message naming the file and the reason.

### Data requirements (DR)

- **DR-4** Nothing is written by the reader; the file is opened read-only and closed.
- **DR-5** Loaded records are ordinary records: redaction already happened before export, and the
  reader adds nothing that was not in the file.

### Non-functional requirements (NFR)

- **NFR-5** The timeline and the reader are Foundation only and build on Linux.
- **NFR-6** The public API added here does not break 2.0 compatibility.

### Edge cases (EC)

- **EC-9** No records: nothing to draw, no ruler, no division by zero.
- **EC-10** Every record in one instant: the window is clamped to 1 ms rather than zero.
- **EC-11** A record that never started: excluded from the timeline, kept in the list.
- **EC-12** A request still in flight: drawn to the read moment; no duration text.
- **EC-13** A HAR whose entries lack a URL: that entry is skipped, the rest are read.
- **EC-14** A HAR at a major version other than 1: rejected with the version named.
- **EC-15** A base64 body: decoded rather than kept as text.
- **EC-16** A file that is not JSON, or JSON that is not HAR: rejected with a reason a person reads.

## 6. State Machine and Flows

Panel: `list ⇄ timeline`, both rendering the same `snapshot()`; either may push `detail(record)`.

Inspector: `empty → reading → open`, and `reading → failed → empty|open` — a failed read leaves any
already-open trace alone, so a bad drop does not lose the file you were reading.

## 7. Engineering Notes

The rule for where an attempt ends and its successor's backoff begins now lives in one function
returning absolute intervals; the per-request waterfall and the shared timeline both map those to
their own axis. Before this change the rule existed only inside the waterfall, and a second view
would have been a second copy of it.

`DiagnosticsTimeline` takes `now` rather than reading the clock, so an in-flight lane is
deterministic in tests.

The macOS app is deliberately thin: a model that opens a file into a recorder, and the package's own
panel. Everything it displays is library code, so the app cannot drift from what an embedded panel
shows.

## 8. Test Matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-13, UR-5 | T-9.2, T-9.3, T-9.6, T-9.7 | unit | Engineering |
| FR-14 | T-9.10, T-9.11 | unit | Engineering |
| FR-18, EC-12 | T-9.9 | unit | Engineering |
| EC-9, EC-10, EC-11 | T-9.1, T-9.4, T-9.5 | unit | Engineering |
| FR-15, EC-13…EC-16 | T-10.6…T-10.9 | unit | Engineering |
| FR-16 | T-10.1…T-10.5 | unit | Engineering |
| FR-17 | T-10.10, T-10.11 | unit | Engineering |
| UR-5, UR-6 | T-UI-4 | UI | Engineering |

### Negative tests

- A HAR at version 2.0 is rejected rather than half-read.
- A malformed entry does not take the rest of the file with it.
- A record with no start time is not placed on the clock.
- Bars are positioned against the window, not against their own request — the failure this guards
  would make every lane start at the left edge.
