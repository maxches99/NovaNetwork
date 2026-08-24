# What's New in 2.1

## Reliable managed transfers

- Added stable `TransferID`, immutable snapshots, typed lifecycle states, bounded event streams,
  cancellation handles, and exactly-once terminal delivery.
- Added a versioned per-transfer `DiskTransferJournal` with atomic writes, partial recovery, and
  explicit orphan/corruption diagnostics.
- Request headers and credentials are excluded from persisted snapshots; restored work requires a
  fresh live `APIRequest`.

## Resumable downloads

- Added HTTP Range resume with validator-aware `If-Range` requests.
- Valid `206 Content-Range` responses append to private partial files; ignored ranges (`200`) and
  failed preconditions (`412`) restart safely without duplicating bytes.
- Invalid ranges fail with typed errors and never publish a destination file.
- Optional final byte-count and streaming SHA-256 verification runs before atomic finalization.

## Resumable uploads

- Added the pluggable `ResumableUploadStrategy` contract.
- Added a built-in TUS 1.0 strategy using create (`POST`), offset discovery (`HEAD`), and bounded
  chunk append (`PATCH`).
- Server-confirmed upload URLs and offsets are journaled; upload credentials remain memory-only.

## Apple background transfers

- Added `BackgroundTransferCoordinator` for real file-backed background uploads and downloads on
  iOS and macOS.
- Stable transfer IDs are attached to URLSession tasks and reconciled one-to-one after relaunch.
- Added private download staging, integrity validation, atomic destination handling, network path
  policies, task priorities, and a once-only host lifecycle completion bridge.
- Host applications still own capabilities, entitlements, and background callback forwarding.

## Observability and portability

- Added credential-free managed lifecycle, resume-decision, restoration, background, progress,
  completion, failure, and cancellation telemetry.
- Added OpenTelemetry event mapping under `managed_transfer.<event>` with negative-path tests that
  prevent false completion events.
- Added an Ubuntu Swift 6.2.3 CI lane for strict `NovaNetworkCore` compilation.

## Verification

- Added deterministic protocol tests for Range/If-Range, safe restart, journal recovery, TUS
  offsets/chunking, integrity failures, reconciliation, background finalization, lifecycle handoff,
  network policies, and telemetry.
- Added real-public-API E2E against HTTPBingo Range, the official TUS demo service, and a real
  macOS background URLSession download. No E2E mocks, stubs, or fake transports are used.

## Migration notes

- All 2.1 APIs are additive; the 2.0 foreground stream/upload/download APIs remain unchanged.
- Persisted schema v1 is the first managed-transfer schema. Unknown future schema versions are
  isolated and reported rather than interpreted; future migrations must add an explicit migrator.
- Use an app-private directory for journals, partial downloads, and background staging.
- Re-supply authentication after restoration and use TLS for upload resource URLs.

## Licensing

- Relicensed from GPL-3.0 to the Apache License, Version 2.0, so the package can be adopted in
  closed-source applications. There is a single copyright holder and no prior external
  contributions, so no contributor consent was required.
