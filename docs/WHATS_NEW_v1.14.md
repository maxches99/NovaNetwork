# What's New in v1.14

## Offline-First Sync Pipeline
- Added offline replay priorities for queued writes: `critical`, `normal`, `background`.
- Added policy-driven replay scheduler controls:
  - fairness weights,
  - starvation protection,
  - per-priority replay band limits,
  - replay windows and rate controls for reconnect recovery.

## Conflict Workflows
- Added rich conflict metadata contract (`OfflineQueueConflictMetadata`) for conflict decision hooks.
- Added `NetworkClient` conflict resolver hook: `offlineConflictResolver`.
- Added safe post-resolution API for manual items: `replayManualReviewItem(queueID:resolutionReason:)`.
- Normalized terminal replay outcomes and telemetry for drop/manual/dead-letter paths.

## Secure Persistence Lifecycle
- Added encrypted offline-store rotation support with `rotateOfflineQueueEncryption()`.
- Added rotating AES-GCM cipher support (`RotatingAESGCMOfflineWriteStoreCipher`) for key-version transitions.
- Added partial schema compatibility behavior:
  - older compatible entries can be loaded by newer readers,
  - incompatible future entries are preserved.
- Added recovery report accounting (`OfflineStoreRecoveryReport`) to quantify skipped corrupted/incompatible records.

## Operability and Observability
- Added offline pipeline metrics API: `offlineQueuePipelineMetrics()` with:
  - queue age distribution (`p50`, `p90`, `max`),
  - replay throughput,
  - terminal outcome breakdown.
- Added explicit recovery-loss telemetry signal (`recoveryLossDetected`) including skipped record counts.
- Extended offline telemetry context with replay priority and skipped-record fields.

## Tests and Docs
- Added unit/integration coverage for scheduler fairness/starvation, conflict resolver/manual-review replay, schema compatibility, encryption rotation, and recovery-loss telemetry.
- Added v1.14 DFR with requirements and test matrix:
  - `docs/REQUEST_COALESCER_V1_14_DFR.md`
- Updated `README.md` with v1.14 offline-first usage examples.
