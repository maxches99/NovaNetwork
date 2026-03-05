# What's New in v1.17

## Customer Impact
- Added Observability Contract v2 with explicit payload versioning fields.
- Added ready-to-use OpenTelemetry adapter layer without imposing OpenTelemetry dependency in core.
- Added stable SDK SLO metrics for retry, reconnect, replay, and offline queue age p95.

## Changes
- Added `TelemetryContractVersion`, `TelemetryEventPayload`, `TelemetryMetricPayload`, and `TelemetrySLOMetricName`.
- Added `OpenTelemetryExporting` protocol and `OpenTelemetryAdapter` mapping from `NetworkTelemetryHooks` to versioned event/metric payloads.
- Extended `OfflineQueueAgeDistribution` with `p95Seconds` and populated it in `offlineQueuePipelineMetrics()`.
- Added golden tests for payload schema and adapter SLO-metric emission behavior.
- Added contract docs: `docs/TELEMETRY_CONTRACT_V2.md`.

## Notes for Support/Ops
- Feature flag: none
- Rollout segments: all SDK users on v1.17
- Monitoring signals (logs/metrics/events):
  - `sdk.retry.exhausted`
  - `sdk.reconnect.success`
  - `sdk.replay.success`
  - `sdk.queue.age.p95.ms`
- Known limitations:
  - OpenTelemetry concrete instrumentation wiring remains in app target.

## Rollback
- Conditions to rollback:
  - Contract v2 payload incompatibility in downstream pipelines.
- Rollback steps:
  - Revert to previous release and consume legacy `telemetryHooks` directly.

## Source Traceability
- DFR: Confluence (internal)
- Requirement IDs: FR-1, FR-2, FR-3, DR-1, DR-2, AR-1, AR-2, AR-3, AR-4, NFR-1, NFR-2
