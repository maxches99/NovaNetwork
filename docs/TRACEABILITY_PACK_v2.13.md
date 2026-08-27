# Traceability Pack v2.13

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V2_13_DFR.md`
- Scope: the diagnostics recorder and its record model, bounded storage and capture policies,
  redaction, the summary, HAR 1.2 export, `os_signpost` intervals, and the SwiftUI panel.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-1, FR-2, FR-3, FR-4, EC-1, EC-2 | `Sources/NovaNetworkDiagnostics/DiagnosticsRecorder.swift` |
| FR-5, FR-6, DR-3, EC-3, EC-4 | `DiagnosticsOptions.swift` (`capacity`, `BodyCapturePolicy`) |
| FR-7 | `DiagnosticsSummary.swift` |
| FR-8, UR-4, EC-5, EC-6 | `HARExporter.swift` |
| FR-9, DR-2 | `DiagnosticsOptions.swift` (`DiagnosticsRedaction`), applied in the recorder |
| FR-10, EC-7 | `DiagnosticsSignposter.swift` |
| FR-11, UR-2 | `DiagnosticsPanelState.swift`, `NetworkDiagnosticsView.swift` |
| FR-12, NFR-2 | `Package.swift`, `#if canImport(SwiftUI)`, Linux CI gate |
| UR-1 | `hooks` and `startConsuming(_:)`, shown in `Examples/Diagnostics` |
| UR-3 | DocC comments on every public symbol, `Diagnostics.md` |
| AR-1, DR-1 | no telemetry emitted, nothing persisted, client untouched |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-1.1…T-1.5 | FR-1…FR-4, EC-1, EC-2 | unit | `DiagnosticsRecorderTests` |
| T-2.2…T-2.5 | FR-5, FR-6, EC-3, EC-4, EC-8 | unit | `DiagnosticsRecorderTests`, `BodyCapturePolicyTests` |
| T-3.1 | FR-7 | unit | `DiagnosticsSummaryTests` |
| T-4.1…T-4.3 | FR-8, UR-4, EC-5, EC-6 | unit | `HARExportTests`, `HARRequestBodyTests` |
| T-5.1 | FR-9, DR-2 | unit | `DiagnosticsRedactionTests` |
| T-6.1 | FR-10, EC-7 | unit | `DiagnosticsSignposterTests`, `SignpostEmissionTests` |
| T-7.1 | FR-11, UR-2 | unit | `DiagnosticsPanelStateTests` |
| T-8.1 | AR-1 | integration | `DiagnosticsClientIntegrationTests` |
| — | FR-1 (hook surface) | unit | `DiagnosticsInstallationTests` |
| T-1.6 | FR-1…FR-4, EC-1b (order independence) | unit | `DiagnosticsOrderIndependenceTests` |
| T-GATE-1…4 | NFR-1…NFR-4 | CI | zero-dependency check, coverage gate, Linux gate, API breakage gate |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `Sources/NovaNetworkDiagnostics`, excluding the SwiftUI view | 97.23% |
| `NetworkDiagnosticsView.swift` | 0% — excluded from the gate, see below |

`NetworkDiagnosticsView.swift` is excluded from the coverage gate because a SwiftUI view is not
executed by unit tests. The exclusion is stated in `.github/workflows/ci.yml` next to the `find`
that applies it, and the view is deliberately logic-free: everything it renders is computed by
`DiagnosticsPanelState`, which is covered at 96.77%.

## Security and data contract

- Redaction runs as a record is built, before retention, and is asserted by searching an exported
  HAR for the credential.
- The default header set matches `CassetteRedaction.default`, verified by a test that names each
  header. The duplication is deliberate for now: sharing the list would couple two independent
  products, and unifying them is follow-up work.
- Nothing is persisted by the recorder; a HAR exists only where the caller writes it.

## Verification gaps

- The SwiftUI panel is compiled but never rendered in tests; there is no host app in this package.
- Signpost emission is exercised for both enabled and disabled paths, but the resulting Instruments
  trace is not asserted — only that recording behaves identically either way.
- The example target is built in CI, not executed.
