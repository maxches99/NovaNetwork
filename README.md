# NovaNetworkClient

`NovaNetworkClient` is a Swift library for deduplicating concurrent requests with the same logical identity.

When multiple callers ask for the same resource at the same time, only one underlying operation runs and all callers await the shared result.

## Documentation

- [Getting Started](Sources/NovaNetworkClient/NovaNetworkClient.docc/GettingStarted.md)
- [Interactive DocC Tutorials](Sources/NovaNetworkClient/NovaNetworkClient.docc/Tutorial-Table-of-Contents.tutorial)
- [Documentation Website](https://nova-network-documentation.maxches99.workers.dev)
- [Website source and build instructions](DocumentationSite/README.md)
- [Core Concepts](Sources/NovaNetworkClient/NovaNetworkClient.docc/CoreConcepts.md)
- [Choosing an API](Sources/NovaNetworkClient/NovaNetworkClient.docc/ChoosingAnAPI.md)
- [Declarative Endpoints (`@Endpoint` macro and OpenAPI generation)](Sources/NovaNetworkClient/NovaNetworkClient.docc/DeclarativeEndpoints.md)
- [Record and Replay (cassettes)](Sources/NovaNetworkClient/NovaNetworkClient.docc/RecordAndReplay.md)
- [Diagnostics (recorder, HAR export, Instruments, SwiftUI panel)](Sources/NovaNetworkClient/NovaNetworkClient.docc/Diagnostics.md)
- [Authentication (OAuth 2.0, PKCE, token storage, request signing)](Sources/NovaNetworkClient/NovaNetworkClient.docc/Authentication.md)
- [Query Layer (server state for screens)](Sources/NovaNetworkClient/NovaNetworkClient.docc/QueryLayer.md)
- [Production Checklist](Sources/NovaNetworkClient/NovaNetworkClient.docc/ProductionChecklist.md)
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Setup & Usage Guide](docs/SETUP_GUIDE.md)
- [Unit Test Policy](docs/UNIT_TEST_POLICY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Examples](Examples/README.md)
- [Telemetry Contract v2](docs/TELEMETRY_CONTRACT_V2.md)
- [NovaNetwork v2.0 DFR](docs/dfr/NOVA_NETWORK_V2_DFR.md)
- [NovaNetwork v2.1 DFR](docs/dfr/NOVA_NETWORK_V2_1_DFR.md)
- [NovaNetwork v2.11 DFR](docs/dfr/NOVA_NETWORK_V2_11_DFR.md)
- [NovaNetwork v2.12 DFR](docs/dfr/NOVA_NETWORK_V2_12_DFR.md)
- [v2.0 Traceability Pack](docs/TRACEABILITY_PACK_v2.0.md)
- [v2.1 Traceability Pack](docs/TRACEABILITY_PACK_v2.1.md)
- [v2.11 Traceability Pack](docs/TRACEABILITY_PACK_v2.11.md)
- [v2.12 Traceability Pack](docs/TRACEABILITY_PACK_v2.12.md)
- [NovaNetwork v2.13 DFR](docs/dfr/NOVA_NETWORK_V2_13_DFR.md)
- [v2.0 Traceability Pack](docs/TRACEABILITY_PACK_v2.0.md)
- [v2.1 Traceability Pack](docs/TRACEABILITY_PACK_v2.1.md)
- [v2.11 Traceability Pack](docs/TRACEABILITY_PACK_v2.11.md)
- [v2.13 Traceability Pack](docs/TRACEABILITY_PACK_v2.13.md)
- [NovaNetwork v2.14 DFR](docs/dfr/NOVA_NETWORK_V2_14_DFR.md)
- [v2.0 Traceability Pack](docs/TRACEABILITY_PACK_v2.0.md)
- [v2.1 Traceability Pack](docs/TRACEABILITY_PACK_v2.1.md)
- [v2.11 Traceability Pack](docs/TRACEABILITY_PACK_v2.11.md)
- [v2.14 Traceability Pack](docs/TRACEABILITY_PACK_v2.14.md)
- [NovaNetwork v3.0 DFR](docs/dfr/NOVA_NETWORK_V3_0_DFR.md)
- [v2.0 Traceability Pack](docs/TRACEABILITY_PACK_v2.0.md)
- [v2.1 Traceability Pack](docs/TRACEABILITY_PACK_v2.1.md)
- [v2.11 Traceability Pack](docs/TRACEABILITY_PACK_v2.11.md)
- [v3.0 Traceability Pack](docs/TRACEABILITY_PACK_v3.0.md)
- [v1.15 Traceability Pack](docs/TRACEABILITY_PACK_v1.15.md)
- [v1.16 Traceability Pack](docs/TRACEABILITY_PACK_v1.16.md)
- [v1.19 Traceability Pack](docs/TRACEABILITY_PACK_v1.19.md)

## Product Delivery Templates

