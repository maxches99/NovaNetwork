# What's New in 1.19

## DX 2.0: Presets v2 (`base + overlays`)
- Added composable preset model:
  - `NetworkClientPreset.compose(base:overlays:)`
  - `NetworkClientPresetOverlayKind`
  - `NetworkClientPresetOverlay`
- Overlay application is deterministic and merge-only for request options/runtime policy fields.

## Production Onboarding Improvements
- Added `NetworkClientProductionProfileGenerator` to generate production setup profiles by goal (`restAPI`, `realtime`, `offlineFirst`).
- Added bootstrap snippet generation via `NetworkClientProductionProfile.bootstrapSnippet(...)`.
- Added `NetworkClientPresetValidator` with anti-pattern checks and severity levels:
  - Missing durable offline store with enabled offline queue (blocking).
  - Missing rate-limit/circuit-breaker/deadline guardrails (warnings).
  - Overlay priority conflict hints (warnings).

## Examples -> Reference Cookbook
- Updated `Examples/README.md` to cookbook format with scenario IDs and contract-test mapping.
- Added new runnable onboarding example:
  - `NovaNetworkClientProductionProfileExample`

## Traceability (DFR -> Tests)
- Added DFR: `docs/dfr/DX_2_0_V1_19_DFR.md`
- Added traceability pack: `docs/TRACEABILITY_PACK_v1.19.md`
- Added/updated tests:
  - `presetV2CompositionAppliesOverlayOrder`
  - `presetV2ValidatorFlagsOfflineQueueWithoutStoreAsBlocking`
  - `productionProfileGeneratorBuildsValidatedRealtimeProfile`
  - `cookbookScenarioCoalescedRequestUsesSingleTransportCall`
  - `cookbookScenarioProductionProfileForOfflineFirstRequiresStore`
