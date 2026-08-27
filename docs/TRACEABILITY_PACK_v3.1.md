# Traceability Pack v3.1

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_1_DFR.md`
- Scope: the shared-clock timeline model and its panel mode, the HAR reader, loading records into a
  recorder, and the macOS inspector that puts those three together.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-13, FR-18, EC-9…EC-12 | `Sources/NovaNetworkDiagnostics/DiagnosticsTimeline.swift` |
| FR-14 | `DiagnosticsTimeline.swift` (`tickSteps`, `ticks(across:)`) |
| FR-13 (span rule), NFR-5 | `DiagnosticsPanelState.intervals(for:endingAt:)`, `milliseconds(from:to:)` |
| FR-15, EC-13…EC-16 | `Sources/NovaNetworkDiagnostics/HARImporter.swift` |
| FR-16, DR-5 | `HARImporter.swift` (`Notes`), paired with `HARExporter.comment(for:)` |
| FR-17 | `DiagnosticsRecorder.load(_:)` |
| UR-5, UR-6 | `NetworkDiagnosticsView.swift` (`Mode`, `requestTimeline`, `laneRow`) |
| UR-7, UR-8, DR-4 | `Inspector/NovaNetworkInspector/InspectorModel.swift`, `InspectorView.swift` |
| NFR-6 | additive public API only; no existing symbol changed |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-9.1…T-9.5 | EC-9…EC-11, FR-13 | unit | `DiagnosticsTimelineTests` |
| T-9.6…T-9.8 | FR-13, UR-5 | unit | `DiagnosticsTimelineTests` |
| T-9.9 | FR-18, EC-12 | unit | `DiagnosticsTimelineTests` |
| T-9.10, T-9.11 | FR-14 | unit | `DiagnosticsTimelineTests` |
| T-10.1…T-10.5 | FR-16 | unit | `HARImportTests` |
| T-10.6…T-10.9 | FR-15, EC-13…EC-16 | unit | `HARImportTests` |
| T-10.10, T-10.11 | FR-17 | unit | `RecorderLoadingTests` |
| T-UI-4 | UR-5, UR-6 | UI | `DiagnosticsPanelUITests.testTheTimelinePutsEveryRequestOnOneClock` |
| T-GATE-5 | UR-7, UR-8 | CI | `macos-inspector` job builds the app |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `DiagnosticsTimeline.swift` | covered by 12 tests; every branch of the ruler and the window |
| `HARImporter.swift` | covered by 10 tests, including three foreign-producer shapes |
| `NetworkDiagnosticsView.swift` | excluded from the gate; covered by the demo app's UI tests |

## Verification gaps

- The timeline is asserted as a layout, not as pixels. The UI test proves lanes and a ruler render
  and that the mode switch works; it does not assert bar geometry on screen.
- The macOS inspector is built in CI, not driven. It was opened by hand against a HAR produced from
  real `httpbin.org` traffic, and that is the extent of its verification.
- HAR reading is tested against files this package writes and three hand-written foreign shapes, not
  against a corpus from real tools.
- Zoom, scrub, and range selection are not implemented, so nothing tests them.