- [DFR Template](docs/templates/DFR_TEMPLATE.md)
- [Test Matrix Example](docs/templates/TEST_MATRIX_EXAMPLE.md)
- [What's New Template](docs/templates/WHATS_NEW_TEMPLATE.md)
- [PR Template](.github/pull_request_template.md)

## Installation (SwiftPM)

```swift
dependencies: [
    .package(url: "https://github.com/maxches99/NovaNetwork", from: "2.0.0")
]
```

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "NovaNetworkClient", package: "NovaNetwork")
        ]
    )
]
```

The package has **no dependencies** in this configuration.

### Optional: the `@Endpoint` macro

The `@Endpoint` macro is the only part of the package that needs `swift-syntax`, so it lives behind
a SwiftPM trait that is off by default. SwiftPM prunes the dependency entirely while the trait is
disabled, so opting out costs nothing:

```swift
dependencies: [
    .package(url: "https://github.com/maxches99/NovaNetwork", from: "2.11.0", traits: ["EndpointMacros"])
]
```

```swift
.product(name: "NovaNetworkMacros", package: "NovaNetwork")
```

Generating endpoints from an OpenAPI document needs neither the trait nor the macro — see
[Declarative Endpoints](#declarative-endpoints-v211).

## Features

- Typed `Endpoint<Response>` execution with endpoint-specific decoding.
- Declarative endpoints: the opt-in `@Endpoint` macro generates request construction from a method,
  a path template, and a type's stored properties, with `@Path`/`@Query`/`@Header`/`@Body` markers
  and compile-time diagnostics for every misuse.
- OpenAPI 3.0/3.1 code generation (`swift package nova-openapi`) producing deterministic, checked-in
  endpoint and model types that depend only on `NovaNetworkCore` — no macro, no swift-syntax.
- Shared declarative runtime (`EndpointDefinition`, `EndpointRequestBuilder`,
  `EndpointParameterConvertible`) so hand-written, macro-generated, and spec-generated endpoints
  build identical requests.
- Record and replay (`NovaNetworkCassette`): capture real exchanges into a reviewable JSON cassette
  and replay them deterministically in tests, previews, and offline demo builds, with credentials
  redacted before anything reaches disk.
- Diagnostics (`NovaNetworkDiagnostics`): a bounded recorder over the existing telemetry, retry
  waterfalls, HAR 1.2 export for bug reports, `os_signpost` intervals for Instruments, and a SwiftUI
  panel — with credentials redacted before anything is retained.
- Linux build gate: `NovaNetworkClient`'s Apple-only APIs (certificate pinning, mTLS, the offline
  queue's optional AES-GCM cipher) are behind explicit availability checks, and fingerprint
  hashing no longer requires `CryptoKit`, so the core client compiles on Linux (see
  [Linux Compatibility](#linux-compatibility) for exactly what that does and doesn't claim).
- `NetworkError` conforms to `Equatable` and `LocalizedError`; `NetworkErrorContext` and
  `ContextualNetworkError` attach request/attempt context without changing its existing cases.
- `NovaNetworkClientTestSupport`: request-matching routes, chaos injection, a deterministic
  virtual clock, and telemetry recording for testing code that uses `NovaNetworkClient`.
- `ResponseDecoding` strategies (`decode`, `loadResponse`) for decoders that need response
  headers, including `Content-Type`-based negotiation, alongside the unchanged default
  `Decodable`/`JSONDecoder` path.
- `NetworkClientConfiguration`: a mutable value grouping every construction option, as an
  alternative to `NetworkClient.init`'s labeled arguments for configuring many options at once.
- Swift 6.2 strict-concurrency compliance and a Swift 6.3 compatibility CI lane.
- Bounded concurrent batches with stable ordering, fail-fast, and collecting modes.
- Incremental response streaming plus native URLSession upload/download progress APIs.
- Durable managed transfers with stable IDs, resumable HTTP Range downloads, TUS uploads,
  integrity checks, restoration, and Apple background URLSession coordination.
- Single-flight HTTP authentication refresh, isolated by authentication scope.
- Authentication (`NovaNetworkAuth`): OAuth 2.0 authorization code with PKCE, refresh, client
  credentials, and device grants; typed error envelopes; in-memory and Keychain token stores; and
  HMAC-SHA256 request signing, wired into the client's existing single-flight refresh.
- Standalone cross-platform `NovaNetworkCore` product for request/response/error/endpoint models.
- HTTP Cache 2.0 with ETag and Last-Modified revalidation, corrected age, request directives,
  `stale-if-error`, and safe `Vary: *` handling.
- Query layer (`NovaNetworkQuery`): server state by key for the screens that render it, with
  stale-while-revalidate reads, shared in-flight fetches, subscriptions, optimistic mutations with
  rollback, hierarchical invalidation, and paged queries.
- Coalesces concurrent requests by stable fingerprint key.
- Optional short-lived in-memory response cache (`cacheFirst`, `staleWhileRevalidate`).
- Optional pluggable response cache (`MemoryResponseCache`, `DiskResponseCache`, custom `ResponseCache`).
- HTTP cache revalidation returns cached content after `304 Not Modified`.
- Configurable fingerprint policy (`query`, `headers`, `body`).
- Coalescer limits (`maxInFlightKeys`, `maxWaitersPerKey`, `inFlightTimeout`).
- Configurable waiter overflow behavior for coalescing limits (`bypass` or explicit failure).
- Per-request execution options (priority, per-request limits override, capacity scheduling, deadline budget, coalescing mode, circuit breaker).
- Client-side per-key rate limiting (`RateLimitPolicy`).
- Request middleware pipeline (`beforeSend` / `afterResponse`).
- Offline queue for write requests (`POST`/`PUT`/`PATCH`) with durable disk store and replay APIs.
- Offline-first sync pipeline: priority-aware replay (`critical`/`normal`/`background`), fairness scheduler, starvation protection, replay windows, and rate controls.
- Conflict workflows with rich metadata resolver hooks plus manual-review requeue API.
- Offline pipeline observability APIs (`offlineQueuePipelineMetrics`) and recovery-loss telemetry.
- Encrypted offline store lifecycle controls with forward-compatible schema reads and key-rotation rewrite path.
- Cancellation policies:
  - `keepRunning`
  - `cancelWhenNoWaiters`
- Retry/backoff policy for transient failures (for example `429`, `5xx`, network timeouts) with idempotency-aware gating.
- Adaptive retry options (failure-category profiles, `Retry-After` support, retry budget).
- Runtime policy updates (global/host/endpoint scope) without recreating `NetworkClient`.
- Coalescing dedupe TTL policy with scope overrides and priority `endpoint > host > global`.
- Runtime tuning for coalescer fairness scheduler and circuit-breaker thresholds/probe policy.
- DX presets for faster adoption:
  - `NetworkClientPreset.restHeavy`
  - `NetworkClientPreset.realtimeHeavy`
  - `NetworkClientPreset.offlineFirst`
- Presets v2 composition model (`base preset + overlays`) via:
  - `NetworkClientPreset.compose(base:overlays:)`
  - `NetworkClientPresetOverlayKind`
- Safe preset override points via `NetworkClientPreset.RequestOverrides` (merge-only overrides).
- Production onboarding helpers:
  - `NetworkClientProductionProfileGenerator`
  - `NetworkClientPresetValidator` / `validateProductionReadiness`
  - anti-pattern validation report with blocking vs warning findings.
- Testable retry behavior via injectable clock and random generator.
- Data and typed `Decodable` loading APIs.
- Typed error mapping overloads (`errorMapper`).
- Batch loading helpers (`loadBatch`, `loadBatchResults`) with stable input order.
- Streaming helper (`loadStream`) with true incremental URLSession delivery on supported platforms.
- Server-Sent Events (`loadServerSentEvents`) with a spec-compliant, platform-independent parser,
  automatic reconnect, `Last-Event-ID` replay, and server-driven `retry:` timing.
- Multipart form-data uploads (`uploadMultipart`, `MultipartFormDataEncoder`) streamed from disk
  in fixed-size chunks, never buffering file parts fully in memory.
- File-based uploads (`upload(request:fromFile:...)`) streamed natively from disk via
  `URLSession.upload(for:fromFile:)`.
- Certificate pinning (`Transport.pinned`, `CertificatePinningPolicy`) with SPKI SHA-256 public
  key pins, backup pins for rotation, per-host allow/reject for unpinned hosts, and mutual TLS
  client certificate support (Apple platforms only).
- Request helpers (`APIRequestBuilder`, `Encodable` JSON body initializer).
- Idempotency helpers (`APIRequest.withIdempotencyKey`, `IdempotencyPolicy`).
- Cache management (`preload`, `invalidate`).
- Coalescer metrics (`hit/miss/cancellation/completion`) and observer events.
- Async event stream (`events() -> AsyncStream<NetworkClientEvent>`).
- In-flight diagnostics (`inFlightRequests()`).
- Optional telemetry hooks for tracing/metrics adapters, including coalescer, queue metrics, retry, retry exhaustion, cancellation, circuit-breaker transitions, and offline queue lifecycle callbacks.
- Extended telemetry fields for retry schedule source/profile/scope, retry-skipped reasons, and runtime policy update events.

## Quick Start

```swift
import Foundation
import NovaNetworkClient

let client = NetworkClient(
    transport: Transport(),
    retryPolicy: RetryPolicy(maxAttempts: 3)
)

let request = APIRequest(
    method: .get,
    url: URL(string: "https://example.com/api")!,
    queryItems: [URLQueryItem(name: "id", value: "42")],
    headers: ["Accept": "application/json"]
)

async let first = client.load(request: request, authScope: "user:42")
async let second = client.load(request: request, authScope: "user:42")

let (a, b) = try await (first, second)
print(a == b) // true
```

## Configuration

`NetworkClient.init` takes each option as a labeled argument, which reads well for a handful of
options. For configuring many options at once, build a `NetworkClientConfiguration` instead:

```swift
var configuration = NetworkClientConfiguration()
configuration.transport = Transport()
configuration.retryPolicy = RetryPolicy(maxAttempts: 3)
configuration.defaultCachePolicy = .cacheFirst(maxAge: 30)
configuration.middlewares = [authMiddleware]
configuration.telemetryHooks = hooks
configuration.addMiddleware(loggingMiddleware)

let client = NetworkClient(configuration: configuration)
```

The two initializers are equivalent and interchangeable; `NetworkClientConfiguration` is a plain
mutable value, so a base configuration can be built once and adapted per environment (for
example, per build configuration or test target) before constructing a client from it.

## v2.0 API Quick Start

```swift
import Foundation
import NovaNetworkClient

struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

let endpoint = AnyEndpoint<User>(
    request: APIRequest(
        method: .get,
        url: URL(string: "https://api.example.com/users/42")!
    )
)

let client = NetworkClient(
    httpAuthRefreshProvider: HTTPAuthRefreshProvider { scope in
        let token = try await credentials.refreshToken(for: scope)
        return ["Authorization": "Bearer \(token)"]
    }
)

let user = try await client.execute(endpoint: endpoint, authScope: "user:42")

