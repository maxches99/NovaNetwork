# NovaNetworkClient 2.0 DFR

## 1. Metadata

- Feature name: NovaNetworkClient 2.0 — Typed APIs, Safe Concurrency, Transfers, Auth, Modular Core, and HTTP Cache 2.0
- Owner: NovaNetworkClient maintainers
- Stakeholders: Product, Swift library consumers, Engineering, QA, Support/Ops
- Status: `Implemented and verified`
- Approval source: user-directed implementation scope on 2026-07-13
- Target version/build: 2.0.0
- Related links:
  - API contract: this DFR and generated DocC
  - Test matrix: section 8
  - Release notes: `docs/WHATS_NEW_v2.0.md`
  - Traceability: `docs/TRACEABILITY_PACK_v2.0.md`

## 2. Goal and Scope

### Goal

Evolve NovaNetworkClient into a safer and more ergonomic Swift 6 networking library by providing typed endpoints, bounded concurrent batches, native transfer APIs, single-flight authentication refresh, a cross-platform core module, and more complete HTTP caching while retaining the existing `NovaNetworkClient` umbrella API.

### Non-goals

- Replacing URLSession with a third-party HTTP engine.
- Adding GraphQL, gRPC, REST code generation, or macro-based endpoint generation.
- Providing UI components for progress, authentication, or errors.
- Guaranteeing Android, Linux, or Windows support for the full URLSession client in 2.0; only `NovaNetworkCore` is required to be cross-platform.
- Breaking or removing existing public APIs.
- Implementing background execution entitlements owned by host applications.

### Definition of Done

- [x] DFR created with requirements, state flows, risks, analytics, and test mapping.
- [x] Code implemented for all MVP requirements.
- [x] Unit/integration tests added and passing.
- [x] Analytics contracts implemented and negative paths verified.
- [x] Public API has complete DocC coverage for new/changed declarations.
- [x] Existing umbrella import remains source-compatible.
- [x] `swift build` and `swift test` pass.
- [x] Unit line coverage remains above 90%.
- [x] E2E tests pass against real public APIs with `RUN_E2E_TESTS=1`.
- [x] New endpoint, batch, streaming, upload, download, auth refresh, and cache revalidation
  flows have real-public-API E2E coverage without mock or stub transports.
- [x] `README.md`, traceability pack, and `WHATS_NEW_v2.0.md` are updated.
- [x] Rollout and rollback plans are documented.

### MVP / V1 / Nice-to-have

- MVP: all FR/NFR/EC requirements marked in this document.
- V1: Swift 6.3 stable compatibility CI lane.
- Nice-to-have: nightly Swift compatibility canary, macros, background task scheduler integration,
  resumable uploads, and a full cross-platform HTTP transport.

## 3. User Value

### User problem

Consumers currently assemble raw requests and decoding calls manually, batches run sequentially, default streaming falls back to one fully buffered chunk, HTTP authentication refresh is only demonstrated as a reference pattern, and the package is distributed as one Apple-oriented module. The public API also contains concurrency escape hatches whose safety is not compiler-proven.

The 2.0 scope reduces application boilerplate, improves transfer scalability, makes concurrent behavior explicit and bounded, and allows shared request models to compile independently from Apple-only transport and storage implementations.

### Success metrics

| Metric | Baseline | Target | Measurement method |
|---|---:|---:|---|
| Unit line coverage | 93.50% | >= 90% | `llvm-cov report` |
| Batch peak concurrency | 1 | configured bound, never exceeded | deterministic transport tests |
| Duplicate auth refreshes for concurrent 401s | one per request | one per auth scope/generation | coordinator tests and telemetry |
| Fully buffered default stream on supported OS | yes | no | incremental chunk integration test |
| Existing test regressions | 0 | 0 | `swift test` |
| `NovaNetworkCore` Apple-only imports | CryptoKit/URLSession coupled in umbrella | none | source scan and Linux-compatible build contract |
| New public declaration DocC coverage | not gated | 100% | documentation audit |

## 4. Rollout, Dependencies, Risks

### Rollout plan

