# NovaNetwork 2.1 DFR

## 1. Metadata

- Feature name: NovaNetwork 2.1 — Reliable, Resumable, and Background Transfers
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, QA, Support/Ops
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-07-15
- Target version: 2.1.0
- Source baseline: 2.0.0 (`7e22c0af6b03e4282d561537ce9064b713247296`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v2.1.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v2.1.md`
  - Test policy: `docs/UNIT_TEST_POLICY.md`

## 2. Goal and Scope

### Goal

Extend the foreground transfer APIs introduced in 2.0 with stable transfer identity, durable
state, resumable download and upload contracts, Apple background URLSession coordination,
relaunch reconciliation, integrity verification, network policy controls, and actionable
telemetry while preserving existing source compatibility.

### User value

Applications transferring large files should not have to restart from byte zero after a
temporary interruption or lose observability when the process is suspended. Consumers need a
Sendable transfer model that can be restored after relaunch without persisting credentials and
without receiving duplicate completion callbacks.

### Scope split

- MVP / required for 2.1:
  - stable transfer identity, snapshots, durable journal, and schema migration;
  - HTTP Range / If-Range resumable downloads with safe full-restart fallback;
  - pluggable resumable upload strategy plus a TUS-compatible offset strategy;
  - Apple background URLSession task creation, task reconciliation, and host lifecycle handoff;
  - integrity verification, transfer network policies, telemetry, Linux Core CI, docs, and tests.
- Nice-to-have after MVP:
  - additional vendor-specific upload strategies;
  - richer aggregate transfer dashboards;
  - automatic BackgroundTasks framework scheduling owned by an app integration package.

### Non-goals

- Hiding host application entitlements, capabilities, or background session lifecycle callbacks.
- Persisting Authorization, Cookie, proxy credentials, or arbitrary sensitive headers.
- Claiming that resumable upload works against servers that do not implement a negotiated
  resumable protocol.
- Replacing URLSession or adding a third-party transport dependency.
- Providing a full Linux/Windows implementation of `NovaNetworkClient`; only
  `NovaNetworkCore` receives a Linux build guarantee in 2.1.
- Adding UI components, endpoint macros, GraphQL, gRPC, or breaking/removing 2.0 APIs.

### Definition of Done

- [x] Public API and persistence schema are documented with DocC and engineering notes.
- [x] Existing 2.0 source APIs remain compatible and all examples compile.
- [x] Required happy paths, edge cases, analytics contracts, and negative paths are tested.
- [x] Unit/integration line coverage remains above 90%.
- [x] Real-public-API E2E covers network-observable 2.1 behavior without mocks or stubs.
- [x] Complete strict-concurrency checking passes on the current Swift lane (verified locally);
      the minimum-lane (Swift 6.2.3, Linux) run is CI-only -- see note below.
- [ ] `NovaNetworkCore` builds on Linux CI.
- [x] README, traceability pack, migration guidance, and `WHATS_NEW_v2.1.md` are complete.
- [ ] Release candidate passes two consecutive post-merge CI runs before tagging.

**Pre-commit audit note (2026-08-24):** finishing this feature included an implementation audit,
not just a status check. Findings, all fixed and covered by new regression tests before this
commit:
- `ManagedTransferSnapshot`'s `createdAt`/`updatedAt` did not round-trip exactly through
  `DiskTransferJournal`'s `.secondsSince1970` JSON encoding for an unrounded `Date()` (~50% of the
  time), the root cause of an intermittent flaky journal test seen throughout earlier 2.x work.
  Fixed by rounding to millisecond precision at snapshot construction.
- `DiskTransferJournal.upsert` relied on `Data.write(options: .atomic)`'s own hidden temp-file
  naming (empirically `.dat.nosync<hex>.<random>`), which `cleanupOrphanedTemporaryRecords()`'s
  `.transfer.json.partial` filter could never match -- a crash between write and publish would
  leave an orphaned temp file the recovery scan could never find. Fixed by staging through an
  explicitly named `.partial` file before an atomic publish.
- `ManagedTransferManager.startDownloadTask`/`startUploadTask` registered the cancellation action
  on an unawaited sibling `Task`, racing a caller that cancels the handle immediately after start.
  Fixed by awaiting registration before the handle is returned.
- Unit line coverage was actually 88.7-90.0% (methodology-dependent) before this audit, not the
  >=90% the checkbox above claimed -- `BackgroundTransferCoordinator.scheduleDownload`/
  `scheduleUpload`/`reconcile`/`restore` and several `ManagedTransferManager` resume/replace paths
  had no unit coverage at all (only E2E, which the CI coverage gate does not credit). Added 12
  tests; verified line coverage is now 90.1% using the exact command CI's gate runs.
- The pre-iOS-15/macOS-12 `legacyDownload` fallback in `ManagedTransferManager` is structurally
  unreachable in coverage measured on CI's macOS 15 runners (the `#available` check always takes
  the modern branch there); it is kept for the package's stated minimum-platform support and is
  exercised only by manual/older-OS testing, not by this suite.

