# NovaNetwork 2.13 DFR

## 1. Metadata

- Feature name: NovaNetwork 2.13 — Diagnostics you can see
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, Support
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 2.13.0
- Source baseline: 2.12 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v2.13.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v2.13.md`
  - DocC article: `Sources/NovaNetworkClient/NovaNetworkClient.docc/Diagnostics.md`

## 2. Goal and Scope

### Goal

Turn the telemetry this package already emits into something a developer can look at: a live list of
requests with their retries and timings, an Instruments trace, and a HAR file that opens in any
browser's network inspector and can be attached to a bug report.

### User value

`events()` and `NetworkTelemetryHooks` describe everything that happens, but consuming them means
writing an aggregator, a UI, and an exporter before you learn anything. The information is already
there; what is missing is a way to see it. Support cases in particular need an artifact — "it was
slow on my phone" turns into a file with the actual timings, statuses, and retry decisions.

### Scope split

- MVP / required for 2.13:
  - a bounded diagnostics recorder that installs as telemetry hooks and an event consumer;
  - per-request records with attempts, retry reasons, coalescing, cache outcome, and timings;
  - redaction of credentials before anything is retained;
  - HAR 1.2 export;
  - `os_signpost` intervals so Instruments shows request spans;
  - a SwiftUI panel showing live requests, a summary, and a per-request timeline.
- Nice-to-have after MVP:
  - a custom Instruments package definition;
  - streaming, SSE, and transfer records in the same timeline;
  - persisting a session to disk for later inspection.

### Non-goals

- Replacing an APM or a crash reporter. This is a development and support tool, not a metrics
  pipeline; the existing OpenTelemetry adapter remains the path to a backend.
- Changing what the client emits. Diagnostics is a consumer of the existing contract, so no
  telemetry surface changes shape.
- Shipping a UI that assumes an app architecture. The panel is one view a developer can present,
  not a framework.
- Retaining traffic indefinitely. The recorder is bounded by construction.

### Definition of Done

- [x] DFR updated and approved
- [x] Code implemented
- [x] Tests added/updated per matrix, unit coverage stays above 90%
- [x] Telemetry reviewed (see AR-1)
- [x] "What's New" added
- [x] Traceability pack added
- [x] Documentation (DocC, README, examples) updated
- [x] Rollout plan documented

## 3. User Value

### User problem

When a screen is slow or a request fails intermittently, the developer has logs at best. Was the
request coalesced with another? Served from cache? Retried three times with backoff? Rate limited?
The client knows all of it and says so through telemetry, but nobody wants to build a UI to find out.

### Success metrics

| Metric | Baseline | Target | Measurement method |
|---|---|---|---|
| Lines of code to see live request activity | ~100 (hand-written aggregator + view) | ≤ 3 | `Examples/Diagnostics` |
| Support artifact for a networking bug | none | one HAR file | `T-4.1` |
| Memory held by the recorder | unbounded if hand-rolled | fixed by capacity | `T-2.2` |
| Credentials in an exported HAR | n/a | 0 | `T-5.1` |

## 4. Rollout, Dependencies, Risks

### Rollout plan

- Feature flag: none. New product `NovaNetworkDiagnostics`; nothing existing changes behavior.
- Initial rollout: additive minor release 2.13.0.
- Segments: all consumers; opt-in by installing the recorder's hooks.
- Rollback trigger: none applicable — the client is untouched.

### Dependencies

- Internal: `NovaNetworkClient` (telemetry contexts, `NetworkClientEvent`).
- External: none. `os` and `SwiftUI` are platform frameworks used behind `canImport`.

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| A HAR attached to a ticket leaks a token | High | Medium | Redaction runs before a record is retained, with the same default header set the cassette module uses |
| Recording in production inflates memory | High | Low | Ring buffer with an explicit capacity; body capture is bounded and configurable, defaulting to a size cap |
| The panel implies production monitoring | Medium | Medium | Documented as a development and support tool; the OpenTelemetry adapter stays the backend path |
| Signposts add overhead when unused | Medium | Low | Signposting is opt-in and compiles away where `os` is unavailable |

## 5. Requirements

### Functional requirements (FR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | A recorder installs as `NetworkTelemetryHooks` and records one entry per request lifecycle | A completed request produces one record with method, URL, status, and duration | T-1.1 |
| FR-2 | Records carry every attempt, with retry delay and reason | A request retried twice shows three attempts and two retry reasons | T-1.2 |
| FR-3 | Records carry coalescing outcome and cancellation | A coalesced request is marked as such; a cancelled one records its cancellation | T-1.3 |
| FR-4 | The recorder consumes `NetworkClientEvent` for cache outcomes and policy changes | A cache hit marks the record as served from cache | T-1.4 |
| FR-5 | Storage is bounded by an explicit capacity, dropping oldest first | Capacity 10 with 25 requests retains the last 10 | T-2.2 |
| FR-6 | Body capture is configurable: none, size only, or bounded bytes | Each mode verified; the bounded mode truncates and says so | T-2.3 |
| FR-7 | A summary aggregates counts, failure rate, coalescing rate, cache-hit rate, and duration percentiles | Values verified against a known sequence | T-3.1 |
| FR-8 | HAR 1.2 export produces a valid log with entries, timings, request, and response | Output parses and carries one entry per record | T-4.1 |
| FR-9 | Credentials are redacted before a record is retained | Default header set never appears in a record or an export | T-5.1 |
| FR-10 | `os_signpost` intervals mark each request, with retries as events | Signposting compiles and is opt-in; unavailable platforms no-op | T-6.1 |
| FR-11 | A SwiftUI panel lists requests, shows a summary, and details one request's timeline | Panel builds where SwiftUI exists and renders from a recorder snapshot | T-7.1 |
| FR-12 | Everything works without the panel: the recorder and exporter are headless | Core builds on Linux with no UI | CI |

### UX requirements (UR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Installing diagnostics is one property on the client's configuration | `NetworkClientConfiguration.telemetryHooks = recorder.hooks` | `Examples/Diagnostics` |
| UR-2 | A record reads as a story: what was asked, what happened, how long each part took | Record fields and panel detail cover request, attempts, outcome, timings | T-7.1 |
| UR-3 | Every public symbol carries DocC documentation | Documentation build has no missing-doc warnings | DocC build |
| UR-4 | The exported HAR opens in a browser's network inspector | Structure conforms to HAR 1.2 required fields | T-4.2 |

### Data requirements (DR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Nothing is persisted unless the caller exports it | The recorder holds memory only | Diff review |
| DR-2 | No credential material is retained | Redaction runs at record time | T-5.1 |
| DR-3 | Body capture never retains more than the configured limit | Verified for a large body | T-2.3 |

### Analytics requirements (AR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | No new telemetry is emitted and no existing contract changes. Diagnostics is a consumer of Observability Contract v2 | Client behavior identical with and without a recorder installed | T-8.1 |

### Non-functional requirements (NFR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | No new package dependencies | `swift package show-dependencies` unchanged | CI |
| NFR-2 | The headless core compiles on Linux under complete concurrency checking | Linux gate extended | CI |
| NFR-3 | Additive: no existing public symbol changes shape | API breaking-changes gate passes | CI |
| NFR-4 | Unit coverage stays above 90% | Coverage gate includes the new target | CI |
| NFR-5 | Recording adds under 50 microseconds per request on the hot path | Measured in `T-2.4` | T-2.4 |

### Edge cases (EC)

| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | A request ends without ever starting (hook order) | The record is created on end, with unknown start marked rather than a negative duration | T-1.5 |
| EC-1b | Any hook arrives before the one that logically precedes it | No fact is lost: a late start does not reopen a finished request, early coalescing and cache events are held by key, and a cancellation with no record creates one | T-1.6 |
| EC-2 | Two requests share a coalescing key | Both records exist; the joined one is marked coalesced | T-1.3 |
| EC-3 | Capacity of zero | Nothing is retained and no crash | T-2.2 |
| EC-4 | A request body larger than the capture limit | Truncated to the limit and flagged truncated | T-2.3 |
| EC-5 | Export with no records | A valid, empty HAR log | T-4.1 |
| EC-6 | A non-UTF-8 response body in HAR | Encoded base64 with the encoding field set | T-4.3 |
| EC-7 | Signposting on a platform without `os` | Compiles and does nothing | CI (Linux) |
| EC-8 | Concurrent requests recording at once | Actor isolation serializes; all records present | T-2.5 |

## 6. State Machine and Flows

| From | Trigger | To | Notes |
|---|---|---|---|
| `absent` | `onRequestStart` | `inFlight` | Record created, attempt 1 appended, signpost interval begins |
| `inFlight` | `onRetryScheduled` | `inFlight` | Attempt appended with delay and reason |
| `inFlight` | cache event for the key | `inFlight` | Cache outcome annotated |
| `inFlight` | `onRequestEnd` with a response | `completed` | Status, duration, and body summary stored; interval ends |
| `inFlight` | `onRequestEnd` with an error | `failed` | Error reason stored; interval ends |
| `inFlight` | `onRequestCancelled` | `cancelled` | Cancellation reason stored |
| `completed`/`failed`/`cancelled` | capacity exceeded | `evicted` | Oldest record dropped first |

## 7. Engineering Notes

- **Every handler is order-independent.** The hooks hand their work off through separate tasks, so
  nothing guarantees a start is processed before the end that followed it, or that a cancellation
  lands while its record is still open. Handlers that assumed an order would drop events on a busy
  device: a start arriving late must not reopen a finished request, an early coalescing or cache
  event is held by key until its record exists, and a cancellation with no record creates one.
- **A consumer, not a change.** Everything here reads the existing telemetry and event contract. If
  diagnostics needed a new hook, that would be a signal the contract was incomplete — and this
  release deliberately does not add one.
- **Redaction is duplicated on purpose, for now.** The cassette module carries the same default
  header set. Sharing it would couple two independent products through `NovaNetworkCore`; unifying
  them is follow-up work, and the duplication is one list in one file with a test asserting it.
- **Bounded by construction.** A diagnostics buffer that grows until memory runs out is a bug
  waiting for a long-running app. Capacity is a required construction parameter with a documented
  default, and body capture is capped.
- **The panel is optional and separate from the truth.** The recorder and the exporter are headless
  and testable; the SwiftUI view renders a snapshot. That keeps Linux and command-line consumers
  whole and means the UI cannot become the only way to read the data.
- **HAR because it is already understood.** Every browser, Charles, and Proxyman reads it, so a
  support artifact needs no new viewer.

## 8. Test Matrix

| Requirement ID | Test ID | Test type | Owner | Status |
|---|---|---|---|---|
| FR-1, FR-2, FR-3, FR-4, EC-1, EC-2 | T-1.1…T-1.5 | unit | Engineering | done |
| FR-1…FR-4, EC-1b | T-1.6 | unit | Engineering | done |
| FR-5, FR-6, EC-3, EC-4, EC-8, NFR-5 | T-2.2…T-2.5 | unit | Engineering | done |
| FR-7 | T-3.1 | unit | Engineering | done |
| FR-8, UR-4, EC-5, EC-6 | T-4.1…T-4.3 | unit | Engineering | done |
| FR-9, DR-2 | T-5.1 | unit | Engineering | done |
| FR-10 | T-6.1 | unit | Engineering | done |
| FR-11, UR-2 | T-7.1 | unit (snapshot of view model) | Engineering | done |
| AR-1 | T-8.1 | integration | Engineering | done |

### Negative tests

- T-1.5 asserts an end without a start produces a usable record rather than a negative duration.
- T-2.2 asserts eviction order and a capacity of zero.
- T-5.1 searches an exported HAR for the credential and asserts it is absent.
- T-4.3 asserts a binary body is base64-encoded with the HAR `encoding` field set.