let bodies = try await client.loadBatch(
    requests: requests,
    authScope: "user:42",
    batchOptions: .init(maxConcurrentRequests: 4)
)
```

## v2.1 Resumable Transfer Quick Start

```swift
import Foundation
import NovaNetworkClient

let transferRoot = FileManager.default.urls(
    for: .applicationSupportDirectory,
    in: .userDomainMask
)[0].appendingPathComponent("Transfers", isDirectory: true)

let journal = DiskTransferJournal(
    directoryURL: transferRoot.appendingPathComponent("journal", isDirectory: true)
)
let manager = ManagedTransferManager(
    journal: journal,
    partialDirectoryURL: transferRoot.appendingPathComponent("partial", isDirectory: true)
)

let handle = try await manager.startDownload(
    request: APIRequest(
        method: .get,
        url: URL(string: "https://cdn.example.com/archive.zip")!,
        headers: ["Authorization": "Bearer live-only"]
    ),
    to: transferRoot.appendingPathComponent("archive.zip"),
    destinationPolicy: .replace,
    options: .init(
        resume: .requiresValidator,
        integrity: .expectedSHA256(expectedDigest)
    )
)

for await event in handle.events {
    if case .completed(let snapshot) = event {
        print("Completed \(snapshot.id)")
    }
}
```

Call `manager.restore()` after relaunch, then pass a fresh authenticated `APIRequest` to
`resumeDownload` or `resumeUpload`. Request headers and credentials are deliberately not stored
in the journal. `ManagedTransferManager` uses the built-in TUS 1.0 strategy by default for
resumable uploads, or accepts a custom `ResumableUploadStrategy`.

For Apple background transfers, create a `BackgroundTransferCoordinator`, use a stable unique
background session identifier, and forward the host lifecycle callback:

```swift
let background = BackgroundTransferCoordinator(journal: journal)

let handle = try await background.scheduleDownload(
    request: request,
    to: destinationURL,
    options: .init(
        execution: .background(sessionIdentifier: "com.example.app.transfers"),
        integrity: .expectedByteCount(expectedBytes),
        networkPolicy: .init(
            allowsCellularAccess: false,
            isDiscretionary: true
        )
    )
)

// Forward from the app delegate's background URLSession callback.
await background.handleEvents(
    forSessionIdentifier: identifier,
    completionHandler: completionHandler
)
```

The app still owns platform entitlements and lifecycle forwarding. Background execution is
available on iOS and macOS; other platforms receive
`ManagedTransferError.backgroundTransfersUnavailable`.

For model-only targets, depend on and `import NovaNetworkCore`. Existing targets may continue
to import `NovaNetworkClient`, which re-exports the core public API.

## Declarative Endpoints (v2.11)

Two ways to stop hand-writing `makeRequest()`. Both produce ordinary `Endpoint` conformances, both
go through the same `EndpointRequestBuilder`, and they can be mixed with hand-written endpoints in
one target.

### The `@Endpoint` macro

Requires the opt-in `EndpointMacros` trait — see [Installation](#optional-the-endpoint-macro).

```swift
import NovaNetworkMacros

protocol PetstoreAPI: EndpointDefinition {}

extension PetstoreAPI {
    var baseURL: URL { URL(string: "https://api.petstore.example.com/v1")! }
}

@Endpoint(.get, "/pets/{petId}/photos", response: [Photo].self)
struct GetPetPhotos: PetstoreAPI {
    let petId: Int                            // fills {petId}: the name matches the placeholder
    var limit: Int?                           // unmarked, so it becomes ?limit=…
    @Query("sort_by") var sortBy: String?
    @Header("X-Trace") var trace: String?
}

@Endpoint(.post, "/pets", response: Pet.self)
struct CreatePet: PetstoreAPI {
    @Body var pet: NewPet
    @Header("Idempotency-Key") var idempotencyKey: String
}

let photos = try await client.execute(endpoint: GetPetPhotos(petId: 7, limit: 20), authScope: "petstore")
```

Each stored property takes one role, resolved in this order: an explicit `@Path`/`@Query`/`@Header`/
`@Body` marker, then a path parameter when the property name matches a `{placeholder}`, then a query
item under its own name. `baseURL`, `timeout`, `additionalHeaders`, and `jsonEncoder` are protocol
customization points and are never parameters; static and computed properties are ignored.

Behavior worth knowing, and identical for every declarative endpoint:

- a `nil` query item or header is omitted, never sent as the text `"nil"`; a `nil` path parameter is
  an error, since omitting it would change which resource the URL addresses;
- arrays repeat by default (`?tag=a&tag=b`); `@Query("tag", style: .commaSeparated)` sends `?tag=a,b`,
  alongside `.spaceDelimited` and `.pipeDelimited`;
- path values are percent-encoded against the unreserved set, so a value containing `/`, `?`, or `#`
  stays one segment.

Misuse is a diagnostic on the offending declaration, not a malformed expansion: a non-struct or
generic type, an interpolated path, an unfilled `{placeholder}`, a `@Path` with no matching
placeholder, two `@Body` properties, `@Body` on `GET`/`HEAD`, two markers on one property, or an
empty wire name.

### Generating from OpenAPI

```bash
swift package --allow-writing-to-package-directory nova-openapi \
  --spec openapi.yaml --output Sources/MyApp/GeneratedEndpoints.swift
```

The generator reads OpenAPI 3.0.x and 3.1.x as JSON or as a documented YAML subset, and writes one
`struct` per operation plus `Codable` models from `components/schemas`. Output is deterministic —
the same document always produces the same bytes — and depends only on `NovaNetworkCore`, so it
compiles with the macro trait disabled. Generated names come from `operationId`, or from the method
and path when there is none (`GET /pets/{petId}/photo` → `GetPetsByPetIdPhoto`).

```swift
let pets = try await client.execute(
    endpoint: ListPets(limit: 20, tags: ["kitten"]),
    authScope: "petstore",
    decoder: PetstoreAPI.makeDecoder()   // configured for the document's date format
)
```

Anything the generator cannot represent faithfully is a warning naming its location, never a silent
substitution: a multi-branch `oneOf`/`anyOf` falls back to a generated JSON value type, a recursive
schema is boxed as `Indirect<…>`, a payload with no JSON media type is skipped, and a document
without `servers` produces endpoints that take `baseURL` as an initializer parameter. Anchors,
aliases, tags, and multi-document YAML streams are rejected with a line and column rather than
guessed at. Credentials from `securitySchemes` never reach generated code.

A complete worked example — spec, checked-in output, and a runnable program — is in
[`Examples/OpenAPIPetstore`](Examples/OpenAPIPetstore).

## Record and Replay (v2.12)

Capture real traffic once, replay it forever. A cassette is a fixture with the fidelity of the real
exchange — the header casing, the null field, the error envelope nobody remembered — and the
determinism of a file.

```swift
import NovaNetworkCassette

try await withCassette(at: fixtureURL, upstream: Transport()) { transport in
    let client = NetworkClient(transport: transport)
    let user: User = try await client.load(request: request, authScope: nil)
    #expect(user.name == "Ada")
}
```

The first run performs the real request and writes the cassette; every run after is offline and
deterministic. `CassetteTransport` is an ordinary `NetworkTransport`, so coalescing, caching, retry,
middleware, and telemetry behave exactly as they do against a live server.

| Mode | Upstream contacted | Use it for |
|---|---|---|
| `.replay` | never | tests and demo builds that must not touch the network |
| `.record` | always | capturing a fresh recording |
| `.recordMissing` | only for unrecorded requests | day-to-day work: record once, replay after |

Matching defaults to **method plus full URL**, with query order ignored. Headers and bodies are
available but off by default: matching a header that carries a nonce or a trace id makes every
replay fail for a reason invisible in the file. Use `.methodAndPath`, `.includingBody`, or
`.matchingHeaders("Accept-Language")` when the identity really is different.

Repeated requests replay as **episodes** — first recording consumed first — so a polling or
pagination sequence stays a sequence. When they run out, the default errors; `.repeatLast` keeps
serving the final one.