- Feature flag: not required; all new behavior is opt-in except `loadBatch` performance, whose ordering and fail-fast contract remain compatible.
- Initial rollout percentage: 100% for package 2.0 adopters.
- Segments: typed endpoints, transfers, auth refresh, and Cache 2.0 can be adopted independently.
- Ramp plan: publish prerelease documentation and verification matrix before commit/release.
- Rollback trigger: public API break, data race, cache serving invalid variants, auth refresh loop, transfer data corruption, or coverage below 90%.

### Dependencies

- Internal: RequestCoalescer, retry pipeline, telemetry hooks, response cache, URLSession transport.
- External: Foundation and CryptoKit for the umbrella package; `NovaNetworkCore` uses Foundation only.
- New third-party dependencies: none.

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Batch task leak or concurrency bound violation | High | Medium | structured task group, cancellation tests, active-count test transport |
| `@unchecked Sendable` hides mutable state race | High | Medium | isolate mutable lifetime state in an actor and run strict-concurrency diagnostics |
| Multiple concurrent 401 responses trigger refresh storm | High | High | actor-owned single-flight refresh task keyed by auth scope |
| Retried auth request loops on repeated 401 | High | Medium | hard maximum refresh attempts and refreshed-generation tracking |
| Streaming producer outruns consumer | Medium | Medium | bounded AsyncThrowingStream buffering and cancellation propagation |
| Download replacement corrupts destination | High | Low | temporary file then atomic replace/move |
| Cache returns a response for `Vary: *` | High | Medium | prohibit storage for wildcard vary |
| HTTP age calculation ignores server `Age`/`Date` | Medium | Medium | explicit corrected-age calculation and deterministic tests |
| Modularization breaks umbrella imports | High | Medium | re-export core from umbrella and compile existing examples/tests |
| Cross-platform Core accidentally imports Apple-only APIs | Medium | Medium | dedicated target and import audit |
| Public API expansion lacks documentation | Medium | High | DocC comments required in the same patch |

## 5. Requirements

### Functional requirements (FR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-CONC-1 | Swift 6 concurrency diagnostics | Library builds in Swift 6 language mode with complete strict-concurrency diagnostics and no new warnings. | T-CONC-1 |
| FR-CONC-2 | Safe client lifetime state | `NetworkClient` mutable listener-task state is actor-isolated or otherwise compiler-verifiable; no unchecked mutable access is introduced. | T-CONC-2 |
| FR-CONC-3 | Cancellation propagation | Child work created by endpoint, batch, auth, and transfer APIs terminates when the consumer cancels. | T-CONC-3, T-BATCH-4, T-XFER-4 |
| FR-END-1 | Typed endpoint protocol | A public `Endpoint` contract describes request creation and typed response decoding for `Sendable` response types. | T-END-1 |
| FR-END-2 | Typed execution | `NetworkClient.execute(endpoint:authScope:...)` applies the normal cache/retry/coalescing pipeline and returns the endpoint response type. | T-END-2 |
| FR-END-3 | Custom decoding | Endpoints can customize decoding without requiring a global client decoder. | T-END-3 |
| FR-BATCH-1 | Bounded concurrency | `loadBatch` supports a positive `maxConcurrentRequests` bound and never exceeds it. | T-BATCH-1 |
| FR-BATCH-2 | Stable ordering | Batch outputs correspond to input order regardless of completion order. | T-BATCH-2 |
| FR-BATCH-3 | Error policies | Fail-fast preserves throwing behavior; collecting mode returns per-item success/failure without false successes. | T-BATCH-3 |
| FR-BATCH-4 | Batch cancellation | Cancellation prevents pending work from starting and cancels active child tasks. | T-BATCH-4 |
| FR-XFER-1 | Incremental streaming | Default URLSession transport can yield response bytes in multiple chunks on supported platforms without buffering the complete response first. | T-XFER-1 |
| FR-XFER-2 | Upload API | Client uploads `Data` and returns `NetworkResponse`, with progress updates and normal HTTP error mapping. | T-XFER-2 |
| FR-XFER-3 | Download API | Client downloads to a requested destination using a temporary file, reports progress, and replaces according to an explicit policy. | T-XFER-3 |
| FR-XFER-4 | Transfer cancellation | Cancelling stream/progress consumption cancels underlying URLSession work and finishes exactly once. | T-XFER-4 |
| FR-AUTH-1 | Auth provider contract | Applications can provide an async, Sendable refresh closure that returns refreshed headers for an auth scope. | T-AUTH-1 |
| FR-AUTH-2 | Single-flight refresh | Concurrent unauthorized responses sharing a scope await one refresh operation. | T-AUTH-2 |
| FR-AUTH-3 | Bounded replay | Each request is replayed after refresh at most once by default and repeated 401 returns the terminal HTTP error. | T-AUTH-3 |
| FR-AUTH-4 | Auth telemetry | Refresh start/success/failure events include scope and waiter information; success is never emitted on failure. | T-AUTH-4 |
| FR-MOD-1 | Cross-platform core product | Package exposes `NovaNetworkCore` containing request/response/error/endpoint models without CryptoKit or Apple-only frameworks. | T-MOD-1 |
| FR-MOD-2 | Umbrella compatibility | `import NovaNetworkClient` continues to expose core public types and all existing examples compile. | T-MOD-2 |
| FR-CACHE-1 | Conditional validators | Cache revalidation supports ETag and Last-Modified validators. | T-CACHE-1 |
| FR-CACHE-2 | `stale-if-error` | Eligible stale cached content may be returned after a qualifying network failure within server/client limits. | T-CACHE-2 |
| FR-CACHE-3 | Request directives | Request `Cache-Control: no-cache` forces revalidation and `no-store` prevents response storage for the request. | T-CACHE-3 |
| FR-CACHE-4 | Corrected age | Freshness accounts for response `Age` and `Date` headers in addition to resident time. | T-CACHE-4 |
| FR-CACHE-5 | Wildcard vary safety | Responses containing `Vary: *` are never stored. | T-CACHE-5 |

