# Changelog

This is a chronological index of notable changes. Each entry after 2.0 links to a detailed
`docs/WHATS_NEW_v<version>.md` file rather than duplicating it here; see the
[What's New Template](docs/templates/WHATS_NEW_TEMPLATE.md) for that file's format and the
[DFR template](docs/templates/DFR_TEMPLATE.md) for the requirements process behind major
versions. The version numbers below follow this project's existing `WHATS_NEW_v<major>.<minor>`
convention; not every one is a tagged release — see [Releases](#releases).

## Unreleased

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
