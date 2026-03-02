# NovaNetworkClient

`NovaNetworkClient` is a Swift library for deduplicating concurrent requests with the same logical identity.

When multiple callers ask for the same resource at the same time, only one underlying operation runs and all callers await the shared result.

## Documentation

- [Setup & Usage Guide](docs/SETUP_GUIDE.md)
- [Unit Test Policy](docs/UNIT_TEST_POLICY.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Examples](Examples/README.md)
- [v1.15 Traceability Pack](docs/TRACEABILITY_PACK_v1.15.md)

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

- Coalesces concurrent requests by stable fingerprint key.
- Optional short-lived in-memory response cache (`cacheFirst`, `staleWhileRevalidate`).
- Optional pluggable response cache (`MemoryResponseCache`, `DiskResponseCache`, custom `ResponseCache`).
- HTTP cache revalidation with `ETag` / `If-None-Match` (returns cached body on `304 Not Modified`).
- Basic HTTP cache directive support (`Cache-Control`, `Expires`, `Vary`) for freshness and variant checks.
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
- Safe preset override points via `NetworkClientPreset.RequestOverrides` (merge-only overrides).
- Testable retry behavior via injectable clock and random generator.
- Data and typed `Decodable` loading APIs.
- Typed error mapping overloads (`errorMapper`).
- Batch loading helper (`loadBatch`) with stable input order.
- Streaming helper (`loadStream`) with fallback to single-chunk mode.
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

Use observer events or metrics snapshot:

```swift
let client = NetworkClient(
    transport: Transport(),
    observer: { event in
        print(event)
    }
)

let metrics = await client.coalescerMetrics()
print(metrics.coalescedHits)
```

## Batch Loading

```swift
let responses = try await client.loadBatch(
    requests: [requestA, requestB, requestC],
    authScope: "user:42"
)
```

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

This project is licensed under the GNU General Public License v3.0.
See [LICENSE](LICENSE) for details.
