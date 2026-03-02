# REQUEST_COALESCER_V1_14_DFR

## Metadata
- Feature: v1.14 Offline-First Sync
- Owner: Networking Platform
- Stakeholders: Product, iOS Platform, Backend API, QA/SRE
- Goal: Upgrade offline queue from FIFO buffer to policy-driven sync pipeline with conflict workflows and durable operations for long-lived offline sessions.
- Non-goals:
  - Full CRDT/domain-level merge engine.
  - Domain-specific reconciliation business rules.
- Definition of Done:
  - DFR + code + tests + telemetry + docs/README + `docs/WHATS_NEW_v1.14.md`.
  - Replay scheduler verified for fairness/starvation.
  - Key rotation + schema compatibility/migration path verified with no loss of valid records.
- Rollout plan:
  - Stage 1: enable defaults only (`normal` priority, conservative replay window).
  - Stage 2: enable priority tuning and conflict resolver in selected apps.
  - Stage 3: enable rotation/recovery telemetry alerts globally.
- Dependencies: `DiskOfflineWriteStore`, `NetworkClient`, telemetry adapter implementations.
- Risks:
  - API complexity increase.
  - Store migration failures in field.
  - Inconsistent conflict handling across teams.

## User Value
### Problem statement
Existing offline queue behavior was basic FIFO replay with limited conflict controls and insufficient operability signals for long offline periods.

### Success metrics (KPI)
- Replay success rate after long offline periods increases.
- Manual-review stuck item ratio decreases.
- Queue drain time after reconnect improves.

### Scope split
- MVP (v1.14): scheduler, conflict resolver contract, manual-review requeue API, recovery-loss telemetry, metrics API, schema compatibility + encryption rotation path.
- V1+: richer app-level reconciliation templates and prebuilt dashboard bundles.

## Requirements
### Functional requirements
- `FR-1`: Queued writes MUST support replay priorities: `critical`, `normal`, `background`.
  - Acceptance: priority persists in store entry metadata and appears in snapshot/telemetry contexts.
- `FR-2`: Replay scheduler MUST support fairness, starvation protection, per-priority band limits.
  - Acceptance: mixed-priority replay does not starve aged low-priority records; fairness weights affect order.
- `FR-3`: Replay scheduler MUST support replay windows and rate control for recovery.
  - Acceptance: scheduler can bound sustained replay burst behavior with configurable window/rate.
- `FR-4`: Conflict workflows MUST provide rich conflict metadata to resolver hook.
  - Acceptance: metadata includes queueID/requestKey/replayIdentity/attempt/status/priority/timestamps.
- `FR-5`: Manual-review items MUST support safe post-resolution replay.
  - Acceptance: API requeues only `manualReview` entries to `replayScheduled`.
- `FR-6`: Encrypted store MUST support rotation path.
  - Acceptance: rotation rewrites entries under current cipher version without dropping valid records.
- `FR-7`: Schema migration MUST support partial compatibility.
  - Acceptance: older schema entries can be loaded by newer reader when compatible; future/incompatible entries are preserved.
- `FR-8`: Recovery MUST skip bad records, preserve good records, and expose loss scale.
  - Acceptance: corrupted entries are skipped; valid entries remain; recovery report + telemetry signal include skipped counts.
- `FR-9`: Pipeline observability MUST include queue age distribution, replay throughput, terminal outcome breakdown.
  - Acceptance: `offlineQueuePipelineMetrics()` returns these values.

### UX requirements
- `UR-1`: Manual-review state taxonomy MUST be explicit and stable for app workflows.
  - Acceptance: states/events clearly distinguish `manualReview`, `replayScheduled`, terminal outcomes.

### Data requirements
- `DR-1`: Persisted replay metadata MUST include priority and scheduler policy.
- `DR-2`: Store recovery report MUST include scanned/recovered/skipped counters.

### Analytics requirements
- `AR-1`: Offline telemetry MUST include priority where applicable.
- `AR-2`: Recovery loss MUST emit explicit telemetry signal with skipped-record count.
- `AR-3`: Terminal outcomes MUST never emit false success on failure paths.

### Non-functional requirements
- `NFR-1`: Replay scheduling overhead should remain bounded and not regress existing queue throughput materially.
- `NFR-2`: Store corruption handling must be non-fatal for healthy records.

### Edge cases
- `EC-1`: Future schema/encryption version encountered.
  - Expected: skip and keep entry, no destructive delete.
- `EC-2`: Manual review requeue called for non-manual item.
  - Expected: safe no-op (`false`).
- `EC-3`: Conflict resolver overrides static policy.
  - Expected: resolver decision wins.
- `EC-4`: Long offline backlog with high-priority flood.
  - Expected: starvation protection still schedules aged background entries.

## State and Flow
### States
- `queued`
- `replayScheduled`
- `replaying`
- `retryWaiting`
- `manualReview`
- `deadLetter`

### Transition map
- `queued/replayScheduled/retryWaiting(ready)` -> `replaying` -> `succeeded|retryWaiting|manualReview|deadLetter|droppedConflict|dedupeSuppressed`
- `manualReview` -> `replayScheduled` (via post-resolution API)

## Test Matrix
| Requirement ID | Test IDs | Owner |
| --- | --- | --- |
| FR-1 | `T-1.1` (`flushOfflineQueueSchedulerProtectsStarvedBackgroundItems`) | QA + Platform |
| FR-2 | `T-2.1` (`flushOfflineQueueSchedulerProtectsStarvedBackgroundItems`) | QA + Platform |
| FR-3 | `T-3.1` (`offlineQueuePipelineMetricsExposeAgeThroughputAndOutcomes`) | Platform |
| FR-4 | `T-4.1` (`offlineConflictResolverCanOverridePolicyAndDropConflict`) | QA + Platform |
| FR-5 | `T-5.1` (`replayManualReviewItemSchedulesPostResolutionReplay`) | QA + App Team |
| FR-6 | `T-6.1` (`diskOfflineWriteStoreRotateEncryptionRewritesEntriesWithNewVersion`) | Platform |
| FR-7 | `T-7.1` (`diskOfflineWriteStoreReadsOlderSchemaWithForwardCompatibility`) | Platform |
| FR-8 | `T-8.1` (`diskOfflineWriteStoreRecoveryReportCapturesPartialCorruption`), `T-8.2` (`telemetryHooksEmitRecoveryLossSignalForPartiallyCorruptedOfflineStore`) | QA + SRE |
| FR-9 | `T-9.1` (`offlineQueuePipelineMetricsExposeAgeThroughputAndOutcomes`) | SRE + Platform |
| AR-1 | `T-10.1` (`telemetryHooksEmitOfflineQueueLifecycleContexts`) | Analytics |
| AR-2 | `T-10.2` (`telemetryHooksEmitRecoveryLossSignalForPartiallyCorruptedOfflineStore`) | Analytics |
| AR-3 | `T-10.3` (`telemetryHooksDoNotEmitOfflineQueueSuccessOnTerminalFailure`) | Analytics |

## Analytics and Alert Recommendations
- Alert when `recoveryLossDetected.skippedRecords > 0` over rolling interval.
- Alert when `terminalOutcomes.manualReview` grows without requeue drain.
- Alert when `queue age p90` exceeds SLO threshold after reconnect.
