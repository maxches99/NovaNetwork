## What's New in v1.8

- Added replay deduplication for offline write queue using replay identity and a configurable dedupe window.
- Added conflict handling policies for terminal replay conflicts:
  - `retry`
  - `drop`
  - `manualReview`
- Added replay metadata fields to queue persistence (`replayIdentity`, conflict policy, max replay attempts, terminal replay status/timestamp).
- Added optional at-rest encryption for offline write queue storage via `DiskOfflineWriteStore(cipher:)`.
- Added built-in `AESGCMOfflineWriteStoreCipher` and encryption metadata versioning support.
- Added replay terminal success index persistence to suppress duplicate replay after restart/recovery scenarios.
- Added new offline queue telemetry semantics for terminal outcomes (`executed`, `dedupe_suppressed`, `dropped_conflict`, `manual_review_required`, `failed`).
- Updated docs with new offline queue replay and encryption configuration options.
- Added test coverage for replay dedupe suppression, conflict policies, encrypted store round-trip, key-unavailable recovery, and unknown encryption-version handling.
