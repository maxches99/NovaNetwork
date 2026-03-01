## What's New in v1.9

- Added initial WebSocket support with `WebSocketClient` and `WebSocketConfiguration`.
- Added typed realtime contracts: `WebSocketMessage`, `WebSocketConnectionState`, and `WebSocketError`.
- Added async streams for connection state observation and inbound message consumption.
- Added base lifecycle operations for realtime connections: `connect`, `send`, and `disconnect`.
- Added automatic reconnect flow with capped exponential backoff and jitter controls.
- Added heartbeat policy (`ping/pong`) with timeout-based stale connection detection.
- Added reconnect state transitions and terminal reconnect exhaustion handling (`.reconnectExhausted`).
- Added WebSocket telemetry hook support via `NetworkTelemetryHooks.onWebSocketEvent`.
- Added unit and E2E coverage for reconnect recovery, reconnect exhaustion, heartbeat timeout, and telemetry payload contracts.
