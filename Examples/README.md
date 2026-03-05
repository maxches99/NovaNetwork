# Examples Reference Cookbook

Runnable and test-backed scenarios for `NovaNetworkClient`.

## Quick Start

Build all examples:

```bash
swift build
```

Run cookbook contract tests:

```bash
swift test --filter NetworkingCoverageTests
```

## Cookbook Scenarios

| Scenario ID | Focus | Example target | Contract test |
|---|---|---|---|
| CB-1 | Coalesced typed read | `NovaNetworkClientJSONPlaceholderExample` | `cookbookScenarioCoalescedRequestUsesSingleTransportCall` |
| CB-2 | Preset composition v2 (`base + overlays`) | `NovaNetworkClientDiagnosticsReferenceExample` | `presetV2CompositionAppliesOverlayOrder` |
| CB-3 | Production validator anti-patterns | `NovaNetworkClientProductionProfileExample` | `presetV2ValidatorFlagsOfflineQueueWithoutStoreAsBlocking` |
| CB-4 | Offline queue onboarding baseline | `NovaNetworkClientOfflineQueueExample` | `enqueueWriteQueuesWhenOfflineAndAppliesDefaultIdempotencyKey` |
| CB-5 | Telemetry onboarding baseline | `NovaNetworkClientDiagnosticsReferenceExample` | `telemetryHooksEmitCoalescerRetryAndCancellationContracts` |
| CB-6 | Production profile generator (DX 2.0) | `NovaNetworkClientProductionProfileExample` | `cookbookScenarioProductionProfileForOfflineFirstRequiresStore` |

## Run Commands

```bash
swift run NovaNetworkClientJSONPlaceholderExample
swift run NovaNetworkClientBatchTodosExample
swift run NovaNetworkClientMiddlewareExample
swift run NovaNetworkClientOfflineQueueExample
swift run NovaNetworkClientWebSocketExample
swift run NovaNetworkClientAuthRefreshReferenceExample
swift run NovaNetworkClientReconnectRecoveryReferenceExample
swift run NovaNetworkClientOfflineReplayReferenceExample
swift run NovaNetworkClientDiagnosticsReferenceExample
swift run NovaNetworkClientProductionProfileExample
```

Optional WebSocket endpoint override:

```bash
NOVA_WS_URL=wss://ws.ifelse.io swift run NovaNetworkClientWebSocketExample
NOVA_WS_URL=wss://ws.ifelse.io swift run NovaNetworkClientReconnectRecoveryReferenceExample
```
