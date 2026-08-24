# Traceability Pack v2.1

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V2_1_DFR.md`
- Scope: durable managed transfer identity, Range resume, TUS uploads, Apple background URLSession,
  relaunch reconciliation, integrity, transfer policies, telemetry, and Linux Core compatibility.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-TR-1...2, UR-1...3 | `ManagedTransferTypes.swift`, `ManagedTransferCoordinator.swift` |
| FR-TR-3, DR-1...4 | `TransferJournal.swift` |
| FR-TR-4, FR-BG-3, EC-6...7 | `ManagedTransferCoordinator.reconcile`, `BackgroundTransferCoordinator.reconcile` |
| FR-DL-1...3, EC-1...4 | `ManagedTransferManager.swift` Range/If-Range validation and file finalization |
| FR-UP-1...2, EC-10 | `ResumableUploadStrategy.swift`, `TUSResumableUploadStrategy`, managed upload loop |
| FR-BG-1...2, EC-9 | `BackgroundTransferCoordinator.swift` and its URLSession delegate bridge |
| FR-INT-1, EC-5 | streaming `SHA256Util`, foreground/background integrity and staging logic |
| FR-POL-1 | `TransferNetworkPolicy`, request/configuration/task mapping |
| AR-1...4 | `TelemetryManagedTransferContext`, `NetworkTelemetryHooks`, coordinator emission, `OpenTelemetryAdapter` |
| NFR-2...5, NFR-7 | `Package.swift`, strict build, bounded buffers/chunks, actor isolation, Linux CI job |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-TR-1...3 | FR-TR-1...2, UR-2, EC-8 | unit | `NovaNetworkCoreTests`, `ManagedTransferInfrastructureTests` |
| T-STORE-1...4, T-SEC-1 | FR-TR-3, DR-1...4, EC-7 | unit/integration | `ManagedTransferInfrastructureTests` journal tests |
| T-RESTORE-1...3 | FR-TR-4, FR-BG-3, EC-6 | integration | coordinator restore/reconciliation tests |
| T-DL-1...6 | FR-DL-1...3, EC-1...4 | integration | `ManagedTransferProtocolTests` Range protocol tests |
| T-UP-1...5 | FR-UP-1...2, EC-10 | integration | `ManagedTransferProtocolTests` TUS tests |
| T-BG-1...4 | FR-BG-1...3, EC-9 | integration | `BackgroundTransferCoordinatorTests` |
| T-INT-1...3 | FR-INT-1, EC-5 | unit/integration | foreground and background integrity tests |
| T-POL-1...3 | FR-POL-1 | unit | request/configuration policy mapping test |
| T-AR-1...4 | AR-1...4 | unit/integration | telemetry lifecycle, payload, and false-success tests |
| E2E-DL-1 | FR-DL-1...3, NFR-6 | e2e | HTTPBingo `/range/1024` resume and integrity |
| E2E-UP-1 | FR-UP-2, NFR-6 | e2e | official `tusd.tusdemo.net` interrupted/resumed upload |
| E2E-BG-1 | FR-BG-1, NFR-6 | e2e | macOS background URLSession to HTTPBingo |
| T-GATE-1...6 | NFR-1...7 | CI/release | coverage, strict concurrency, Linux Core, public-E2E policy |

## Security and data contract

- Journal snapshots contain request URL/method, file/checkpoint metadata, and non-secret OS task
  identity only.
- Authorization, Cookie, Proxy-Authorization, arbitrary request headers, and response bodies are
  not represented in the persistence model.
- Telemetry contains stable IDs, kind, byte counts, offsets, non-secret task/session identifiers,
  and enumerated sanitized reasons only.

## Rollout and rollback

- Feature flag: none; every 2.1 API is opt-in and 2.0 APIs remain available.
- Initial release: `2.1.0-rc.1`, followed by host-app background smoke and two consecutive green
  post-merge CI runs before stable `2.1.0`.
- Roll back to 2.0.x on corruption, duplicate terminal delivery, credential persistence, identity
  mismatch, or coverage/concurrency regression. Preserve journals for a compatible 2.1 patch.

## Final verification result

An initial pre-commit pass was recorded on 2026-07-15, before this work was actually committed.
Before committing, a fresh audit on 2026-08-24 (Apple Swift 6.3.3) found that two of that pass's
claims did not hold up under re-verification -- coverage was not actually above 90% by the
methodology CI's gate uses, and re-reading the transfer/journal implementation surfaced two real
correctness bugs. Both are fixed; see the Definition of Done audit note in the DFR
(`docs/dfr/NOVA_NETWORK_V2_1_DFR.md`) for what was found. The table below reflects the state
actually verified at commit time, not the earlier July pass.

| Gate | Result | Evidence |
|---|---|---|
| Complete strict-concurrency build | pass | `swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency`, current (Swift 6.3) lane only -- minimum lane is CI-only, see below |
| Unit/integration suite | pass | 451 tests, 39 suites, 0 failures; reran 3x clean |
| Unit line coverage (CI gate methodology) | pass | 90.13% -- 12,985 executable lines in `Sources/NovaNetworkClient` + `Sources/NovaNetworkCore`, 1,281 uncovered; computed with the exact `xcrun llvm-cov report` invocation `.github/workflows/ci.yml`'s coverage gate runs, under `bash` (not the interactive shell) since the gate's unquoted `${SOURCE_FILES}` expansion is shell-dependent |
| Real-public-API E2E | pass | 34 tests, including Range resume, TUS resume, and a real macOS background transfer, all against live `httpbingo.org`/`tusd.tusdemo.net` |
| E2E transport policy scan | pass | no mock, stub, fake transport, or example-domain endpoint in the E2E tree |
| Public API DocC audit | pass | every `public`/`open` declaration added under `Networking/Transfers/` and in `ManagedTransferTypes.swift` has a `///` comment, including ones preceded by `@discardableResult` |
| Dependency audit | pass | no third-party package dependency added |
| Diff hygiene | pass | `git diff --check` reports no whitespace errors; new untracked files independently checked for trailing whitespace |
| Swift 6.2.3 macOS/Linux lanes | pending CI | configured in `.github/workflows/ci.yml`; this toolchain only has Swift 6.3.3 installed, so these lanes are not claimed as locally executed |
| Release-candidate soak | pending post-merge | requires two consecutive green CI runs before the stable tag |

The local implementation gates are green as of this commit. The unchecked DFR items are limited to
remote minimum-toolchain/Linux execution and the post-merge release-candidate soak, neither of
which is achievable outside CI.
