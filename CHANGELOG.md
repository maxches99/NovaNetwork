# Changelog

This is a chronological index of notable changes. Each entry after 2.0 links to a detailed
`docs/WHATS_NEW_v<version>.md` file rather than duplicating it here; see the
[What's New Template](docs/templates/WHATS_NEW_TEMPLATE.md) for that file's format and the
[DFR template](docs/templates/DFR_TEMPLATE.md) for the requirements process behind major
versions. The version numbers below follow this project's existing `WHATS_NEW_v<major>.<minor>`
convention; not every one is a tagged release — see [Releases](#releases).

## Unreleased

- **The test suite runs on Linux.** Until now CI compiled the library there and ran nothing: the
  `Linux Client Build Gate` said as much in its own comment. Switching the suite on took four rounds
  of build fixes before a single assertion could run — missing `FoundationNetworking` imports;
  Apple-only APIs used unguarded in tests (`Darwin.Mach` in the benchmarks, CryptoKit encryption, two
  `URLRequest` properties, a `self` capture in a `@Sendable` closure); `stderr`, which is a global
  `var` on Glibc and so rejected by strict concurrency; and `PortableSHA256`, reached through a
  module that does not define it, which had therefore never compiled anywhere, because the suite
  exercising it only exists where CryptoKit is absent.

  Then it earned its keep: the first thing it found once it could run was the `replaceItemAt` bug
  below — a real behavioural difference, in the code that decides whether queued writes survive.
  Fixing it took four more assertions with it.

  What remains is honest about its own limits. Twelve managed transfer, background transfer, and
  streaming tests are
  **skipped on Linux with a stated reason** rather than deleted, because they depend on Apple's
  `URLSession` behaviour — ranged and resumed requests reaching a `URLProtocol` double, responses
  arriving in more than one chunk, and background sessions, which do not exist there at all. They
  appear as skips in the output, so the gap is visible rather than absent. With those set aside the
  suite passes on Linux. One test now pins *both*
  platforms instead of one: an error thrown from a `URLProtocol` reaches the transport wrapped on
  Apple and unwrapped on Linux, so it maps to `transport` there and `cancelled` here, and both are
  asserted.
- **Staged files are published with `rename(2)`, not `FileManager.replaceItemAt`.** On
  swift-corelibs-foundation `replaceItemAt` can remove the destination and leave nothing in its
  place, which is how an offline queue holding one entry came back holding none. The same call sat
  in five places, all of them durability code: the offline write store, the transfer journal, the
  managed transfer manager, the background transfer coordinator, and the streaming transport.
  `rename(2)` replaces an existing destination and is atomic on both platforms, so a reader sees the
  old file or the new one and never neither; a staged file on another filesystem (`EXDEV`) is copied
  beside the destination first so the publish itself stays a rename.

## 3.4.0 — 2026-08-27

The first tagged release since 2.0.0. Everything below shipped in it.

- [3.4](docs/WHATS_NEW_v3.4.md) — Sharing the offline queue across processes: App Group container
  resolution that names the entitlement when it is missing, a non-blocking `flock`-based
  cross-process lock, and `CoordinatedOfflineWriteStore`, a decorator that takes the lock around any
  `OfflineWriteStore` so an app and its share extension can use one queue without writing over each
  other. Opt-in; nothing changes for a client that does not wrap its store.
- [3.3](docs/WHATS_NEW_v3.3.md) — Network path policies: decide what to send from the *kind* of path,
  not only from whether there is one. Interfaces, expense, and Low Data Mode become send, defer, or
  fail, with an `isEssential` escape hatch so a sign-in is never the thing that gets held back.
  Deferral reaches the offline queue that already exists rather than a second one beside it. Off by
  default; `Network.framework` is behind `canImport`.
- [3.2](docs/WHATS_NEW_v3.2.md) — Adaptive concurrency: how many requests may be in flight at once,
  decided from what the server is doing rather than picked. Additive increase while requests are
  waiting for slots, multiplicative decrease on refusals *and* on responses slower than the best
  seen, arrival-ordered queueing with cancellation and an optional queue timeout, and a telemetry
  hook for every movement. Off by default; coalesced callers share one slot.
- [3.1](docs/WHATS_NEW_v3.1.md) — A trace you can read: every request on one clock with a readable
  ruler and a List/Timeline switch in the panel, a HAR 1.2 reader that accepts files from any
  producer and restores attempts, coalescing, and cache outcome from our own exports,
  `DiagnosticsRecorder.load(_:)`, and [`Inspector`](Inspector), a macOS app that opens a HAR and
  shows it with the same panel a live app embeds.
- **Diagnostics panel: rows are tappable again.** `NetworkDiagnosticsView` declared its list with a
  selection binding, which turns rows into selection targets — the `NavigationSplitView` sidebar
  pattern — so a tap set the binding instead of pushing the request's detail. The binding was never
  read. The detail screen is also titled with the method *and* path now, since several requests
  share a method. Covered by UI tests in [`DemoApp`](DemoApp), because whether a row is tappable is
  a property of the rendered hierarchy that no unit test over `DiagnosticsPanelState` can reach.
- **`NovaNetworkDiagnostics` is a library product.** The target existed and was tested, but was never
  exposed as a product, so nothing outside the package could depend on it.
- **[`DemoApp`](DemoApp)** — an iOS app for looking at the diagnostics panel on a device, consuming
  the repository as a local package. Five scenarios (retry, coalescing, cache, rejection,
  cancellation) run either against a scripted transport inside the app or as real HTTPS requests to
  an httpbin-compatible host.
- **Benchmark baselines are gated in CI.** The benchmark executable existed and nothing ran it, so
  a regression in how many transport calls a coalesced workload makes would have landed silently.
  The checks now split what the code decides — transport-call counts, retry-storm outcomes, breaker
  transitions, replay counts, enforced — from what a shared runner decides as much as the code —
  elapsed time, latency, allocations, reported as an advisory unless `--strict-timing` is passed.
  A missing or unreadable baseline file is now a failure rather than a silent pass, which it was
  whenever the benchmark ran from outside the repository root.
- [3.0](docs/WHATS_NEW_v3.0.md) — NovaNetworkQuery: server state by key for the screens that render
  it, with stale-while-revalidate reads, shared in-flight fetches, subscriptions, optimistic
  mutations with exact rollback, hierarchical invalidation, paged queries, and an availability-gated
  observable model. New standalone `NovaNetworkQuery` product; the platform floor is unchanged.
- [2.14](docs/WHATS_NEW_v2.14.md) — Authentication: OAuth 2.0 authorization code with PKCE, refresh,
  client credentials, and device grants, typed error envelopes, in-memory and Keychain token stores,
  single-flight refresh wired into the client, and HMAC-SHA256 request signing. New standalone
  `NovaNetworkAuth` product; SHA-256 promoted to public `NovaNetworkCore` API.
- [2.13](docs/WHATS_NEW_v2.13.md) — Diagnostics: a bounded recorder over the existing telemetry with
  retry waterfalls, HAR 1.2 export, `os_signpost` intervals for Instruments, and a SwiftUI panel.
  New standalone `NovaNetworkDiagnostics` product.
- [2.12](docs/WHATS_NEW_v2.12.md) — Record and replay: capture real exchanges into a reviewable JSON
  cassette and replay them deterministically in tests, previews, and offline demo builds, with
  credentials redacted before anything reaches disk. New standalone `NovaNetworkCassette` product.
- [2.11](docs/WHATS_NEW_v2.11.md) — Declarative endpoints: the opt-in `@Endpoint` macro (behind the
  `EndpointMacros` SwiftPM trait, so the default package graph still resolves zero dependencies),
  an OpenAPI 3.0/3.1 generator exposed as `swift package nova-openapi`, and the shared
  `EndpointDefinition`/`EndpointRequestBuilder` runtime both front ends target.
- [2.10](docs/WHATS_NEW_v2.10.md) — Apple-style Swift-DocC learning experience with a complete
  Getting Started guide, eight progressive interactive tutorials, core-concept and API-selection
  guides, a production checklist, type-checked tutorial resources, and a standalone documentation
  website with a dedicated CI build.
- **Relicensed from GPL-3.0 to the Apache License, Version 2.0**, so the package can be adopted
  in closed-source applications. Single copyright holder, no prior external contributions, so no
  contributor consent was required. See [LICENSE](LICENSE).
- [2.9](docs/WHATS_NEW_v2.9.md) — Linux build gate for `NovaNetworkClient`: Apple-only APIs
  (certificate pinning, mTLS, the offline queue's optional AES-GCM cipher) audited and gated
  behind availability checks; request/cache-key fingerprint hashing no longer requires
  `CryptoKit`. Audited and gated, not proven working — see that file for exactly what was and
  wasn't verified.
- [2.8](docs/WHATS_NEW_v2.8.md) — `NetworkError` conforms to `Equatable` and `LocalizedError`;
  additive `NetworkErrorContext`/`ContextualNetworkError` for request/attempt context.
- [2.7](docs/WHATS_NEW_v2.7.md) — `NovaNetworkClientTestSupport` grew from four basic test
  doubles into a fuller testing DSL: request-matching routes, chaos injection, a deterministic
  virtual clock, and telemetry recording.
- [2.6](docs/WHATS_NEW_v2.6.md) — `ResponseDecoding` strategies for content-type-aware response
  decoding, alongside the unchanged default `Decodable`/`JSONDecoder` path.
- [2.5](docs/WHATS_NEW_v2.5.md) — `NetworkClientConfiguration`, a mutable value grouping every
  `NetworkClient` construction option, as an alternative to the labeled-argument initializer.
- [2.4](docs/WHATS_NEW_v2.4.md) — Certificate pinning and mutual TLS (Apple platforms): SPKI
  SHA-256 public-key pinning with backup pins, client certificate support.
- [2.3](docs/WHATS_NEW_v2.3.md) — Multipart form-data uploads streamed from disk in fixed-size
  chunks, never buffering file parts fully in memory.
- [2.2](docs/WHATS_NEW_v2.2.md) — Server-Sent Events: a spec-compliant, platform-independent
  parser, automatic reconnect, `Last-Event-ID` replay, server-driven `retry:` timing.

## Releases

- [3.4.0](#340--2026-08-27) — everything from 2.2 to 3.4 in one tag: SSE, multipart, resumable and
  background transfers, WebSocket hardening, the `@Endpoint` macro and OpenAPI generator, record and
  replay cassettes, diagnostics with a timeline and a macOS inspector, a full auth module,
  NovaNetworkQuery, adaptive concurrency, network path policies, and a queue an app can share with
  its extensions. Relicensed to Apache 2.0. The platform floor and the zero-dependency default
  package graph are unchanged.
- [2.0.0](docs/WHATS_NEW_v2.0.md) — Typed `Endpoint`/`execute` API, `NovaNetworkCore` as a
  standalone cross-platform product, native streaming/upload/download, single-flight HTTP auth
  refresh.
- [1.19](docs/WHATS_NEW_v1.19.md) — DX 2.0: preset composition (`base + overlays`), production
  readiness validator, reference cookbook.
- [1.18](docs/WHATS_NEW_v1.18.md) — Durability and chaos hardening for the offline queue.
- [1.17](docs/WHATS_NEW_v1.17.md) — Observability Contract v2.
- [1.16](docs/WHATS_NEW_v1.16.md) — Architecture split and networking folder reorganization
  (internal).
- [1.15](docs/WHATS_NEW_v1.15.md) — DX presets (`restHeavy`, `realtimeHeavy`, `offlineFirst`) for
  faster adoption.
- [1.14](docs/WHATS_NEW_v1.14.md) — Offline-first sync pipeline: priority-aware replay, fairness
  scheduler, starvation protection, replay windows.
- [1.13](docs/WHATS_NEW_v1.13.md), [1.12](docs/WHATS_NEW_v1.12.md),
  [1.11](docs/WHATS_NEW_v1.11.md), [1.10](docs/WHATS_NEW_v1.10.md) — incremental offline queue,
  retry, and telemetry hardening.
- [1.9](docs/WHATS_NEW_v1.9.md), [1.8](docs/WHATS_NEW_v1.8.md), [1.7](docs/WHATS_NEW_v1.7.md) —
  incremental resilience and observability additions.
- [1.6](docs/WHATS_NEW_v1.6.md) — Adaptive retry profiles by failure category; server-driven
  backoff via `Retry-After`.
- [1.5](docs/WHATS_NEW_v1.5.md) — Deadline budget enforcement across the request/retry lifecycle.
- [1.4](docs/WHATS_NEW_v1.4.md) — Priority-aware request scheduling; retry policy v2 (bounded
  exponential backoff with jitter).
- [1.3](docs/WHATS_NEW_v1.3.md) — Middleware/interceptor pipeline; disk cache capacity controls.
- [1.2](docs/WHATS_NEW_v1.2.md) — `ResponseCache` abstraction (`MemoryResponseCache`,
  `DiskResponseCache`); ETag/`If-None-Match` revalidation.
- [1.1](docs/WHATS_NEW_v1.1.md) — Response cache policies, cache management APIs, coalescing
  safety limits, injectable `RetryClock`/`RetryRandomGenerator`, `APIRequestBuilder`.

Git tags exist for `1.4` through `2.0.0`; the versions listed under Unreleased above are not yet
tagged. See [CONTRIBUTING.md](CONTRIBUTING.md) for how a release gets tagged and how the
[API breaking-changes gate](.github/workflows/ci.yml) uses the most recent tag as its baseline.