## 3. Success Metrics

| Metric | Baseline | 2.1 target | Measurement |
|---|---:|---:|---|
| Interrupted download reused bytes | 0% | Server-accepted partial bytes are not downloaded again | Range E2E and byte accounting |
| Duplicate terminal events | Not applicable | 0 across 100 repeated resume/recovery cycles | deterministic stress test |
| Journal recovery | None | 100 valid snapshots restore; corrupt records are isolated | store recovery tests |
| Credential persistence | Not defined | 0 prohibited headers/values on disk | serialized-file audit |
| Background task reconciliation | None | Every matching URLSession task maps to one TransferID | integration test/sample app |
| Unit/integration coverage | 92.45% | >= 90% | CI llvm-cov gate |
| Core Linux compatibility | Not enforced | Ubuntu CI build passes | Linux CI job |

## 4. Rollout, Dependencies, and Risks

### Rollout

- Feature flag: none; all managed/background/resume APIs are opt-in.
- Existing `upload` and `download` streams retain their 2.0 behavior.
- Initial rollout: `2.1.0-rc.1`, external SwiftPM smoke, app-host background test, then stable.
- Rollback triggers: file corruption, duplicate completion, credential persistence, task identity
  mismatch, strict-concurrency regression, or coverage below 90%.

### Dependencies

- Internal: `NetworkClient`, transfer-capable transport, telemetry hooks, fingerprinting.
- Platform: Foundation URLSession; background execution is Apple-only.
- Third-party packages: none.
- Host integration: background session identifier/callback forwarding and platform capabilities.

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Resume validator changed and bytes are concatenated incorrectly | Critical | Medium | Require valid 206/Content-Range and If-Range match; otherwise discard partial data and restart |
| Background callbacks arrive before consumer restoration | High | High | Actor-owned buffered event hub keyed by TransferID |
| Duplicate OS task reconciliation | High | Medium | Persist task identifier and enforce one-to-one mapping |
| Journal contains credentials | Critical | Medium | Header denylist, safe-header allowlist, serialized-file tests |
| Journal corruption blocks every transfer | High | Medium | Per-record schema envelope and partial recovery report |
| Upload server uses incompatible resume semantics | High | High | Strategy protocol and explicit server capability validation |
| Cancellation races with finalization | High | Medium | Actor-isolated terminal transition and atomic destination move |
| Background behavior cannot be proven in package-only tests | Medium | High | URLSession integration coverage plus a minimal app-host verification fixture |
| Public demo service is unavailable | Medium | Medium | E2E skip only when gate variable is absent; release gate requires a successful configured run |

## 5. Requirements

### Functional requirements

| ID | Requirement | Acceptance criteria | Tests |
|---|---|---|---|
| FR-TR-1 | Stable transfer identity | Every managed operation has a Sendable/Codable `TransferID` that remains stable across snapshots and restoration. | T-TR-1 |
| FR-TR-2 | Transfer handle and events | A handle exposes its ID, current snapshot, cancellation, and an async event stream with exactly one terminal event. | T-TR-2, T-TR-3 |
| FR-TR-3 | Durable transfer journal | A versioned store atomically upserts/removes snapshots and partially recovers valid records when one record is corrupt. | T-STORE-1...4 |
| FR-TR-4 | Relaunch reconciliation | Persisted records and live background URLSession tasks reconcile one-to-one; orphaned records/tasks are reported explicitly. | T-RESTORE-1...3 |
| FR-DL-1 | Resumable download request | A partial download resumes with `Range` and `If-Range` when a validator is available. | T-DL-1, E2E-DL-1 |
| FR-DL-2 | Resume response validation | Only a valid 206 with a matching Content-Range appends bytes; 200, 412, or invalid ranges safely restart. | T-DL-2...5 |
| FR-DL-3 | Atomic finalization | Partial bytes are stored separately and become the destination only after success and integrity validation. | T-DL-6 |
| FR-UP-1 | Upload strategy contract | A Sendable strategy can create, query, and append to a server-side upload resource without exposing credentials to persistence. | T-UP-1 |
| FR-UP-2 | TUS-compatible upload | The built-in strategy negotiates TUS version, persists upload URL/offset metadata, and resumes from the server-reported offset. | T-UP-2...5, E2E-UP-1 |
| FR-BG-1 | Background configuration | Apple clients can create background upload/download tasks using a caller-owned session identifier. | T-BG-1 |
| FR-BG-2 | Host lifecycle bridge | The host can forward background session completion; the coordinator invokes the completion handler once after pending callbacks drain. | T-BG-2, T-BG-3 |
| FR-BG-3 | Background restoration | Existing URLSession tasks restore into managed snapshots without starting duplicate network work. | T-BG-4 |
| FR-INT-1 | Integrity verification | Optional expected byte count and SHA-256 digest are checked before download completion. | T-INT-1...3 |
| FR-POL-1 | Network policy | Managed transfers expose cellular, expensive, constrained, discretionary, and priority policy where supported. | T-POL-1...3 |

