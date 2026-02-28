## What's New in v1.10

- Improved WebSocket auto-reconnect behavior with capped exponential backoff, jitter, and clearer recoverable/non-recoverable handling.
- Added stale connection detection hardening with heartbeat-driven unhealthy transition and controlled reconnect flow.
- Added optional ack-aware outbound delivery contract using `messageId`, including timeout handling and reconnect resend semantics.
- Added offline outbound queue policy controls (`dropOldest`, `dropNewest`, `failFast`) with bounded queue limits.
- Expanded socket telemetry hooks for reconnect attempts/outcomes, queueing/drop events, and ack timeouts with correlation identifiers.
- Added DFR and test-matrix traceability for socket reliability requirements targeted for v1.10.