### UX requirements (UR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Progressive disclosure | Existing raw `APIRequest` APIs remain available; typed endpoints and transfer policies are opt-in. | T-MOD-2 |
| UR-2 | Predictable defaults | Batch concurrency is bounded, auth replay is limited, and downloads never overwrite unless policy allows it. | T-BATCH-1, T-AUTH-3, T-XFER-3 |
| UR-3 | Actionable errors | Invalid batch limits, destination conflicts, decoding failures, and auth refresh failures produce typed errors. | T-END-3, T-BATCH-3, T-XFER-3, T-AUTH-3 |
| UR-4 | Documentation | Every new public entity and method has DocC describing behavior, cancellation, and errors. | T-DOC-1 |

### Data requirements (DR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Input/output ordering | Batch index is stable and never inferred from completion order. | T-BATCH-2 |
| DR-2 | Credential isolation | Auth refresh state is keyed by normalized auth scope; credentials are not logged in telemetry. | T-AUTH-2, T-AUTH-4 |
| DR-3 | Transfer integrity | Downloaded bytes are only exposed at the final destination after successful completion. | T-XFER-3 |
| DR-4 | Cache metadata compatibility | Existing disk cache records decode after new optional validator/age metadata is added. | T-CACHE-6 |

### Analytics requirements (AR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | Batch lifecycle | Emit one batch completion context with total/succeeded/failed/cancelled/max-concurrency/duration. | T-AR-1 |
| AR-2 | Transfer lifecycle | Emit start/progress/completion/failure contexts without emitting completion on failure. | T-AR-2 |
| AR-3 | HTTP auth lifecycle | Emit refresh started/succeeded/failed once per actual refresh operation, not per waiter. | T-AUTH-4 |
| AR-4 | Cache outcomes | Existing events distinguish validator revalidation and stale-if-error fallback. | T-AR-4 |

### Non-functional requirements (NFR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | Coverage | Unit line coverage remains >= 90%. | T-GATE-1 |
| NFR-2 | Compatibility | Existing public signatures remain source-compatible; all current tests and examples compile. | T-MOD-2 |
| NFR-3 | Memory | Streaming APIs use bounded buffering; downloads do not retain the entire payload in memory. | T-XFER-1, T-XFER-3 |
| NFR-4 | Determinism | Unit tests use injected transports/clocks and no external network; telemetry recorders preserve synchronous emission order without unstructured per-event tasks. | T-GATE-3, test policy audit |
| NFR-5 | E2E integrity | E2E tests use real public APIs only and run only with `RUN_E2E_TESTS=1`. | T-GATE-2 |
| NFR-7 | v2 E2E breadth | Every v2 feature with network-observable behavior has at least one real-public-API E2E scenario; compiler/module-only behavior remains covered by integration gates. | T-E2E-END, T-E2E-BATCH, T-E2E-XFER, T-E2E-AUTH, T-E2E-CACHE |
| NFR-6 | No dependencies | No third-party package dependency is added. | package audit |

