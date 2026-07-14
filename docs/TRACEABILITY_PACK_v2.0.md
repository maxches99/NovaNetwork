# Traceability Pack v2.0

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V2_DFR.md`
- Scope: typed endpoints, concurrency safety, concurrent batching, transfers, HTTP auth refresh,
  modular core, and HTTP Cache 2.0.

## Requirement to implementation mapping

| Requirements | Implementation |
|---|---|
| FR-CONC-1...3 | `NetworkClient.swift`, `NetworkClientEventHubs.swift`, `RequestCoalescer.swift`, strict Swift CI |
| FR-END-1...3 | `Sources/NovaNetworkCore/Endpoint.swift`, `NetworkClient+Endpoint.swift` |
| FR-BATCH-1...4, AR-1 | `BatchTypes.swift`, `NetworkClient+Batch.swift`, `TelemetryHooks.swift` |
| FR-XFER-1...4, AR-2 | `TransferTypes.swift`, `StreamingNetworkTransport.swift`, `Transport+Transfers.swift`, `NetworkClient+Transfers.swift` |
| FR-AUTH-1...4, AR-3 | `HTTPAuthRefresh.swift`, `NetworkClient+HTTPAuthRefresh.swift`, `NetworkError.swift` |
| FR-MOD-1...2 | `Package.swift`, `Sources/NovaNetworkCore`, `NovaNetworkCoreExports.swift` |
| FR-CACHE-1...5, DR-4, AR-4 | cache implementations, `NetworkClient+CacheInternals.swift`, `NetworkClientEvent.swift` |
| NFR-1...6 | CI workflow, SwiftPM manifest, unit/E2E policy gates |

## Requirement to test mapping

| Requirement IDs | Test IDs and executable evidence |
|---|---|
| FR-CONC-1 | T-CONC-1 complete strict-concurrency build |
| FR-CONC-2...3 | T-CONC-2...3 `ConcurrencySafetyTests`, cancellation tests in batch/transfers |
| FR-END-1...3 | T-END-1...3 `EndpointTests` |
| FR-BATCH-1...4, EC-1...2, AR-1 | T-BATCH-1...6 and T-AR-1 `BatchExecutionTests` |
| FR-XFER-1...4, EC-6...7, AR-2 | T-XFER-1...4 and T-AR-2 `TransferTests` |
| FR-AUTH-1...4, EC-4...5, AR-3 | T-AUTH-1...5 `HTTPAuthRefreshTests` |
| FR-MOD-1...2 | T-MOD-1 `NovaNetworkCoreTests`; T-MOD-2 full build/test |
| FR-CACHE-1...5, DR-4, EC-8...10, AR-4 | T-CACHE-1...6 and T-AR-4 `HTTPCacheV2Tests` plus cache regression suites |
| UR-4 | T-DOC-1 DocC audit of new/changed public API |
| NFR-1 | T-GATE-1 combined `NovaNetworkClient` + `NovaNetworkCore` line coverage >= 90% |
| NFR-4 | T-GATE-3 ordered lock-based WebSocket telemetry recorder and 50 repeated Swift 6.3 runs of `connectivityFlapStabilityDoesNotSpawnDuplicateReconnectLoops`; T-GATE-4 scheduler-independent setup for `inFlightTimeoutEvictsHungEntries` plus synchronous lock-backed shared telemetry recording |
| NFR-5 | T-GATE-2 `RUN_E2E_TESTS=1` against public endpoints only |
| NFR-7 | T-E2E-END/BATCH/XFER/AUTH/CACHE in `E2ECoverageTests+V2.swift` |

## Release and rollout

- Release notes: `docs/WHATS_NEW_v2.0.md`.
- Rollout order: opt-in endpoint/batch/transfer/auth APIs, core-module adoption, then cache-policy adoption.
- Existing raw `APIRequest` and umbrella-import paths remain available.
- CI verifies the minimum Swift 6.2 toolchain and current Swift 6.3 compatibility.

## Verified result

- Strict concurrency build: passed.
- `NovaNetworkCore` target build: passed.
- Unit/integration tests: 271 passed.
- Combined line coverage: 92.45%.
- Swift 6.3 telemetry-order stability repetition: 50/50 passed.
- Swift 6.3 timeout setup stability repetition: 100/100 passed; shared policy telemetry ordering: 50/50 passed; full suite stability: 3/3 passed.
- Real-public-API E2E: 31 passed, including all seven v2 network-observable scenarios.
