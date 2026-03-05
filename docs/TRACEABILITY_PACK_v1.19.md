# Traceability Pack v1.19 (DX 2.0)

## DFR
- `docs/dfr/DX_2_0_V1_19_DFR.md`

## Requirement -> Code Mapping
| Requirement ID | Code references |
|---|---|
| FR-1 | `Sources/NovaNetworkClient/Networking/Client/NetworkClientPresetDX.swift` (`NetworkClientPresetComposer`, `NetworkClientPreset.compose`) |
| FR-2 | `Sources/NovaNetworkClient/Networking/Client/NetworkClientPresetDX.swift` (`NetworkClientPresetValidator`, validation report models) |
| FR-3 | `Sources/NovaNetworkClient/Networking/Client/NetworkClientPresetDX.swift` (`NetworkClientProductionProfileGenerator`, `NetworkClientProductionProfile`) |
| FR-4 | `Examples/README.md`, `Examples/ProductionProfile/ProductionProfileExample.swift`, `Package.swift` |
| UR-1 | `NetworkClientProductionProfile.bootstrapSnippet` |
| UR-2 | `NetworkClientPresetValidationIssue` |
| AR-1 | `AP-OFFLINE-001` validator rule |

## Requirement -> Test Mapping
| Requirement ID | Test ID | File |
|---|---|---|
| FR-1 | T-19.1 `presetV2CompositionAppliesOverlayOrder` | `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+Presets.swift` |
| FR-2 | T-19.2 `presetV2ValidatorFlagsOfflineQueueWithoutStoreAsBlocking` | `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+Presets.swift` |
| FR-3 | T-19.3 `productionProfileGeneratorBuildsValidatedRealtimeProfile` | `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+Presets.swift` |
| FR-4 | T-19.4 `cookbookScenarioCoalescedRequestUsesSingleTransportCall` | `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+ReferenceCookbook.swift` |
| AR-1 | T-19.5 `cookbookScenarioProductionProfileForOfflineFirstRequiresStore` | `Tests/NovaNetworkClientTests/Unit/Networking/NetworkingCoverageTests+ReferenceCookbook.swift` |

## Coverage and Validation
- Unit tests: run `swift test`
- Coverage gate: run `swift test --enable-code-coverage`
- E2E gate: run `RUN_E2E_TESTS=1 swift test --filter E2ECoverageTests`