### Edge cases (EC)

| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Empty batch | Returns immediately with an empty result and no child task. | T-BATCH-5 |
| EC-2 | Batch bound <= 0 | Throws a typed invalid-configuration error before starting work. | T-BATCH-6 |
| EC-3 | Endpoint decoder throws | Maps to `NetworkError.decoding` unless already a `NetworkError`. | T-END-3 |
| EC-4 | Refresh closure fails | All waiters receive auth refresh failure/terminal request error; no request loops. | T-AUTH-3, T-AUTH-4 |
| EC-5 | Different auth scopes fail together | Refresh operations remain independent. | T-AUTH-5 |
| EC-6 | Stream consumer terminates early | Underlying transfer is cancelled and continuation removed. | T-XFER-4 |
| EC-7 | Download destination exists | Explicit `.fail`, `.replace`, or `.keepExisting` policy is honored. | T-XFER-3 |
| EC-8 | Cache contains `Vary: *` | Entry is neither stored nor reused. | T-CACHE-5 |
| EC-9 | Invalid/malformed HTTP dates | Header is ignored safely and client freshness limit still applies. | T-CACHE-4 |
| EC-10 | Stale entry and cancellation/auth failure | `stale-if-error` does not mask cancellation, authorization, or explicit client policy errors. | T-CACHE-2 |

## 6. State Machine and Flows

### Endpoint states

- `idle`
- `executing`
- `decoding`
- `completed`
- `failed`
- `cancelled`

### Batch states

- `idle`
- `scheduling`
- `running(active, pending, completed)`
- `completed`
- `failed`
- `cancelled`

### Transfer states

- `idle`
- `preparing`
- `transferring(bytesCompleted, totalBytes)`
- `finalizing`
- `completed`
- `failed`
- `cancelled`

### Auth refresh states per scope

- `idle(generation)`
- `refreshing(generation, waiters)`
- `succeeded(newGeneration)`
- `failed(generation)`

### Cache states

- `miss`
- `fresh`
- `staleRevalidatable`
- `revalidating`
- `staleIfErrorEligible`
- `expired`

### Transitions

| From | Trigger | To | Notes |
|---|---|---|---|
| endpoint idle | execute | executing | Uses normal request pipeline. |
| endpoint executing | response bytes | decoding | Endpoint controls decoding. |
| endpoint decoding | decode success | completed | Return typed response. |
| batch scheduling | capacity available | running | Never exceed configured bound. |
| batch running | child result | running/completed | Store by original index. |
| transfer transferring | consumer cancellation | cancelled | Cancel URLSession task. |
| auth idle | HTTP 401 | refreshing | Create one task for scope. |
| auth refreshing | another HTTP 401 | refreshing | Join existing refresh. |
| auth succeeded | replay request | idle | Replay at most configured limit. |
| cache staleRevalidatable | 304 | fresh | Merge metadata and reuse body. |
| cache staleIfErrorEligible | qualifying failure | fresh/stale served | Emit fallback outcome. |

### State to UI/Actions/Analytics mapping

This is a library and does not render UI. “UI” below means observable API output.

| State | Observable API | Allowed actions | Analytics |
|---|---|---|---|
| endpoint executing | suspended async call | cancel task | existing request start/end |
| batch running | suspended call | cancel task | batch completion only at terminal state |
| transfer transferring | progress AsyncSequence | cancel/stop consuming | transfer start/progress |
| auth refreshing | requests await same task | cancel waiter | auth refresh started once |
| cache stale served | cached body returned | invalidate/reload | stale-if-error outcome |
| failed | typed thrown error/result failure | retry by caller | failure event only |

## 7. Engineering Notes