**Credentials never reach the file.** Redaction runs as the exchange is captured, not as the file is
written. `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `X-API-Key`, and
`X-Auth-Token` are replaced by default; add your own headers, query items, or a body transform:

```swift
let redaction = CassetteRedaction.default
    .redacting(headers: "X-Tenant-Signature")
    .redacting(queryItems: "api_key")
```

The file is pretty-printed JSON with sorted keys, UTF-8 bodies stored as text, and no timestamps, so
re-saving an unchanged recording produces identical bytes and a real change shows up as a real diff.

`NovaNetworkCassette` is its own product depending only on `NovaNetworkCore`, so a preview or demo
build links it without a test-support module. Only completed HTTP exchanges are recorded — a
throwing transport is not an exchange — and streaming, SSE, and managed transfers are out of scope.

A runnable end-to-end demo is in [`Examples/Cassette`](Examples/Cassette).

## Diagnostics (v2.13)

The client already reports everything worth knowing. `DiagnosticsRecorder` is somewhere for it to
land:

```swift
import NovaNetworkDiagnostics

let recorder = DiagnosticsRecorder()
var configuration = NetworkClientConfiguration()
configuration.telemetryHooks = recorder.hooks
let client = NetworkClient(configuration: configuration)
recorder.startConsuming(client.events())
```

That is the whole installation — diagnostics is a consumer of the existing telemetry contract, so
nothing about the client changes.

One record per **logical request**, not per attempt. The client reports a start and an end for every
attempt and announces a retry only after the failed attempt ended; the recorder stitches those back
into the request a person actually made:

```
GET /flaky — 200 in 598 ms
  █████████████ Attempt 1
  ············ Backoff 185 ms
               ██████████████████████████ Attempt 2
               ·························· Backoff 399 ms
                                         █ Attempt 3
```

A record also carries the status or error, whether the request was coalesced, how the cache
answered, redacted headers, and body sizes.

**Failure means failure.** A transport that returns a 500 as a response has completed the exchange —
so the outcome case is `completed(status:)`, and `isFailure` covers any status from 400 up, a
transport error, or a cancellation. `failureRate` counts HTTP errors; a summary reading "0% failed"
next to a list of 500s would be worse than no summary.

**Bounded by construction.** 200 records by default, oldest dropped first, bodies capped at 64 KB
and flagged when truncated. Credentials are redacted as a record is built, not as it is exported.

```swift
let har = try await recorder.exportHAR()   // HAR 1.2 — opens in any browser's inspector
let summary = await recorder.summary()     // 4 requests · 50% failed · 25% coalesced
```

With `emitsSignposts` enabled, requests become `os_signpost` intervals with retries as point events,
so Instruments shows request spans next to CPU and allocations. `NetworkDiagnosticsView` presents the
same data on Apple platforms; everything it shows is computed by `DiagnosticsPanelState`, which is
plain Swift and testable anywhere.

This is a development and support tool, not production monitoring — `OpenTelemetryAdapter` remains
the path to a backend.

A runnable demo, including the waterfall above, is in [`Examples/Diagnostics`](Examples/Diagnostics),
and [`DemoApp`](DemoApp) is an iOS app that puts the panel on a device: five scenarios covering
retries, coalescing, cache, rejection, and cancellation, run either against a scripted transport
inside the app or as real HTTPS requests to an httpbin-compatible host.

### One clock, not one row at a time (v3.1)

A waterfall says where one request's time went. It cannot say what else was running — and
concurrency, coalescing, and queueing are properties of requests together. `DiagnosticsTimeline`
places every retained record on one window with a readable ruler, and the panel switches to it:

```
2.1 s total    0 ms      500 ms     1 s       1.5 s
GET /flaky     ▐█▌──▐█▌────▐█▌
GET /profile              ▐██▌
GET /settings                   ▐██▌
POST /orders                          ▐█▌
GET /slow                                  ▐████████   in flight
```

Two callers coalesced onto one request start on the same vertical line, a cache hit is a sliver, and
a retry storm is a row of bars with the backoff visible between them. A request still running is
drawn up to the moment the snapshot was read.

### Reading a HAR back (v3.1)

`HARImporter` is the other half of the export: it reads HAR 1.2 from any producer, and restores what
HAR has no field for — attempts, coalescing, cache outcome — when the file came from `HARExporter`.

```swift
await recorder.load(try HARImporter().import(Data(contentsOf: url)))
```

[`Inspector`](Inspector) is a macOS app built on those two lines: drop a HAR on it and read it with
the same panel a live app embeds.

## Authentication (v2.14)

The client already coordinates *when* to refresh. This supplies *what* to refresh with.

```swift
import NovaNetworkAuth

let oauth = OAuth2Client(configuration: OAuth2Configuration(
    clientID: "your-client-id",
    authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
    tokenEndpoint: URL(string: "https://auth.example.com/token")!,
    redirectURI: URL(string: "yourapp://callback")!,
    scopes: ["profile", "email"]
))
let authenticator = OAuth2Authenticator(client: oauth)

var configuration = NetworkClientConfiguration()
configuration.authRefreshProvider = authenticator.refreshProvider
configuration.middleware = [authenticator.middleware]
```

### The authorization code flow

```swift
let pkce = PKCEChallenge.generate()
let state = UUID().uuidString
let url = try oauth.authorizationURL(state: state, challenge: pkce)
// The app opens `url` and receives the callback.
let code = try oauth.authorizationCode(from: callbackURL, expectedState: state)
let token = try await oauth.exchange(code: code, verifier: pkce.verifier)
try await authenticator.setToken(token)
```

PKCE is always used: the verifier is 32 random bytes as base64url, the challenge its SHA-256, so an
intercepted code is useless without the secret that never left the device. The `state` check runs
**before** anything else is read and throws without returning the code — that check is what stops an
attacker's authorization code being redeemed in your user's session.

### Refresh once, not per caller

An actor alone is not enough: it suspends at the network call, so a second caller arriving mid-refresh
would start another. The authenticator shares the in-flight task, so eight simultaneous callers
produce **one** request to the provider.

Two details that are wrong more often than they are right, and are handled here:

- a refresh response usually omits `refresh_token`, meaning "keep the one you have" — dropping it is
  how a session dies an hour later for no visible reason;
- a token with no `expires_in` is never treated as expired, because guessing would refresh working
  credentials on a timer.

A refresh rejected with `invalid_grant` clears the stored token, so the app can ask for a sign-in
instead of failing identically forever.

### Device flow, storage, signing

```swift
let authorization = try await oauth.requestDeviceAuthorization()
print("Go to \(authorization.verificationURI) and enter \(authorization.userCode)")
let token = try await oauth.pollForToken(authorization)   // honors slow_down and authorization_pending
```

Tokens live in memory by default; `KeychainTokenStore` files them as generic passwords with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so they are reachable from a background refresh
and never sync to another device. For APIs that authenticate with a shared secret,
`HMACRequestSigner` signs over a documented canonical form and ships as middleware.

**Not included:** presenting a browser (it needs a window anchor the app owns) and AWS Signature
Version 4 (its correctness needs reference vectors; an unverified signer would look finished and be
dangerous). Both are stated rather than quietly missing.

A runnable walkthrough is in [`Examples/Authentication`](Examples/Authentication).
## Query Layer (v3.0)

`NetworkClient` answers "perform this request". A screen asks something else: *what is the current
state of this resource, and tell me when it changes.*

```swift
import NovaNetworkQuery

let queries = QueryClient()

