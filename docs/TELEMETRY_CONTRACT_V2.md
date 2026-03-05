# Telemetry Contract v2 (v1.17)

## Schema Envelope
Every Contract v2 telemetry payload carries top-level version fields:

- `event_version` (Int): event schema version. Current value: `2`.
- `contract_version` (String): cross-event contract bundle version. Current value: `"2.0"`.

These fields are present in both event and metric payloads emitted by `OpenTelemetryAdapter`.

## Payload Types

### Event payload (`TelemetryEventPayload`)

```json
{
  "event_name": "network.retry_exhausted",
  "event_version": 2,
  "contract_version": "2.0",
  "attributes": {
    "reason": "http_status_503"
  }
}
```

### Metric payload (`TelemetryMetricPayload`)

```json
{
  "metric_name": "sdk.retry.exhausted",
  "kind": "counter",
  "value": 1,
  "event_version": 2,
  "contract_version": "2.0",
  "attributes": {
    "coalescing_mode": "default"
  }
}
```

## SLO Metrics (SDK)
The SDK now defines stable SLO metric names:

- `sdk.retry.exhausted` (`counter`)
- `sdk.reconnect.success` (`counter`)
- `sdk.replay.success` (`counter`)
- `sdk.queue.age.p95.ms` (`gauge`, milliseconds)

## Mapping Rules

### Hook-driven metrics
- `onRetryExhausted` -> `sdk.retry.exhausted`
- `onWebSocketEvent` with `type == reconnect_success` -> `sdk.reconnect.success`
- `onOfflineQueueEvent` with `type == replaySucceeded` -> `sdk.replay.success`

### Pipeline metric
- `offlineQueuePipelineMetrics().ageDistribution.p95Seconds` -> `sdk.queue.age.p95.ms`
- Conversion: `seconds * 1000`.

## Compatibility
- Contract v1 style hooks remain available.
- Contract v2 is additive and delivered through `OpenTelemetryAdapter` and payload structs.
- `OfflineQueueAgeDistribution` now includes `p95Seconds` (initializer remains backward-compatible).

## Golden Validation
Contract schema is protected by golden tests in:

- `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+ObservabilityContractV2.swift`

Covered golden payloads:

- retry exhausted event payload
- websocket reconnect success event payload
- offline replay success event payload
- queue age p95 metric payload
