# What's New in v1.15

## DX Presets for Faster Adoption
- Added `NetworkClientPreset` with three production-oriented profiles:
  - `restHeavy`
  - `realtimeHeavy`
  - `offlineFirst`
- Each preset now defines:
  - safe default policy values (`retry`, `cache`, runtime policy, request options),
  - explicit tradeoffs,
  - merge-safe override points via `NetworkClientPreset.RequestOverrides`.

## Runtime Policy Bootstrap Helper
- Added `NetworkClient.applyRuntimePolicy(from:scope:)` to apply preset runtime policies with existing runtime update mechanics and telemetry.

## Reference App Scenarios in `Examples/`
- Added runnable reference examples for adoption-critical workflows:
  - `AuthRefreshReference` (401 -> refresh -> retry),
  - `ReconnectRecoveryReference` (WebSocket recovery + diagnostics),
  - `OfflineReplayReference` (enqueue/replay/metrics),
  - `DiagnosticsReference` (events + telemetry hooks + runtime updates).

## Traceability Pack (DFR -> Tests -> Telemetry)
- Added dedicated traceability mapping document for capability-level implementation/tests/telemetry:
  - `docs/TRACEABILITY_PACK_v1.15.md`

## Tests and Docs
- Added unit coverage for preset contracts and runtime policy telemetry emission.
- Updated `README.md` and `Examples/README.md` with preset and reference-flow onboarding.
