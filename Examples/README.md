# Examples

Runnable examples for `NovaNetworkClient`.

## JSONPlaceholder Coalescing

Uses the public API [https://jsonplaceholder.typicode.com](https://jsonplaceholder.typicode.com) to show:
- typed decoding;
- request coalescing for identical concurrent requests.

Run:

```bash
swift run NovaNetworkClientJSONPlaceholderExample
```

## Batch Loading

Shows `loadBatch` with several JSONPlaceholder endpoints and typed decoding.

Run:

```bash
swift run NovaNetworkClientBatchTodosExample
```

## Middleware

Shows request middleware (`beforeSend`) by injecting custom headers and validating them via [https://httpbin.org/anything](https://httpbin.org/anything).

Run:

```bash
swift run NovaNetworkClientMiddlewareExample
```

## Offline Queue

Shows `enqueueWrite` with durable `DiskOfflineWriteStore` and queue depth inspection.

Run:

```bash
swift run NovaNetworkClientOfflineQueueExample
```

## WebSocket

Shows realtime connect/send/receive over a public echo endpoint (`wss://ws.postman-echo.com/raw`) with state observation.

Run:

```bash
swift run NovaNetworkClientWebSocketExample
```

Optional endpoint override:

```bash
NOVA_WS_URL=wss://ws.ifelse.io swift run NovaNetworkClientWebSocketExample
```

## Reference: Auth Refresh

Shows a reference app flow where an expired bearer token gets a `401`, refreshes token state, and retries with `NetworkClientPreset.restHeavy`.

Run:

```bash
swift run NovaNetworkClientAuthRefreshReferenceExample
```

## Reference: Reconnect Recovery

Shows a reference app flow for WebSocket reconnect recovery with queue pressure diagnostics and telemetry stream output.

Run:

```bash
swift run NovaNetworkClientReconnectRecoveryReferenceExample
```

Optional endpoint override:

```bash
NOVA_WS_URL=wss://ws.ifelse.io swift run NovaNetworkClientReconnectRecoveryReferenceExample
```

## Reference: Offline Replay

Shows `NetworkClientPreset.offlineFirst` with durable writes and replay/metrics inspection.

Run:

```bash
swift run NovaNetworkClientOfflineReplayReferenceExample
```

## Reference: Observability and Diagnostics

Shows request event stream + telemetry hooks + runtime policy update events as a diagnostics baseline.

Run:

```bash
swift run NovaNetworkClientDiagnosticsReferenceExample
```
