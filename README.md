# NovaNetworkClient

`NovaNetworkClient` is a Swift library for deduplicating concurrent requests with the same logical identity.

When multiple callers ask for the same resource at the same time, only one underlying operation runs and all callers await the shared result.

## Documentation

- [Setup & Usage Guide](docs/SETUP_GUIDE.md)
- [Unit Test Policy](docs/UNIT_TEST_POLICY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Examples](Examples/README.md)
- [Telemetry Contract v2](docs/TELEMETRY_CONTRACT_V2.md)
- [NovaNetwork v2.0 DFR](docs/dfr/NOVA_NETWORK_V2_DFR.md)
- [v2.0 Traceability Pack](docs/TRACEABILITY_PACK_v2.0.md)
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
    .package(url: "https://github.com/your-org/NovaNetworkClient.git", from: "1.0.0")
]
```

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "NovaNetworkClient", package: "NovaNetworkClient")
        ]
    )
]
```

## Features

- Typed `Endpoint<Response>` execution with endpoint-specific decoding.
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
- Single-flight HTTP authentication refresh, isolated by authentication scope.
- Standalone cross-platform `NovaNetworkCore` product for request/response/error/endpoint models.
- HTTP Cache 2.0 with ETag and Last-Modified revalidation, corrected age, request directives,
  `stale-if-error`, and safe `Vary: *` handling.
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

For model-only targets, depend on and `import NovaNetworkCore`. Existing targets may continue
to import `NovaNetworkClient`, which re-exports the core public API.

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

## Benchmark Baseline Check

```bash
swift run NovaNetworkClientBenchmarks --check-baseline
```

## Stress Benchmark Suite

```bash
swift run NovaNetworkClientBenchmarks --stress-suite
swift run NovaNetworkClientBenchmarks --check-stress-baseline
```

Stress baseline now includes a combined offline-replay + realtime request pressure scenario.

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

## License

This project is licensed under the Apache License, Version 2.0.
See [LICENSE](LICENSE) for details.
