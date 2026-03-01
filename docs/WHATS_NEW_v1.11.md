## What's New in v1.11

- Added auth-aware WebSocket recovery with injectable token refresh policy and lifecycle telemetry (`auth_refresh_started/succeeded/failed`).
- Added configurable ACK detection (`WebSocketAckMatcher`) and bounded ACK dedupe TTL controls.
- Added runtime diagnostics snapshot API (`webSocketDiagnostics`) with safe aggregate fields (state, health, reconnect attempt, queue depth, pending ACK count, last error).
- Added connectivity-aware reconnect suppression when offline with explicit resume-on-online state/telemetry.
- Added optional durable outbound queue persistence (`WebSocketOutboundQueueStore`, `DiskWebSocketOutboundQueueStore`) with FIFO replay after reconnect.
- Added partial-corruption recovery for persisted outbound queue: invalid records are skipped, valid records continue replay, and failure telemetry is emitted.
- Added optional subscription replay registry (`registerSubscription` / `unregisterSubscription` / `clearSubscriptions`) with restore start/success/failure telemetry.

### Compatibility
- Public API changes are additive and default-compatible.
- Existing WebSocket callsites continue to compile without migration changes.