let user: User = try await queries.value(for: QueryKey("users", 1)) {
    try await client.load(request: request, authScope: nil)
}
```

| Without | With |
|---|---|
| Two screens fetch the same list twice | One entry per key, one in-flight fetch per key |
| Pull-to-refresh blanks the list to a spinner | The old value stays visible, marked stale, while the refresh runs |
| A delete leaves the row on screen | The mutation invalidates the key and every screen updates |
| A failed optimistic edit stays applied | The exact previous value is restored |

### Rendering

```swift
for await state in await queries.states(for: QueryKey("users", 1), as: User.self) {
    switch state {
    case .idle, .loading(nil):            showSpinner()
    case let .loading(.some(user)),
         let .success(user, _):           show(user, stale: state.isStale)
    case let .failure(error, previous):   show(error, keeping: previous)
    }
}
```

Subscribers receive the current state first, so a screen arriving late is never blank. Errors are
part of the state rather than only thrown, so a view can render the problem beside the value it
already had. On iOS 17+, `ObservableQuery` wraps the same stream for SwiftUI — the only
availability-gated piece, because the package's floor stays at iOS 13.

### Mutating

```swift
try await queries.mutate(
    optimistic: [QueryKey("users", 1): editedUser],
    invalidating: [QueryKey("users", 1), "users"]
) {
    try await client.load(request: saveRequest, authScope: nil)
}
```

A failure restores the **exact captured snapshot**, not a reversed diff — the only approach that
stays correct when two mutations race. Keys are hierarchical, so `invalidate(prefix: "users")` marks
the whole family stale; entries with subscribers refetch immediately, and entries nobody is watching
are marked and left alone rather than spending the user's battery.

### Paging

```swift
let feed = PagedQuery<Post, String>(key: "feed", client: queries) { cursor in
    let page: FeedPage = try await client.load(request: feedRequest(after: cursor), authScope: nil)
    return QueryPage(elements: page.posts, nextCursor: page.next)
}
let posts = try await feed.loadNextPage()   // everything so far, not just the new page
```

**Not included:** a normalized entity cache (values are stored by key, not merged into a graph) and
persistence (the offline queue remains the durable path for writes).

A runnable demo is in [`Examples/Query`](Examples/Query).

## Preset Quick Start (v1.15)

```swift
import Foundation
import NovaNetworkClient

let preset = NetworkClientPreset.offlineFirst

let client = NetworkClient(
    transport: Transport(),
    retryPolicy: preset.retryPolicy,
    defaultCachePolicy: preset.defaultCachePolicy,
    offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
)

await client.applyRuntimePolicy(from: preset)

let safeOptions = preset.requestOptions(
    overrides: .init(
        priority: .high,
        rateLimitPolicy: RateLimitPolicy(maxRequests: 6, intervalSeconds: 1)
    )
)

let payload = try await client.load(
    request: request,
    authScope: "user:42",
    options: safeOptions
)
```

## DX 2.0 Production Profile Quick Start (v1.19)

```swift
import Foundation
import NovaNetworkClient

let profile = NetworkClientProductionProfileGenerator().generate(
    goal: .offlineFirst,
    overlays: [.offlineDurability, .strictReliability],
    offlineStoreConfigured: true
)

guard profile.validation.isProductionReady else {
    for issue in profile.validation.issues {
        print("[\(issue.severity.rawValue)] \(issue.code): \(issue.message)")
    }
    fatalError("Fix production validation issues before rollout.")
}

let preset = profile.composedPreset
let client = NetworkClient(
    transport: Transport(),
    retryPolicy: preset.retryPolicy,
    defaultCachePolicy: preset.defaultCachePolicy,
    offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
)
await client.applyRuntimePolicy(from: preset)
```

## Examples

### 1) Typed GET Request

```swift
struct UserProfile: Decodable, Sendable {
    let id: Int
    let name: String
}

let request = APIRequest(
    method: .get,
    url: URL(string: "https://api.example.com/profile")!,
    queryItems: [URLQueryItem(name: "id", value: "42")]
)

let profile: UserProfile = try await client.load(
    request: request,
    authScope: "user:42"
)
```

### 2) POST With Idempotency + Offline Queue

```swift
let createItem = APIRequest(
    method: .post,
    url: URL(string: "https://api.example.com/items")!,
    body: Data("{\"name\":\"draft\"}".utf8)
)
.withIdempotencyKey("create-item-user-42")

let result = try await client.enqueueWrite(
    request: createItem,
    authScope: "user:42",
    options: .init(offlineQueuePolicy: .init(mode: .enqueueWhenOffline))
)

switch result {
case .completed:
    print("Request sent immediately")
case .queued(let receipt):
    print("Saved for replay: \\(receipt.queueID)")
}
```

### 3) Observe Runtime Events

```swift
let stream = client.events()

Task {
    for await event in stream {
        print("event:", event)
    }
}
```

### 4) Offline-First Sync Policy (v1.14)

```swift
let queuePolicy = OfflineQueuePolicy(
    mode: .enqueueWhenOffline,
    replayPriority: .critical,
    replaySchedulerPolicy: .init(
        fairReplayWeights: [.critical: 4, .normal: 2, .background: 1],
        starvationProtectionAgeSeconds: 120,
        priorityBandLimits: [
            .init(priority: .critical, maxConsecutiveReplays: 8),
            .init(priority: .normal, maxConsecutiveReplays: 4),
            .init(priority: .background, maxConsecutiveReplays: 2)
        ],
        replayWindow: .init(
            maxContinuousReplaySeconds: 20,
            coolDownSeconds: 1,
            maxReplaysPerSecond: 10
        )
    ),
    replayConflictPolicy: .manualReview
)

let client = NetworkClient(
    transport: Transport(),
    offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL),
    offlineConflictResolver: { metadata in
        if metadata.statusCode == 409 {
            return .manualReview(reason: "server_conflict_requires_review")
        }
        return .retry(afterSeconds: nil)
    }
)

_ = try await client.enqueueWrite(
    request: createItem,
    authScope: "user:42",
    options: .init(offlineQueuePolicy: queuePolicy)
)
```

### 5) Manual-Review Replay and Metrics

```swift
let snapshot = await client.offlineQueueSnapshot()
if let manualItem = snapshot.first(where: { $0.state == .manualReview }) {
    let requeued = await client.replayManualReviewItem(
        queueID: manualItem.receipt.queueID,
        resolutionReason: "resolved_in_ui"
    )
    print("Requeued:", requeued)
}

let metrics = await client.offlineQueuePipelineMetrics()
print(metrics.queueDepth)
print(metrics.ageDistribution.p90Seconds)
print(metrics.ageDistribution.p95Seconds)
print(metrics.replayThroughput.replaysPerSecond)
print(metrics.terminalOutcomes)
```

### 6) Encryption Rotation for Offline Store

```swift
let rotated = await client.rotateOfflineQueueEncryption()
print("Rewritten encrypted records:", rotated)
```

## Cache Policy

```swift
let client = NetworkClient(defaultCachePolicy: .cacheFirst(maxAge: 5))
let data = try await client.load(
    request: request,
    authScope: "user:42",
    cachePolicy: .staleWhileRevalidate(maxAge: 2, staleAge: 30)
)
```

## Disk Cache

```swift
let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NovaNetworkClientCache")

let client = NetworkClient(
    transport: Transport(),
    cache: DiskResponseCache(directoryURL: cacheURL),
    defaultCachePolicy: .cacheFirst(maxAge: 30)
)
```

## Per-Request Options

```swift
let data = try await client.load(
    request: request,
    authScope: "user:42",
    options: RequestExecutionOptions(
        coalescerLimitsOverride: .init(maxInFlightKeys: 8),
        priority: .high,
        capacityScheduling: .queueByPriority,
        coalescingMode: .custom("feed:primary"),
        deadlineBudgetSeconds: 2.0,
        circuitBreakerPolicy: CircuitBreakerPolicy(
            scope: .host,
            failureThreshold: 3,
            cooldownSeconds: 10
        )
    )
)
```

## Runtime Policy Updates

```swift
await client.updateRuntimePolicy(
    .init(
        retryPolicy: RetryPolicy(
            maxAttempts: 3,
            adaptiveProfiles: [
                .rateLimited: .init(maxAttempts: 2, baseDelayNanoseconds: 1_000_000_000, jitterRange: nil)
            ]
        )
    ),
    scope: .host("api.example.com")
)

await client.updateRuntimePolicy(
    .init(deadlineBudgetSeconds: 0.5),
    scope: .endpoint(host: "api.example.com", pathPrefix: "/critical")
)

