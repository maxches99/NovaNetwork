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
| CB-7 | Endpoints generated from an OpenAPI document | `NovaNetworkClientOpenAPIPetstoreExample` | `theCheckedInGeneratedFileMatchesWhatTheGeneratorProducesNow` |

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
swift run NovaNetworkClientOpenAPIPetstoreExample
```

### OpenAPI generation (CB-7)

`OpenAPIPetstore/` holds a specification, the checked-in Swift the generator produced from it, and a
program that builds requests with those types. The generated file lives in its own target that
depends on `NovaNetworkCore` alone, so "generated code needs neither the `@Endpoint` macro nor its
package trait" is enforced by the build rather than asserted in prose.

Regenerate it after editing the spec:

```bash
swift run nova-openapi \
  --spec Examples/OpenAPIPetstore/petstore.yaml \
  --output Examples/OpenAPIPetstore/Generated/GeneratedPetstoreAPI.swift
```

In your own package, the command plugin does the same thing:

```bash
swift package --allow-writing-to-package-directory nova-openapi \
  --spec openapi.yaml --output Sources/MyApp/GeneratedEndpoints.swift
```

Optional WebSocket endpoint override:

```bash
NOVA_WS_URL=wss://ws.ifelse.io swift run NovaNetworkClientWebSocketExample
NOVA_WS_URL=wss://ws.ifelse.io swift run NovaNetworkClientReconnectRecoveryReferenceExample
```