- `swift-tools-version` remains 6.2 unless a 6.3-only manifest feature becomes necessary.
- The library target uses Swift 6 language mode; app-oriented default MainActor isolation is not enabled for this networking library.
- New concurrency should use structured task groups or actor-owned unstructured tasks with explicit cancellation cleanup.
- `NetworkClient` remains a class for source compatibility. Mutable listener lifetime state moves behind actor isolation rather than converting the whole client to an actor.
- The existing `loadBatch` signature remains and delegates to bounded concurrent fail-fast execution. A collecting overload exposes per-item results.
- `NovaNetworkCore` is a separate product. The umbrella module re-exports it so existing consumers need no new import.
- Cache schema additions must be optional/defaulted to preserve decoding of older persisted records.
- HTTP auth refresh is integrated around transport execution and kept separate from normal retry attempt accounting.
- Telemetry must never include authorization header values or refreshed credential material.

## 8. Test Matrix

| Requirement ID | Test ID | Test type | Owner | Status |
|---|---|---|---|---|
| FR-CONC-1 | T-CONC-1 strict concurrency build | integration | Engineering | passed |
| FR-CONC-2 | T-CONC-2 concurrent client lifetime stress | unit | Engineering | passed |
| FR-CONC-3 | T-CONC-3 cancellation cleanup | unit | Engineering | passed |
| FR-END-1 | T-END-1 endpoint request construction | unit | Engineering | passed |
| FR-END-2 | T-END-2 typed endpoint executes through client | unit | Engineering | passed |
| FR-END-3, EC-3 | T-END-3 custom decoder and failure mapping | unit | Engineering | passed |
| FR-BATCH-1 | T-BATCH-1 batch respects maximum concurrency | unit | Engineering | passed |
| FR-BATCH-2, DR-1 | T-BATCH-2 batch preserves input order | unit | Engineering | passed |
| FR-BATCH-3 | T-BATCH-3 fail-fast and collecting policies | unit | Engineering | passed |
| FR-BATCH-4 | T-BATCH-4 cancellation stops batch work | unit | Engineering | passed |
| EC-1 | T-BATCH-5 empty batch | unit | Engineering | passed |
| EC-2 | T-BATCH-6 invalid batch configuration | unit | Engineering | passed |
| FR-XFER-1, NFR-3 | T-XFER-1 incremental bounded stream | integration | Engineering | passed |
| FR-XFER-2 | T-XFER-2 upload response and progress | unit/integration | Engineering | passed |
| FR-XFER-3, DR-3, EC-7 | T-XFER-3 download finalization policies | unit/integration | Engineering | passed |
| FR-XFER-4, EC-6 | T-XFER-4 transfer cancellation | unit | Engineering | passed |
| FR-AUTH-1 | T-AUTH-1 provider applies refreshed headers | unit | Engineering | passed |
| FR-AUTH-2, DR-2 | T-AUTH-2 concurrent 401 single-flight | unit | Engineering | passed |
| FR-AUTH-3, EC-4 | T-AUTH-3 bounded replay and failure | unit | Engineering | passed |
| FR-AUTH-4, AR-3 | T-AUTH-4 auth telemetry success/failure contract | unit | Engineering | passed |
| EC-5 | T-AUTH-5 auth scopes remain independent | unit | Engineering | passed |
| FR-MOD-1 | T-MOD-1 core product import/build audit | integration | Engineering | passed |
| FR-MOD-2, NFR-2 | T-MOD-2 umbrella source compatibility | integration | Engineering | passed |
| FR-CACHE-1 | T-CACHE-1 ETag and Last-Modified revalidation | unit | Engineering | passed |
| FR-CACHE-2, EC-10 | T-CACHE-2 stale-if-error eligibility | unit | Engineering | passed |
| FR-CACHE-3 | T-CACHE-3 request no-cache/no-store | unit | Engineering | passed |
| FR-CACHE-4, EC-9 | T-CACHE-4 corrected response age | unit | Engineering | passed |
| FR-CACHE-5, EC-8 | T-CACHE-5 wildcard vary is not stored | unit | Engineering | passed |
| DR-4 | T-CACHE-6 legacy disk cache schema compatibility | unit | Engineering | passed |
| AR-1 | T-AR-1 batch telemetry schema and trigger | unit | Engineering | passed |
| AR-2 | T-AR-2 transfer telemetry terminal correctness | unit | Engineering | passed |
| AR-4 | T-AR-4 cache outcome telemetry | unit | Engineering | passed |
| UR-4 | T-DOC-1 new public API DocC audit | integration | Engineering | passed |
| NFR-1 | T-GATE-1 unit coverage >= 90% | integration | QA | passed |
| NFR-4 | T-GATE-3 `connectivityFlapStabilityDoesNotSpawnDuplicateReconnectLoops` preserves suppressed -> resumed -> success telemetry order under repeated Swift 6.3 runs | unit/integration | Engineering | passed (50/50 local Swift 6.3 repetitions) |
| NFR-5 | T-GATE-2 real-public-API E2E | e2e | QA | passed |
| FR-END-2, NFR-7 | T-E2E-END typed endpoint against JSONPlaceholder | e2e | QA | passed |
| FR-BATCH-1...3, NFR-7 | T-E2E-BATCH bounded collecting batch against public APIs | e2e | QA | passed |
| FR-XFER-1...3, NFR-7 | T-E2E-XFER incremental stream and upload against HTTPBingo, plus download finalization against JSONPlaceholder | e2e | QA | passed |
| FR-AUTH-1...3, NFR-7 | T-E2E-AUTH 401 refresh and replay against HTTPBingo bearer | e2e | QA | passed |
| FR-CACHE-1, NFR-7 | T-E2E-CACHE ETag conditional revalidation against HTTPBingo | e2e | QA | passed |