// Dedupe TTL control for coalescing windows (endpoint > host > global).
await client.updateRuntimePolicy(
    .init(coalescingPolicy: .init(dedupeTTLSeconds: 30)),
    scope: .host("api.example.com")
)

// Runtime circuit breaker tuning (threshold/cooldown/probe policy).
await client.updateCircuitBreakerRuntimePolicy(
    .init(
        scope: .host,
        failureThreshold: 5,
        cooldownSeconds: 8,
        probePolicy: .parallelProbes(maxConcurrent: 2)
    ),
    scope: .host("api.example.com")
)

// Runtime fairness scheduler tuning for queued coalescer capacity.
await client.updateCoalescerSchedulerPolicy(
    .init(highWeight: 4, mediumWeight: 2, lowWeight: 1)
)
```

## Middleware

```swift
let authMiddleware = NetworkMiddleware(
    beforeSend: { request, _ in
        request.withMergedHeaders(["Authorization": "Bearer token"])
    }
)

let client = NetworkClient(
    transport: Transport(),
    middlewares: [authMiddleware]
)
```

## Rate Limiting

```swift
let data = try await client.load(
    request: request,
    authScope: "user:42",
    options: .init(
        rateLimitPolicy: .init(maxRequests: 5, intervalSeconds: 1)
    )
)
```

## Offline Queue (Write Requests)

```swift
let queueURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("NovaNetworkClientOfflineQueue")

let client = NetworkClient(
    transport: Transport(),
    offlineWriteStore: DiskOfflineWriteStore(
        directoryURL: queueURL,
        cipher: AESGCMOfflineWriteStoreCipher(
            keyProvider: {
                // Provide 16/24/32-byte key material from secure storage.
                Data(repeating: 7, count: 32)
            }
        )
    )
)

let writeRequest = APIRequest(
    method: .post,
    url: URL(string: "https://api.example.com/items")!,
    body: Data("{\"name\":\"draft\"}".utf8)
)

let result = try await client.enqueueWrite(
    request: writeRequest,
    authScope: "user:42",
    options: .init(
        idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
        offlineQueuePolicy: .init(
            mode: .enqueueWhenOffline,
            maxReplayAttempts: 5,
            replayConflictPolicy: .manualReview,
            replayDedupeWindowSeconds: 24 * 60 * 60
        )
    )
)

switch result {
case .completed(let body):
    print("sent now:", body.count)
case .queued(let receipt):
    print("queued:", receipt.queueID)
}

let replayed = await client.flushOfflineQueue()
print("replayed:", replayed)
```

Replay behavior knobs:
- `maxReplayAttempts`: terminal threshold before conflict handling path.
- `replayConflictPolicy`:
  - `.retry`: keep entry in retry flow.
  - `.drop`: drop terminal conflict from queue.
  - `.manualReview`: keep entry with manual-review state.
- `replayDedupeWindowSeconds`: suppress replay if same replay identity already succeeded in window.

Queue management helpers:

```swift
let depth = await client.offlineQueueDepth()
let snapshot = await client.offlineQueueSnapshot()
if let first = snapshot.first {
    _ = await client.dropQueuedWrite(queueID: first.receipt.queueID)
}
_ = await client.dropAllQueuedWrites()
```

Offline queue event stream:

```swift
for await event in client.offlineQueueEvents() {
    print(event)
}
```

## Streaming

```swift
for try await chunk in client.loadStream(request: request, authScope: "user:42") {
    print("chunk bytes:", chunk.count)
}
```

## Server-Sent Events

```swift
let events = client.loadServerSentEvents(
    request: APIRequest(method: .get, url: URL(string: "https://api.example.com/stream")!),
    authScope: "user:42"
)

for try await event in events {
    print(event.event, event.data)
}
```

By default the stream reconnects automatically after the connection ends or fails, resending a
`Last-Event-ID` header once the server has provided one and honoring any `retry:` field the
server sends. Pass `reconnectPolicy: .disabled` for a single-attempt stream, or tune
`SSEReconnectPolicy(maxAttempts:defaultDelayNanoseconds:maxDelayNanoseconds:)` for bounded
reconnection. Requires a transport that implements `ServerSentEventTransport` (the default
``Transport`` does); other transports fail immediately with
`ServerSentEventError.transportUnsupported`.

The wire-format parser (`SSEDecoder`, `SSELineParser`) lives in `NovaNetworkCore` and has no
platform dependencies, so it is usable standalone (for example against a custom transport) on
every supported platform, including Linux.

## WebSocket (MVP)

```swift
let socket = WebSocketClient(
    configuration: WebSocketConfiguration(
        url: URL(string: "wss://ws.postman-echo.com/raw")!,
        headers: ["Authorization": "Bearer token"],
        outboundQueuePolicy: .init(maxQueuedMessages: 100, overflowPolicy: .dropOldest),
        ackPolicy: .init(
            dedupeWindowNanoseconds: 120_000_000_000,
            maxTrackedMessageIDs: 2_048,
            maxResendAttempts: 1
        ),
        authRefreshPolicy: .init(maxAttempts: 1),
        subscriptionReplayPolicy: .init(maxAttemptsPerSubscription: 2, retryDelayNanoseconds: 100_000_000)
    ),
    authRefreshProvider: .init(
        refreshHeaders: {
            ["Authorization": "Bearer refreshed-token"]
        }
    )
)

let stateStream = await socket.connectionStates()
Task {
    for await state in stateStream {
        print("ws state:", state)
    }
}

let messageStream = await socket.messages()
Task {
    for try await message in messageStream {
        print("ws message:", message)
    }
}

