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

### Managed transfer events (2.1 additive mapping)

`onManagedTransferEvent` maps to `managed_transfer.<event>` and includes only credential-free
attributes:

- `transfer_id`, `kind`, and `event`;
- optional `completed_bytes`, `total_bytes`, and `offset`;
- optional background `session_identifier` and `task_identifier`;
- an optional sanitized `reason` code.

Lifecycle values include `started`, `suspended`, `resumed`, `restored`, `progress`, `completed`,
`failed`, `cancelled`, resume decisions, and background scheduling/reconciliation/handoff. Request
headers, cookies, authorization values, and response bodies are never mapped into this payload.

### Adaptive concurrency limit (3.2 additive mapping)

`onConcurrencyLimitChanged` maps to `sdk.concurrency.limit` and carries only numbers and a reason
code:

- `limit` and `previous_limit`;
- `reason`, one of `congestion`, `latency`, `headroom`.

It fires only when the limit actually moves, not on every request, so its volume is bounded by how
often the server's capacity changes rather than by traffic. No URL, header, or body is mapped.

### Pipeline metric
- `offlineQueuePipelineMetrics().ageDistribution.p95Seconds` -> `sdk.queue.age.p95.ms`
- Conversion: `seconds * 1000`.

## Compatibility
- Contract v1 style hooks remain available.
- Contract v2 is additive and delivered through `OpenTelemetryAdapter` and payload structs.
- The 2.1 managed-transfer mapping is additive and does not change existing event names.
- `OfflineQueueAgeDistribution` now includes `p95Seconds` (initializer remains backward-compatible).
- The 3.2 adaptive-concurrency hook is additive; `NetworkTelemetryHooks` gains one optional closure
  with a default, and clients that do not set it are unaffected.

## Golden Validation
Contract schema is protected by golden tests in:

- `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+ObservabilityContractV2.swift`

Covered golden payloads:

- retry exhausted event payload
- websocket reconnect success event payload
- offline replay success event payload
- queue age p95 metric payload