### UX/API requirements

| ID | Requirement | Acceptance criteria | Tests |
|---|---|---|---|
| UR-1 | Progressive adoption | Existing transfer APIs are unchanged; managed APIs are additive and opt-in. | T-COMPAT-1 |
| UR-2 | Observable state | Snapshot/event state names map directly to queued, preparing, transferring, suspended, resuming, restoring, finalizing, completed, failed, and cancelled. | T-TR-2 |
| UR-3 | Actionable errors | Unsupported resume, invalid ranges, integrity mismatch, restoration conflict, and background unavailability use typed errors. | T-ERR-1...5 |
| UR-4 | Documentation | Every public declaration has DocC covering lifecycle, cancellation, platform limits, and security. | T-DOC-1 |

### Data requirements

| ID | Requirement | Acceptance criteria | Tests |
|---|---|---|---|
| DR-1 | Versioned schema | Journal records carry schema version and unknown future records do not block compatible records. | T-STORE-2, T-STORE-3 |
| DR-2 | Credential exclusion | Authorization, Cookie, Proxy-Authorization, and caller-defined sensitive headers are never persisted. | T-SEC-1 |
| DR-3 | Resume checkpoint | Partial file URL, completed bytes, validator, upload URL/offset, and OS task ID persist atomically. | T-STORE-1 |
| DR-4 | Migration | Schema migration is explicit, deterministic, and preserves compatible 2.1 records. | T-STORE-4 |

### Analytics requirements

| ID | Requirement | Acceptance criteria | Tests |
|---|---|---|---|
| AR-1 | Lifecycle telemetry | Started, suspended, resumed, restored, progress, completed, failed, and cancelled include TransferID/kind without sensitive headers. | T-AR-1 |
| AR-2 | Resume telemetry | Resume attempted/accepted/restarted includes byte offset and sanitized reason. | T-AR-2 |
| AR-3 | Background telemetry | Background scheduled/reconciled/orphaned/handoff-completed events identify session and task using non-secret identifiers. | T-AR-3 |
| AR-4 | No false success | Failure, cancellation, integrity mismatch, and restoration conflicts never emit completed. | T-AR-4 |

### Non-functional requirements

| ID | Requirement | Acceptance criteria | Tests |
|---|---|---|---|
| NFR-1 | Coverage | Combined source line coverage remains >= 90%. | T-GATE-1 |
| NFR-2 | Compatibility | Swift 6.2 minimum, current stable Swift lane, existing source/API compatibility. | T-GATE-2 |
| NFR-3 | Concurrency safety | Mutable coordinator/store/session bridge state is actor-isolated; no new unjustified unchecked Sendable conformance. | T-GATE-3 |
| NFR-4 | Bounded resources | Event buffering and checkpoint memory are bounded; files are streamed rather than retained in memory. | T-GATE-4 |
| NFR-5 | Linux Core | `swift build --target NovaNetworkCore` passes on Ubuntu. | T-GATE-5 |
| NFR-6 | E2E integrity | E2E uses only real public endpoints and no mock/stub/fake transport. | T-GATE-6 |
| NFR-7 | Dependencies | No third-party package dependency is added. | package audit |

### Edge cases

| ID | Scenario | Expected behavior | Tests |
|---|---|---|---|
| EC-1 | Partial file length differs from checkpoint | Reject checkpoint and restart safely. | T-DL-3 |
| EC-2 | Server ignores Range and returns 200 | Truncate partial data and treat response as full restart. | T-DL-2 |
| EC-3 | Server reports invalid/mismatched Content-Range | Fail typed validation without exposing destination. | T-DL-4 |
| EC-4 | Validator changed | Restart from byte zero and update validator. | T-DL-5 |
| EC-5 | Integrity mismatch | Remove invalid temporary output, retain failure snapshot, emit no completion. | T-INT-2, T-AR-4 |
| EC-6 | Restore finds duplicate OS tasks | Choose no winner automatically; report restoration conflict. | T-RESTORE-2 |
| EC-7 | Store contains one corrupt record | Restore compatible records and report skipped count. | T-STORE-3 |
| EC-8 | Consumer terminates event iteration | Transfer continues or cancels according to explicit cancellation policy. | T-TR-3 |
| EC-9 | Background API on unsupported platform | Fail with typed `backgroundTransfersUnavailable`. | T-ERR-5 |
| EC-10 | Upload offset exceeds source size | Fail typed protocol validation and do not send a chunk. | T-UP-4 |