try await socket.connect()
try await socket.send(
    .text("{\"type\":\"ping\"}"),
    options: .init(requiresAck: true, messageID: "ping-1", ackTimeoutNanoseconds: 5_000_000_000)
)
await socket.registerSubscription(
    id: "orders-stream",
    message: .text("{\"type\":\"subscribe\",\"channel\":\"orders\"}")
)
let health = await socket.connectionHealth()
print("ws health:", health)
let diagnostics = await socket.webSocketDiagnostics()
print("ws queue depth:", diagnostics.queuedOutboundMessages)
print("ws queue pressure:", diagnostics.queuePressureLevel)
print("ws ack age buckets:", diagnostics.ackPendingAgeBuckets)
print("ws reconnect phase:", diagnostics.reconnectPhase, diagnostics.lastTransitionReason ?? "n/a")
await socket.forceReconnect(reason: "manual_recovery")
await socket.disconnect(reason: "done")
```

You can override ACK parsing for custom backend protocols:

```swift
let socket = WebSocketClient(
    configuration: .init(url: URL(string: "wss://example.com/ws")!),
    ackMatcher: .init { message in
        guard case .text(let value) = message, value.hasPrefix("ACK|") else { return nil }
        return String(value.dropFirst(4))
    }
)
```

For connectivity-aware reconnect suppression/resume, pass `connectivityMonitor` (`OfflineConnectivityMonitor`) when creating `WebSocketClient`.

For durable outbound buffering across app restarts, pass `outboundQueueStore` (for example `DiskWebSocketOutboundQueueStore`).

For optional subscription restore after reconnect, register subscriptions via `registerSubscription(id:message:options:)`.

`WebSocketDiagnostics` also includes queue pressure, ACK pending age buckets, and reconnect phase/reason snapshots for incident triage.

## In-Flight Diagnostics

```swift
let inFlight = await client.inFlightRequests()
print(inFlight.map(\.key))
```

## Sharing the Offline Queue with Extensions (v3.4)

A share extension is a separate process with its own container: a write queued there is invisible to
the app. The only directory both can see is the App Group container — and the moment they both use
it, the actor protecting the queue stops being enough, because an actor serialises one process and
these are two.

```swift
let directory = try AppGroupContainer.directory(
    forAppGroup: "group.com.example.app",
    subdirectory: "offline-queue"
)
configuration.offlineWriteStore = CoordinatedOfflineWriteStore(
    wrapping: DiskOfflineWriteStore(directoryURL: directory),
    lock: CrossProcessFileLock(url: directory.appendingPathComponent(".lock"))
)
```

`CrossProcessFileLock` is `flock` on a lock file, taken **without blocking** and retried — the
blocking form would park the cooperative thread it runs on and stall every other request in the
process while a different process worked. It is a value type rather than an actor because it holds
no mutable state: the mutual exclusion lives in the filesystem.

`CoordinatedOfflineWriteStore` is a decorator, so the existing store keeps behaving exactly as it did
and anything conforming to `OfflineWriteStore` can be wrapped the same way.

Two things worth knowing before adopting. The lock is **advisory**: a process that writes the
directory without taking it is not stopped. And the platforms disagree about a missing entitlement —
iOS reports it, macOS hands back a container path regardless, so there the mistake only surfaces
when something tries to write. See [What's New 3.4](docs/WHATS_NEW_v3.4.md).

## Network Path Policies (v3.3)

Reachability answers one bit: can we reach anything. That bit cannot tell a metered hotspot from
home Wi-Fi, so it cannot decide whether to start a 40 MB upload — and a phone with Low Data Mode on
is still "connected".

```swift
var configuration = NetworkClientConfiguration()
configuration.networkPathMonitor = SystemNetworkPathMonitor()   // reads Network.framework
configuration.networkPathPolicy = .respectMeteredPaths
```

Off by default: with no policy the client never looks at the path.

Three answers rather than two. `send` goes now, `fail` does not go and is not kept, and
`deferUntilPathImproves` does not go now but is kept — reaching the **existing** offline queue,
because a deferral is reported as the `URLError` that queue already recognises. A failure carries
`NetworkPathRestrictionError`, which it does not, so it propagates.

```swift
try await client.load(request: signIn, authScope: nil, options: .init(isEssential: true))
```

Essential requests pass a metered or constrained path — a policy that also blocked the sign-in would
be a policy nobody could adopt. And Low Data Mode outranks the cost guess: `isConstrained` is the
user saying "use less data here", `isExpensive` is an inference about the link.

`SystemNetworkPathMonitor` translates `NWPath` and decides nothing, so policies stay testable on a
machine with no cellular interface:

```swift
configuration.networkPathMonitor = StaticNetworkPathMonitor(
    NetworkPath(status: .satisfied, interfaces: [.cellular], isExpensive: true)
)
```

The policy is consulted once, when the request starts; see
[What's New 3.3](docs/WHATS_NEW_v3.3.md) for the rest of the edges.

## Benchmark Baseline Check

```bash
swift run NovaNetworkClientBenchmarks --check-baseline
```

## Stress Benchmark Suite

```bash
swift run NovaNetworkClientBenchmarks --stress-suite
swift run NovaNetworkClientBenchmarks --check-stress-baseline
```

The stress baseline includes a combined offline-replay + realtime request pressure scenario.

### What the baselines enforce, and what they only report

Both checks run in CI, and they draw a line through the numbers they print:

- **Enforced** — everything the code decides and that holds on any machine: how many calls the
  transport saw, retry-storm outcomes, breaker transitions, replay counts. A change to coalescing,
  retry, or caching moves these, and moving them fails the build.
- **Advisory** — elapsed time, p95/p99 latency, and allocation deltas. On a shared CI runner these
  are as much a property of the machine as of the code, so they are printed and reported as
  `baseline_check=passed_with_advisory` rather than failing. A budget that fails because a
  neighbouring job was busy teaches a team to ignore the gate.

Pass `--strict-timing` to enforce the timing budgets too, which is what you want on dedicated
hardware:

```bash
swift run NovaNetworkClientBenchmarks --check-baseline --strict-timing
```

Asking for a check and not being able to perform it is a failure: if `Benchmarks/baseline.json`
cannot be read — which is what happens when the benchmark is run from outside the repository root —
the check exits non-zero rather than reporting success without having compared anything.

## Deterministic Chaos Suite

```bash
swift test --filter OfflineQueueCoverageTests
swift test --filter connectivityFlapSequenceQueuesOfflineWritesAndRecoversOnFlush
```

`OfflineStoreRecoveryReport` includes `orphanedTemporaryRecords`, `corruptionBudgetExceeded`, and `recoveryLossRate` for provable recovery-loss accounting.

## Multipart Form Data

```swift
let result = client.uploadMultipart(
    url: URL(string: "https://api.example.com/items")!,
    parts: [
        .text(name: "title", value: "My upload"),
        .file(name: "photo", filename: "photo.jpg", contentType: "image/jpeg", fileURL: photoURL),
    ],
    authScope: "user:42"
)

for try await event in result {
    switch event {
    case .progress(let progress):
        print("uploaded:", progress.completedBytes)
    case .completed(let response):
        print("status:", response.statusCode)
    }
}
```

`.file` parts are streamed from disk in fixed-size chunks and are never fully buffered in
memory, regardless of file size. `Content-Type` defaults to `multipart/form-data;
boundary=...` unless already supplied in `headers`.

`uploadMultipart` is a convenience over `MultipartFormDataEncoder`, which can also be used
directly: `write(to:)` streams the encoded body to any file you choose, and `contentType`
returns the matching header value. That decouples encoding from transport, so the same encoded
file can be handed to any file-based upload path, including a durable/resumable one, instead of
`uploadMultipart`'s own upload-then-delete-temp-file flow.

## Request Builder

```swift
let request = try APIRequest
    .builder(method: .post, url: URL(string: "https://example.com/api")!)
    .header("Accept", "application/json")
    .jsonBody(["name": "Max"])
    .build()
```

## Typed Decoding

```swift
struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

let user: User = try await client.load(
    request: request,
    authScope: "user:42"
)
```

## Response Decoding Strategies

`load<T: Decodable>` and `Endpoint.decode(_:using:)` always use a fixed `JSONDecoder` — the
existing default, unchanged. For a decoder that needs to see response headers (most commonly to
pick a strategy by `Content-Type`), use `ResponseDecoding` instead:

```swift
let decoding = ContentTypeNegotiatingResponseDecoding(
    decodersByMediaType: [
        "application/xml": MyXMLResponseDecoding()
    ]
    // falls back to JSONResponseDecoding() for any other Content-Type
)

let user: User = try await client.decode(
    request: request,
    authScope: "user:42",
    responseDecoding: decoding
)
```

Set `configuration.responseDecoding` on a `NetworkClientConfiguration` for a client-wide default
strategy, used whenever a call to `decode(request:...)` does not supply its own. `decode` and its
companion `loadResponse(request:authScope:options:)` (which returns the full response — status,
headers, and body — instead of just `Data`) always bypass the response cache, matching
`cachePolicy: .networkOnly`.

## Fingerprint Policy

By default, fingerprint includes method, canonical URL + query, canonical JSON body digest, headers digest, and auth scope digest.

```swift
let policy = FingerprintPolicy(
    includeQueryItems: true,
    includeBody: true,
    headerInclusion: .allowlist(["Accept", "Content-Type"])
)

let client = NetworkClient(
    transport: Transport(),
    fingerprintPolicy: policy
)
```

## Certificate Pinning and Mutual TLS (Apple platforms)

```swift
let policy = CertificatePinningPolicy(
    pinsByHost: [
        "api.example.com": [
            "4UgYzKuqOyIb7kHr8BLRmzF7nVf1ZLld+MPOVlPZSxA=", // primary
            "X9ow7ZHXqNUe817kCZu4lYmsTgZz4xM5956G5xkLbcw=", // backup, for rotation
        ]
    ],
    unpinnedHostPolicy: .allowDefaultEvaluation
)

let transport = Transport.pinned(
    policy: policy,
    onValidation: { event in
        print("pinning:", event.host, event.outcome)
    }
)

let client = NetworkClient(transport: transport)
```

Pins are base64 SPKI SHA-256 digests, matching:

```bash
openssl x509 -in cert.pem -pubkey -noout \
  | openssl pkey -pubin -outform DER \
  | openssl dgst -sha256 -binary \
  | openssl base64
