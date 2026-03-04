# What's New in 1.18

## Durability & Chaos Hardening
- Hardened `DiskOfflineWriteStore` crash consistency with staged temporary writes and commit-step replacement.
- Added recovery cleanup of orphaned temporary files (`.json.partial`) to keep restart scans deterministic.
- Added corruption budget guardrails: when corruption exceeds safety thresholds, replay set is blocked (fail-closed) and surfaced via recovery metrics.

## Recovery-Loss Metrics
- Expanded `OfflineStoreRecoveryReport` with:
  - `orphanedTemporaryRecords`
  - `corruptionBudgetExceeded`
  - `recoveryLossRate`
- Existing recovery-loss telemetry flow remains compatible and now includes orphaned-temp loss via total skipped records.

## Deterministic Chaos Coverage
- Added deterministic fault-injection tests for:
  - injected I/O write errors,
  - partial-write crash windows,
  - corruption-budget fail-closed behavior,
  - clock-skew TTL safety,
  - connectivity flap auto-flush stability.

## Stress Baseline Expansion
- Added combined offline+realtime stress scenario to benchmark suite.
- Added baseline gates for combined scenario replay throughput, realtime success floor, p99 latency, and transport call ceilings.

## Traceability
- Coverage additions:
  - `Tests/NovaNetworkClientTests/OfflineQueueCoverageTests.swift`
  - `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+OfflineQueue.swift`