### Negative tests

- Batch bound validation occurs before any transport call.
- Batch failure never writes a success result for the failed index.
- Endpoint decode failure never emits request transport success as typed decode success.
- Auth refresh failure emits no success telemetry and does not retry recursively.
- Transfer failure leaves no partial destination file.
- Transfer cancellation emits no completion event.
- `stale-if-error` never masks cancellation, 401/403, rate limiting, circuit-open, or policy errors.
- `Vary: *` never enters either memory or disk cache.

### Regression risks

| Risk | Impact | Mitigation tests |
|---|---|---|
| Existing coalescing changes under endpoint/batch use | High | current coalescer suite, T-END-2, T-BATCH-1 |
| Retry count changes due to auth replay | High | current retry suite, T-AUTH-3 |
| Cache freshness regression | High | current cache suite, T-CACHE-1..6 |
| Umbrella import loses public symbol | High | all current tests/examples, T-MOD-2 |
| Cancellation leaks continuation/task | High | T-CONC-3, T-BATCH-4, T-XFER-4 |

## 9. Release Notes Input ("What's New")

### Customer impact

- Consumers can model typed endpoints and execute them through the existing resilience pipeline.
- Batches run concurrently with a deterministic concurrency cap and stable ordering.
- Native streaming, upload, and download APIs expose progress and cancellation.
- HTTP 401 recovery is single-flight and bounded.
- Shared request models can depend on `NovaNetworkCore` without the full client.
- Cache behavior supports additional standard validators and stale recovery.

### User-facing changes

- New `Endpoint` and typed `execute` APIs.
- New batch options and collecting results API.
- New transfer protocols, progress models, and client methods.
- New HTTP auth refresh provider/configuration.
- New `NovaNetworkCore` library product.
- Extended cache policy and metadata.

### Behavior changes / migration notes

- Existing `loadBatch` retains stable ordering and throwing behavior but executes requests concurrently using a bounded default.
- Existing raw request and umbrella imports remain supported.
- No migration is required for consumers not adopting the new APIs.

### Known limitations

- Full HTTP transport remains Apple-platform focused in 2.0.
- Streaming falls back to a buffered single chunk on OS versions without native URLSession async byte support.
- Background task scheduling remains the responsibility of the host application.

## 10. Verification Record

- Strict concurrency: complete checking build passed on Apple Swift 6.2.4.
- Core isolation: `swift build --target NovaNetworkCore` passed.
- Unit/integration: 271 tests passed.
- Combined source line coverage: 92.59% across `NovaNetworkClient` and `NovaNetworkCore`.
- Real-public-API E2E: 31 tests passed, including 7 v2 feature scenarios.
- E2E policy scan: no mock/stub transports or fake example endpoints in the E2E directory.
- Swift 6.3: stable compatibility job added to CI; execution occurs in GitHub Actions.