```

Configuring more than one pin per host allows certificate/key rotation without an app update:
a connection succeeds as soon as any certificate in the chain matches any configured pin. Hosts
without configured pins follow `unpinnedHostPolicy` (`allowDefaultEvaluation` or `reject`); the
platform's own trust evaluation still runs first for pinned hosts, so a connection must satisfy
both the system trust store and the pin.

For mutual TLS, supply a `ClientCertificateProvider`:

```swift
let transport = Transport.pinned(
    policy: policy,
    clientCertificateProvider: .fixed(
        ClientCertificateIdentity(identity: mySecIdentity)
    )
)
```

This functionality depends on the `Security` framework and is available on Apple platforms only.

## Behavior Contract

| Scenario | Behavior |
|---|---|
| Same key, concurrent callers | One underlying operation executes; all waiters share result |
| Same key, next request after completion | New operation starts |
| `cancelWhenNoWaiters`, one waiter cancels | Operation continues while at least one waiter remains |
| `cancelWhenNoWaiters`, all waiters cancel | Underlying task is cancelled |
| `keepRunning`, all waiters cancel | Underlying task continues until completion |
| Retriable error + attempts remaining | Retries with exponential backoff (optional jitter) |
| Non-idempotent request without idempotency key | No retry by default (can be overridden in `RetryPolicy`) |
| Non-retriable error | Fails immediately |
| Deadline budget exhausted | Request fails with timeout budget error and no additional retry attempt |
| `coalescingMode: .disabled` | Identical concurrent requests execute independently |

## Error Handling

`NetworkError` conforms to `Equatable` and `LocalizedError`:

```swift
catch let error as NetworkError {
    print(error.localizedDescription) // "The server returned HTTP status 429."
    #expect(error == .clientRateLimited(retryAfterSeconds: 30)) // usable directly in test assertions
}
```

`Equatable` cases wrapping an underlying error (`.decoding`, `.transport`,
`.authenticationRefreshFailed`) compare that error by dynamic type and description, since `any
Error` has no general equality contract; treat this as a best-effort comparison for tests and
deduplication, not a guarantee of true value identity.

For request and attempt context (URL, method, attempt number, auth scope) without changing
`NetworkError`'s own cases, wrap it with `NetworkErrorContext` — directly, or automatically via
`loadWithContext`:

```swift
do {
    let data = try await client.loadWithContext(request: request, authScope: "user:42")
} catch let error as ContextualNetworkError {
    logger.error("\(error.localizedDescription)") // includes the request's method, URL, attempt
    reportToCrashlytics(error.error, context: error.context)
}
```

## Observability

Use observer events, telemetry hooks, or the OpenTelemetry adapter layer:

```swift
let exporter = MyOpenTelemetryExporter() // implements OpenTelemetryExporting
let adapter = OpenTelemetryAdapter()
let client = NetworkClient(
    transport: Transport(),
    telemetryHooks: adapter.makeHooks(exporter: exporter)
)

let pipeline = await client.offlineQueuePipelineMetrics()
adapter.emitPipelineMetrics(
    pipeline,
    exporter: exporter,
    attributes: ["scope": .string("global")]
)
```

Observability Contract v2 payloads include top-level `event_version` and `contract_version`.
Default values are `2` and `"2.0"`.

## Batch Loading

```swift
let responses = try await client.loadBatch(
    requests: [requestA, requestB, requestC],
    authScope: "user:42"
)
```

## Testing Your Code

`NovaNetworkClientTestSupport` is a separate product for testing code that uses
`NovaNetworkClient`, without a real server.

```swift
import NovaNetworkClientTestSupport

let router = RoutingTransport()
await router.register(.method(.get) && .pathPrefix("/users/"), statusCode: 200, body: userJSON)
await router.register(.method(.post) && .path("/users")) { request in
    NetworkResponse(statusCode: 201, headers: [:], body: request.body ?? Data())
}

let client = NetworkClient(transport: router)
```

`RoutingTransport` dispatches each request to the first registered route whose `RequestMatcher`
matches (`.method`, `.path`, `.pathPrefix`, `.host`, `.header`, `.bodyContains`, `.url`, combined
with `&&`/`||`); an unmatched request throws `RoutingTransportError` naming the method and URL,
rather than hanging or returning a misleading default.

For resilience testing, wrap any transport with randomized failures and latency:

```swift
let chaos = ChaosTransport(
    wrapping: router,
    policy: ChaosPolicy(failureRate: 0.3, delayRange: 0...200_000_000),
    randomGenerator: TestRetryRandom(value: 0.5) // deterministic for reproducible runs
)
```

For deterministic timing assertions, `VirtualClock` (a `RetryClock`) genuinely suspends callers
until you explicitly advance virtual time:

```swift
let clock = VirtualClock()
let client = NetworkClient(transport: transport, retryPolicy: policy, retryClock: clock)

let task = Task { try await client.load(request: request, authScope: nil) }
await clock.advanceToNextDeadline() // releases the first retry's backoff sleep
```

`TelemetryRecorder` records every event a client's `NetworkTelemetryHooks` emits, for asserting
on retries, coalescing, cancellations, and other lifecycle events instead of re-deriving them
from side effects:

```swift
let recorder = TelemetryRecorder()
let client = NetworkClient(transport: transport, telemetryHooks: await recorder.makeHooks())

_ = try await client.load(request: request, authScope: nil)
await waitUntil { await recorder.requestEndCount() == 1 } // hooks record asynchronously
```

`MockTransport` and `ScriptedTransport` (a single fixed response, and an ordered sequence of
responses, regardless of request content) remain available for simpler cases that don't need
routing.

## Run Tests

```bash
swift test
```

## Run E2E Tests (Optional)

E2E tests use public APIs (`jsonplaceholder.typicode.com`, `httpbin.org`) and are disabled by default.
E2E suite policy: only real public APIs are allowed; mocks/stubs are not allowed in E2E tests.
Scenarios include typed load, coalescing, batch loading, cache hit path, middleware, stream fallback, offline queue enqueue/flush/drop, rate limit, error mapping, runtime policy updates, circuit breaker, and invalidation paths.

```bash
RUN_E2E_TESTS=1 swift test --filter E2ECoverageTests
```

## Linux Compatibility

`NovaNetworkCore` has a Linux CI guarantee (Ubuntu, Swift 6.2.3, strict concurrency). Full
`NovaNetworkClient` Linux support is a work in progress: it has never run on Linux before this
was added, so this section describes what has been *audited and gated*, not what has been
*proven working* — the CI job below is the actual verification going forward.

- Apple-only APIs are behind explicit availability gates: certificate pinning and mTLS
  (`Security`, `#if canImport(Security)`) and the offline queue's optional AES-GCM encryption
  cipher (`CryptoKit`, `#if canImport(CryptoKit)`) simply aren't available where those frameworks
  aren't; everything else in `NovaNetworkClient` — coalescing, retry, circuit breaker, rate
  limiting, caching, the offline queue itself (without that one optional cipher), batching,
  fingerprinting, WebSocket — does not depend on either.
- Request/cache-key fingerprinting no longer requires `CryptoKit`: `SHA256Util` uses a
  from-scratch, dependency-free SHA-256 implementation (verified against the NIST SHA-256 test
  vectors, including a streaming variant fed non-block-aligned chunks) when `CryptoKit` isn't
  available, so this core, non-optional behavior isn't gated behind an Apple-only framework.
  Encryption (as opposed to fingerprinting) remains `CryptoKit`-only rather than a hand-rolled
  authenticated cipher — the security cost of getting that wrong is not a risk worth taking.
- A new CI job (`linux-client-build-gate`) compiles `NovaNetworkClient` and
  `NovaNetworkClientTestSupport` on Ubuntu with Swift 6.2.3. It's compile-only for now — running
  the test suite on Linux is a separate, unverified step.

## License

This project is licensed under the Apache License, Version 2.0.
See [LICENSE](LICENSE) for details.
