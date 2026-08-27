# NovaNetwork 2.12 DFR

## 1. Metadata

- Feature name: NovaNetwork 2.12 — Record and Replay (cassettes)
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, QA
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 2.12.0
- Source baseline: 2.11 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v2.12.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v2.12.md`
  - DocC article: `Sources/NovaNetworkClient/NovaNetworkClient.docc/RecordAndReplay.md`

## 2. Goal and Scope

### Goal

Let a developer record real HTTP traffic once and replay it deterministically forever: in tests, in
SwiftUI previews, and in an app's offline demo mode. The recording is a readable file that gets
reviewed and committed like any other fixture.

### User value

Testing networking code today means writing a stub transport by hand for every scenario, which is
tedious and drifts from what the server actually returns. The alternative — hitting the real service
— makes tests slow, flaky, and dependent on someone else's uptime. A cassette gives the fidelity of
the real exchange with the determinism of a fixture, and the diff shows exactly what changed when
the server's shape changes.

### Scope split

- MVP / required for 2.12:
  - cassette model and a stable, reviewable JSON format;
  - record, replay, and record-missing modes over any upstream ``NetworkTransport``;
  - configurable request matching and ordered playback of repeated requests;
  - redaction at record time so credentials never reach disk;
  - deterministic persistence, a scoped `withCassette` helper, and typed errors;
  - a product that ships independently of the test-support module, for demo and preview use.
- Nice-to-have after MVP:
  - recording streamed responses and Server-Sent Events;
  - recording managed transfers;
  - a cassette-editing command plugin.

### Non-goals

- Recording transport-level failures. A thrown transport error is not an HTTP exchange; only
  completed exchanges are recorded, and failures propagate unchanged.
- Proxy-based or system-wide interception. Cassettes wrap this package's transport contract, not
  `URLProtocol`.
- Matching heuristics that guess. An unmatched request in replay mode is an error naming the
  request, never a silent empty response.
- Editing or migrating cassettes recorded by other libraries.

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

A hand-written stub says what the developer believes the server returns. A cassette says what it
actually returned, including the header casing, the null field, and the error envelope nobody
remembered. When the server changes, a re-recorded cassette shows the difference as a diff instead
of as a mysterious decoding failure in production.

The same recording also solves two adjacent problems: SwiftUI previews that need data without a
network, and demo builds that must work on a conference Wi-Fi.

### Success metrics

| Metric | Baseline | Target | Measurement method |
|---|---|---|---|
| Lines of test code to fake one exchange | ~15 (hand-written transport) | ≤ 3 | Comparison in `RecordAndReplayTests` |
| Secrets written to a cassette by default | n/a | 0 | `T-7.1` asserts default redaction |
| Byte-identical output across saves | n/a | 100% | `T-8.1` |
| Replay determinism across runs | n/a | 100% | `T-3.1`, run in CI |

## 4. Rollout, Dependencies, Risks

### Rollout plan

- Feature flag: none. New product `NovaNetworkCassette`; nothing existing changes behavior.
- Initial rollout: additive minor release 2.12.0.
- Segments: all consumers; opt-in by linking the product.
- Rollback trigger: none applicable — no existing code path is modified.

### Dependencies

- Internal: `NovaNetworkCore` (`APIRequest`, `NetworkResponse`, `NetworkTransport`).
- External: none.

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| A recorded cassette leaks a token into the repository | High | Medium | Redaction applies at record time, defaults cover the common credential headers, and a test asserts the default set |
| Cassettes rot silently against a changed server | Medium | High | Recording is explicit and re-recording produces a reviewable diff; the format stays human-readable so the diff is meaningful |
| Matching too loose, so a test passes against the wrong recording | High | Low | Default matches method and full URL; looser or stricter rules are explicit and documented |
| Matching too strict, so replay fails on an irrelevant header | Medium | Medium | Headers and body are not matched by default; the error names the request and lists near misses |

## 5. Requirements

### Functional requirements (FR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | A cassette is an ordered list of request/response interactions with a versioned JSON format | Round-trips through save and load unchanged | T-1.1 |
| FR-2 | UTF-8 bodies are stored as text; other bodies as base64 | A JSON body is readable in the file; binary data round-trips exactly | T-1.2 |
| FR-3 | Replay mode serves matched interactions and never contacts the upstream transport | Upstream call count stays zero; response equals the recording | T-3.1 |
| FR-4 | Record mode performs the real request and appends the exchange | Interaction count grows by one per request, in order | T-4.1 |
| FR-5 | Record-missing mode replays a match and records anything else | A second run of the same scenario contacts no upstream | T-5.1 |
| FR-6 | Request matching is configurable: method, URL, path, query, named headers, body | Each rule matches and rejects as documented; default is method plus full URL | T-6.1 |
| FR-7 | Repeated identical requests replay in recorded order, once each | Three recordings of one request replay as first, second, third | T-6.2 |
| FR-8 | Exhausted matches follow an explicit policy: error, or repeat the last recording | Both policies verified | T-6.3 |
| FR-9 | Credentials are redacted at record time, with defaults for the common credential headers and hooks for more | `Authorization`, `Cookie`, `Set-Cookie`, `Proxy-Authorization`, and `X-API-Key` never reach disk; custom redactors apply to headers, query items, and bodies | T-7.1, T-7.2 |
| FR-10 | Saving is atomic and deterministic | Two saves of the same cassette produce identical bytes | T-8.1 |
| FR-11 | `withCassette` loads, runs a scope, and saves when the cassette changed | An unchanged cassette is not rewritten | T-9.1 |
| FR-12 | An unmatched request in replay mode throws an error naming method, URL, and the closest recordings | Message contains the request line and candidate count | T-3.2 |
| FR-13 | A missing or malformed cassette file throws a typed error naming the path | Both cases verified | T-12.1 |
| FR-14 | The cassette transport ships as its own product, usable outside tests | `NovaNetworkCassette` builds without the test-support module | Package graph |

### UX requirements (UR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Recording a scenario takes one line of setup | `withCassette(at:mode:upstream:)` wraps the whole flow | `RecordAndReplayTests` |
| UR-2 | A cassette file is readable and reviewable | JSON is pretty-printed with sorted keys and text bodies | T-8.1 |
| UR-3 | Every public symbol carries DocC documentation | Documentation build has no missing-doc warnings | DocC build |
| UR-4 | Failure messages say what to do next | Unmatched-request and mode errors name the request and the mode that rejected it | T-3.2 |

### Data requirements (DR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Cassette format carries an explicit version | Version mismatch is a typed error, not a crash | T-12.2 |
| DR-2 | No credential material is persisted | Redaction runs before serialization, verified by test | T-7.1 |
| DR-3 | No existing on-disk format changes | Offline queue and transfer journals untouched | Diff review |

### Analytics requirements (AR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | No new runtime telemetry. A cassette is a transport; the client's existing events describe execution unchanged | Replayed requests emit the same client events as live ones | T-10.1 |

### Non-functional requirements (NFR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | No new package dependencies | `swift package show-dependencies` unchanged | CI |
| NFR-2 | Compiles on Linux under complete concurrency checking | Linux gate extended to the new target | CI |
| NFR-3 | Additive: no existing public symbol changes shape | API breaking-changes gate passes | CI |
| NFR-4 | Unit coverage stays above 90% | Coverage gate includes the new target | CI |
| NFR-5 | Replay of a 100-interaction cassette resolves a request in under 1 ms | Measured in `T-6.4` | T-6.4 |

### Edge cases (EC)

| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Empty cassette in replay mode | First request throws the unmatched error | T-3.2 |
| EC-2 | Query items in a different order | Matched, because comparison is order-insensitive per rule | T-6.1 |
| EC-3 | Header name casing differs | Matched case-insensitively when headers are part of the rule | T-6.1 |
| EC-4 | Binary (non-UTF-8) response body | Stored base64 and replayed byte-identical | T-1.2 |
| EC-5 | Upstream throws during record mode | The error propagates; nothing is appended | T-4.2 |
| EC-6 | Two concurrent requests against one cassette | Actor isolation serializes access; both resolve correctly | T-11.1 |
| EC-7 | Replay of an HTTP error response (4xx/5xx) | Replayed as a response, not as a thrown error | T-3.3 |
| EC-8 | A cassette recorded with redaction is replayed | Redacted values replay as recorded; matching ignores redacted headers by default | T-7.2 |

## 6. State Machine and Flows

| From | Trigger | To | Notes |
|---|---|---|---|
| `idle` | request arrives, mode replays | `matching` | Rule applied against unconsumed interactions |
| `matching` | match found | `replayed` | Interaction consumed; upstream untouched |
| `matching` | no match, mode is `.replay` | `failed` | Typed unmatched error |
| `matching` | no match, mode is `.recordMissing` | `recording` | Falls through to upstream |
| `idle` | request arrives, mode records | `recording` | Upstream performs the exchange |
| `recording` | upstream returns a response | `recorded` | Redacted, appended, marked dirty |
| `recording` | upstream throws | `failed` | Error propagates, nothing appended |

## 7. Engineering Notes

- **Redaction happens before anything is stored, not before it is written.** A redactor that ran at
  save time would leave the secret in memory in a value the caller could inspect or serialize
  elsewhere; running it as the interaction is recorded means the secret exists only in the live
  request.
- **Matching defaults to method and full URL** because that is the identity a reader assumes from
  looking at a cassette. Headers and bodies are available but off by default: matching on a header
  that carries a nonce or a timestamp makes every replay fail for a reason nobody can see.
- **Repeated requests replay as episodes** — first match consumed first — because polling and
  pagination are exactly what people record, and returning the same first response forever would
  quietly turn a sequence test into a constant.
- **Its own product, not test-only.** Previews and demo builds want replay without linking a test
  support module, and the module is small enough that the extra product costs nothing.
- **Determinism over metadata.** No timestamps are written, even though a recorded-at date is
  tempting: a cassette that changes on every save produces noise in review and cannot be asserted
  byte-for-byte.

## 8. Test Matrix

| Requirement ID | Test ID | Test type | Owner | Status |
|---|---|---|---|---|
| FR-1, DR-1 | T-1.1 | unit | Engineering | done |
| FR-2, EC-4 | T-1.2 | unit | Engineering | done |
| FR-3, EC-1, EC-7 | T-3.1, T-3.2, T-3.3 | unit | Engineering | done |
| FR-4, EC-5 | T-4.1, T-4.2 | unit | Engineering | done |
| FR-5 | T-5.1 | unit | Engineering | done |
| FR-6, FR-7, FR-8, EC-2, EC-3, NFR-5 | T-6.1…T-6.4 | unit | Engineering | done |
| FR-9, DR-2, EC-8 | T-7.1, T-7.2 | unit | Engineering | done |
| FR-10, UR-2 | T-8.1 | unit | Engineering | done |
| FR-11 | T-9.1 | unit | Engineering | done |
| AR-1 | T-10.1 | integration | Engineering | done |
| EC-6 | T-11.1 | unit (concurrency) | Engineering | done |
| FR-13, DR-1 | T-12.1, T-12.2 | unit | Engineering | done |

### Negative tests

- T-3.2 asserts the unmatched-request error names method and URL and reports how many recordings existed.
- T-4.2 asserts a throwing upstream leaves the cassette unchanged.
- T-7.1 asserts no default-redacted header value reaches serialized output.
- T-12.1 and T-12.2 assert typed errors for a missing file, malformed JSON, and an unsupported format version.
