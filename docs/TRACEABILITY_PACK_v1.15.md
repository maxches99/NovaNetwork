# v1.15 Traceability Pack (DFR -> Tests -> Telemetry)

## Capability: Preset-based Bootstrap
- Code:
  - `Sources/NovaNetworkClient/Networking/NetworkClientPreset.swift`
- Tests:
  - `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+Presets.swift::presetsExposeSafeDefaultsAndTradeoffs`
- Telemetry contract:
  - Indirect (startup config). No direct telemetry required at selection time.

## Capability: Safe Override Points
- Code:
  - `NetworkClientPreset.RequestOverrides`
  - `NetworkClientPreset.requestOptions(overrides:)`
- Tests:
  - `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+Presets.swift::presetRequestOverridesMergeWithoutDroppingSafetyDefaults`
- Telemetry contract:
  - Uses existing request telemetry hooks; override application must not suppress request events.

## Capability: Runtime Policy Application From Preset
- Code:
  - `NetworkClient.applyRuntimePolicy(from:scope:)`
- Tests:
  - `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+Presets.swift::applyRuntimePolicyFromPresetEmitsPolicyUpdateTelemetry`
- Telemetry contract:
  - Event: `onPolicyUpdated`
  - Required fields: `source=runtime_update`, `scope`, `changedFields`

## Capability: Auth Refresh Reference Flow
- Example:
  - `Examples/AuthRefreshReference/AuthRefreshReferenceExample.swift`
- Telemetry hooks to validate in integrator apps:
  - `onRequestStart`, `onRequestEnd`, `onRetryScheduled`

## Capability: Reconnect Recovery Reference Flow
- Example:
  - `Examples/ReconnectRecoveryReference/ReconnectRecoveryReferenceExample.swift`
- Telemetry hooks to validate in integrator apps:
  - `onWebSocketEvent` (`reconnect_attempt`, `reconnect_success`, `reconnect_failed`)

## Capability: Offline Replay Reference Flow
- Example:
  - `Examples/OfflineReplayReference/OfflineReplayReferenceExample.swift`
- Telemetry hooks to validate in integrator apps:
  - `onOfflineQueueEvent` (`enqueued`, `replayStarted`, `replaySucceeded`, `replayFailed`)

## Capability: Observability/Diagnostics Reference Flow
- Example:
  - `Examples/DiagnosticsReference/DiagnosticsReferenceExample.swift`
- Telemetry hooks to validate in integrator apps:
  - `onRequestStart`, `onRequestEnd`, `onPolicyUpdated`