## 6. State and Flow Model

### States

`queued -> preparing -> transferring -> suspended -> resuming -> finalizing -> completed`

Additional transitions:

- any non-terminal state -> `failed` or `cancelled`;
- process relaunch -> `restoring` -> previous active state or `failed`;
- invalid download resume response -> `preparing(restart)` -> `transferring`;
- terminal states never transition to another terminal state.

### State -> observable API -> actions -> analytics

| State | Observable API | Allowed actions | Analytics |
|---|---|---|---|
| queued | snapshot + event | cancel/start | started |
| preparing | snapshot + event | cancel | started/resumeAttempted |
| transferring | progress event | suspend/cancel | progress |
| suspended | snapshot + event | resume/cancel | suspended |
| resuming | snapshot + event | cancel | resumeAttempted/accepted/restarted |
| restoring | snapshot + event | cancel/resolve conflict | restored/orphaned |
| finalizing | snapshot + event | none | none until outcome |
| completed | one terminal event | inspect/remove journal | completed |
| failed | one terminal event | retry/remove journal | failed |
| cancelled | one terminal event | remove journal | cancelled |

## 7. Engineering Notes

- Coordinator, journal, and background delegate bridge mutable state use actors.
- Public models are immutable Sendable values in `NovaNetworkCore` when transport-neutral.
- Background URLSession implementation stays in `NovaNetworkClient` and is conditionally
  compiled for Apple platforms.
- SHA-256 implementation reuses the package's dependency-free utility and streams file chunks.
- Existing foreground streams delegate into managed infrastructure only when behavior remains
  exactly source- and lifecycle-compatible.
- Upload resume capability is explicit; the strategy must validate server protocol support.

## 8. Test Matrix

| Requirement IDs | Test IDs | Type | Owner | Required result |
|---|---|---|---|---|
| FR-TR-1...2, UR-2 | T-TR-1...3 | unit | Engineering | pass |
| FR-TR-3, DR-1...4, EC-7 | T-STORE-1...4 | unit/integration | Engineering | pass |
| FR-TR-4, EC-6 | T-RESTORE-1...3 | integration | Engineering | pass |
| FR-DL-1...3, EC-1...4 | T-DL-1...6 | unit/integration | Engineering | pass |
| FR-DL-1 | E2E-DL-1 public Range endpoint | e2e | QA | pass |
| FR-UP-1...2, EC-10 | T-UP-1...5 | unit/integration | Engineering | pass |
| FR-UP-2 | E2E-UP-1 public TUS endpoint | e2e | QA | pass before release |
| FR-BG-1...3 | T-BG-1...4 | integration/app fixture | QA | pass |
| FR-INT-1, EC-5 | T-INT-1...3 | unit | Engineering | pass |
| FR-POL-1 | T-POL-1...3 | unit | Engineering | pass |
| UR-1 | T-COMPAT-1 existing suite/examples | regression | Engineering | pass |
| UR-3 | T-ERR-1...5 | unit | Engineering | pass |
| UR-4 | T-DOC-1 public DocC audit | integration | Engineering | pass |
| DR-2 | T-SEC-1 serialized journal audit | security/unit | QA | pass |
| AR-1...4 | T-AR-1...4 | unit/integration | QA | pass |
| NFR-1 | T-GATE-1 coverage >= 90% | integration | QA | pass |
| NFR-2...4 | T-GATE-2...4 strict build/stress/resource audit | integration | Engineering | pass |
| NFR-5 | T-GATE-5 Linux Core build | CI | Engineering | pass |
| NFR-6 | T-GATE-6 real-public-API scan and E2E | e2e | QA | pass |
| NFR-7 | package dependency audit | integration | Engineering | pass |

## 9. Release and Rollback

- Release notes: `docs/WHATS_NEW_v2.1.md`.
- Migration: additive APIs; existing foreground transfer calls remain supported.
- RC gate: all matrix rows green, coverage >= 90%, real E2E green, external SwiftPM smoke,
  and two consecutive post-merge CI runs.
- Rollback: withdraw 2.1 release, recommend 2.0.x, preserve journal records for a compatible
  patch, and never silently reinterpret a newer schema.
