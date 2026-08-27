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
| CB-8 | Record a live exchange, replay it offline | `NovaNetworkClientCassetteExample` | `theFirstRunRecordsAndTheSecondRunIsOffline` |
| CB-9 | Retry waterfall, coalescing, and a HAR export | `NovaNetworkClientDiagnosticsExample` | `theHooksProperyFeedsEveryLifecycleCallbackIntoTheRecorder` |
| CB-10 | OAuth 2.0 with PKCE, shared refresh, and signing | `NovaNetworkClientAuthenticationExample` | `concurrentCallersShareOneRefresh` |
| CB-11 | Shared server state, optimistic rollback, paging | `NovaNetworkClientQueryExample` | `aFailedMutationRestoresExactlyWhatWasThere` |

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
swift run NovaNetworkClientCassetteExample
```

### Record and replay (CB-8)

`Cassette/` records one real request against a public API, prints whether the credential survived
into the file (it does not), then replays the exchange through a transport that throws if it is ever
called — so the second result can only have come from the recording. The first pass needs network
access; every pass after that would work on a plane.
swift run NovaNetworkClientDiagnosticsExample
```

### Diagnostics (CB-9)

`Diagnostics/` runs a scripted transport that fails twice before succeeding, plus two callers
sharing one request, then prints the retry waterfall and the summary and writes a HAR file. The
transport is scripted rather than live so the interesting cases happen every time instead of only on
a bad day.
swift run NovaNetworkClientAuthenticationExample
```

### Authentication (CB-10)

`Authentication/` walks the authorization code flow against a scripted provider: it builds the PKCE
authorization URL, rejects a tampered callback, exchanges the code, then has eight callers need a
token at once and reports how many refreshes the provider actually saw. The answer is one.
swift run NovaNetworkClientQueryExample
```

### Query layer (CB-11)

`Query/` has two screens ask for the same user at the same moment and reports how many requests the
server saw (one), applies an optimistic edit the server rejects and shows it rolling back, then pages
through a list. The subscriber prints every state it renders, including the stale one during a
refresh.

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
