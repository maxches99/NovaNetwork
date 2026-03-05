# What's New in v1.16

## Architecture Split (Internal)
- Refactored `NetworkClient` into clearer internal boundaries:
  - orchestrator (`NetworkClient`),
  - HTTP execution pipeline (`NetworkClientHTTPExecutionPipeline`),
  - offline replay coordinator (`NetworkClientOfflineReplayCoordinating`).
- Refactored `WebSocketClient` into internal manager boundaries:
  - connection manager,
  - ACK manager,
  - outbound queue manager.

## Testability and Coupling Improvements
- Added explicit internal protocol boundaries for core runtime concerns to reduce coupling and improve targeted testing.
- Preserved all existing public API surface and source compatibility.

## Quality Gates
- `swift build` and `swift test` are green.
- E2E suite is green with real APIs: `RUN_E2E_TESTS=1 swift test --filter E2ECoverageTests`.
- Benchmark baseline check passes: `swift run NovaNetworkClientBenchmarks --check-baseline`.

## Notes for Integrators
- No migration required.
- No public API changes in this release.
