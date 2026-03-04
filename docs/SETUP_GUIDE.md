# NovaNetworkClient Setup & Usage Guide

This guide covers full setup and practical usage of `NovaNetworkClient`.

## Table of Contents

1. [Requirements](#requirements)
2. [Installation (SwiftPM)](#installation-swiftpm)
3. [Minimal Setup](#minimal-setup)
4. [Production Profile Generator (DX 2.0)](#production-profile-generator-dx-20)
5. [Building Requests](#building-requests)
6. [Loading Raw Data](#loading-raw-data)
7. [Loading Decodable Models](#loading-decodable-models)
8. [How Coalescing Works](#how-coalescing-works)
9. [Cancellation Policies](#cancellation-policies)
10. [Fingerprint Policy](#fingerprint-policy)
11. [Retry Policy](#retry-policy)
12. [Cache Policies](#cache-policies)
13. [Offline Queue (Write Requests)](#offline-queue-write-requests)
14. [Observability (Events + Metrics)](#observability-events--metrics)
15. [Error Handling](#error-handling)
16. [Using Custom Transport](#using-custom-transport)
17. [Using `RequestCoalescer` Directly](#using-requestcoalescer-directly)
18. [Testing](#testing)

## Requirements

- Swift 6+
- Apple platform with async/await support

## Installation (SwiftPM)

Add package dependency:

```swift
dependencies: [
    .package(url: "https://github.com/your-org/NovaNetworkClient.git", from: "1.0.0")
]
```

Add product to your target:

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

## Minimal Setup

```swift
import Foundation
import NovaNetworkClient

let client = NetworkClient()
```

## Production Profile Generator (DX 2.0)

Use presets v2 (`base + overlays`) plus anti-pattern checks for faster production onboarding.

```swift
let profile = NetworkClientProductionProfileGenerator().generate(
    goal: .restAPI,
    overlays: [.strictReliability],
    offlineStoreConfigured: false
)

guard profile.validation.isProductionReady else {
    for issue in profile.validation.issues {
        print("[\(issue.severity.rawValue)] \(issue.code): \(issue.message)")
    }
    fatalError("Invalid production profile. Resolve validator findings first.")
}

let preset = profile.composedPreset
let client = NetworkClient(
    retryPolicy: preset.retryPolicy,
    defaultCachePolicy: preset.defaultCachePolicy
)
await client.applyRuntimePolicy(from: preset)
```

You can also compose manually:

```swift
let preset = NetworkClientPreset.compose(
    base: .realtimeHeavy,
    overlays: [.lowLatency, .highThroughput]
)
let report = preset.validateProductionReadiness(overlays: [.lowLatency, .highThroughput])
```

`NetworkClient` default configuration:

- `transport`: `Transport()` (`URLSession.shared`)
- `cancellationPolicy`: `.keepRunning`
- `fingerprintPolicy`: `.default`
- `retryPolicy`: `.none`
- `defaultCachePolicy`: `.networkOnly`

`NetworkClient` also accepts:

- `coalescerLimits` (`maxInFlightKeys`, `maxWaitersPerKey`, `inFlightTimeout`)
- `retryClock` and `retryRandomGenerator` for deterministic retry tests
- `networkObserver` for cache/retry attempt events

## Building Requests

Use `APIRequest` to describe requests:

```swift
let request = APIRequest(
    method: .get,
    url: URL(string: "https://api.example.com/users")!,
    queryItems: [URLQueryItem(name: "id", value: "42")],
    headers: ["Accept": "application/json"],
    body: nil,
    timeout: 30
)
```

Supported HTTP methods are defined in `URLMethod` (`.get`, `.post`, `.put`, `.patch`, `.delete`, etc.).

You can also build fluent requests and encode JSON bodies safely:

```swift
let request = try APIRequest
    .builder(method: .post, url: URL(string: "https://api.example.com/users")!)
    .header("Accept", "application/json")
    .jsonBody(["name": "Max"])
    .build()
```

## Loading Raw Data

```swift
let data = try await client.load(
    request: request,
    authScope: "user:42",
    cachePolicy: .networkOnly
)
```

`authScope` is part of the fingerprint identity (as digest). Use different scopes to avoid coalescing across different auth contexts.

## Loading Decodable Models

```swift
struct User: Decodable, Sendable {
    let id: Int
    let name: String
}

let user: User = try await client.load(
    request: request,
    authScope: "user:42",
    as: User.self
)
```

You can also pass custom decoder:

```swift
let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase

let user: User = try await client.load(
    request: request,
    authScope: "user:42",
    as: User.self,
    decoder: decoder
)
```

## How Coalescing Works

If multiple concurrent calls have the same fingerprint key, only one underlying operation executes.

```swift
async let first = client.load(request: request, authScope: "user:42")
async let second = client.load(request: request, authScope: "user:42")

let (a, b) = try await (first, second)
print(a == b) // true
```

After completion, a new request with the same key starts a new operation.

## Cancellation Policies

### `.keepRunning`

If all waiters cancel, underlying operation continues.

```swift
let client = NetworkClient(cancellationPolicy: .keepRunning)
```

### `.cancelWhenNoWaiters`

If all waiters cancel, underlying operation is cancelled.

```swift
let client = NetworkClient(cancellationPolicy: .cancelWhenNoWaiters)
```

Choose `.cancelWhenNoWaiters` for expensive operations where no listeners remain.

## Fingerprint Policy

Fingerprint controls when two requests are considered the same.

Default includes:

- HTTP method
- canonical URL
- query items
- selected headers (default: all)
- body digest
- auth scope digest

Example with header allowlist:

```swift
let policy = FingerprintPolicy(
    includeQueryItems: true,
    includeBody: true,
    headerInclusion: .allowlist(["Accept", "Content-Type"])
)

let client = NetworkClient(fingerprintPolicy: policy)
```

You can disable body/query participation if needed:

```swift
let policy = FingerprintPolicy(
    includeQueryItems: false,
    includeBody: false,
    headerInclusion: .none
)
```

## Retry Policy

Retry is applied inside `NetworkClient`.

```swift
let retry = RetryPolicy(
    maxAttempts: 3,
    baseDelayNanoseconds: 200_000_000,
    maxDelayNanoseconds: 2_000_000_000,
    jitterRange: 0.8...1.2,
    retriableHTTPStatusCodes: [408, 429, 500, 502, 503, 504],
    retriableURLErrorCodes: [.timedOut, .networkConnectionLost]
)

let client = NetworkClient(retryPolicy: retry)
```

Notes:

- `maxAttempts = 1` means no retries.
- Cancellation is not retried.
- Backoff is exponential and capped by `maxDelayNanoseconds`.

## Cache Policies

`NetworkClient` supports three policies:

- `.networkOnly`: always hit network (default)
- `.cacheFirst(maxAge:)`: return cached value while fresh, otherwise fetch+store
- `.staleWhileRevalidate(maxAge:staleAge:)`: return stale value while triggering background refresh

```swift
let client = NetworkClient(defaultCachePolicy: .cacheFirst(maxAge: 10))

let data = try await client.load(
    request: request,
    authScope: "user:42",
    cachePolicy: .staleWhileRevalidate(maxAge: 2, staleAge: 60)
)
```

Manual cache controls:

```swift
try await client.preload(request: request, authScope: "user:42")
await client.invalidate(request: request, authScope: "user:42")
await client.invalidateAll()
```

## Offline Queue (Write Requests)

Use offline queue for write methods (`POST`/`PUT`/`PATCH`) when transport is unavailable.

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

let request = APIRequest(
    method: .post,
    url: URL(string: "https://api.example.com/items")!,
    body: Data("{\"name\":\"draft\"}".utf8)
)

let result = try await client.enqueueWrite(
    request: request,
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
```

Queue policy modes:

- `.disabled`: default behavior, no offline queueing
- `.enqueueWhenOffline`: try network first, enqueue when transport is offline
- `.alwaysEnqueue`: enqueue immediately and replay later
- `maxReplayAttempts`: terminal threshold before conflict handling path
- `replayConflictPolicy`: `.retry`, `.drop`, `.manualReview`
- `replayDedupeWindowSeconds`: skip duplicate replay when same replay identity already succeeded in time window

Replay and queue management:

```swift
let replayed = await client.flushOfflineQueue(limit: 64)
let depth = await client.offlineQueueDepth()
let snapshot = await client.offlineQueueSnapshot()

if let first = snapshot.first {
    _ = await client.dropQueuedWrite(queueID: first.receipt.queueID)
}
_ = await client.dropAllQueuedWrites()
```

Offline queue events:

```swift
for await event in client.offlineQueueEvents() {
    print(event)
}
```

## Observability (Events + Metrics)

Use `observer` for real-time events:

```swift
let client = NetworkClient(
    observer: { event in
        print(event)
    }
)
```

Event types:

- `.started`
- `.coalesced`
- `.bypassed`
- `.waiterCancelled`
- `.timedOut`
- `.finished`

`networkObserver` gives network/cache specific events:

- `.cacheHit` / `.cacheMiss`
- `.requestAttempt`
- `.retryScheduled`
- `.requestSucceeded` / `.requestFailed`
- `.cacheInvalidated`
- `.requestPolicyUpdated`
- `.circuitBreakerTransition`
- `.requestRateLimited`

`telemetryHooks` supports structured callbacks for:

- coalescer events
- retry scheduled / retry exhausted / retry skipped
- request cancellation
- queue metrics
- circuit-breaker transitions
- runtime policy updates
- offline queue lifecycle (`enqueued`, `replayStarted`, `replaySucceeded`, `replayFailed`, `deadLettered`, `dropped`)

OpenTelemetry adapter without core dependency:

```swift
let exporter = MyOpenTelemetryExporter() // implements OpenTelemetryExporting in app target
let adapter = OpenTelemetryAdapter()
let client = NetworkClient(
    transport: Transport(),
    telemetryHooks: adapter.makeHooks(exporter: exporter)
)

let pipeline = await client.offlineQueuePipelineMetrics()
adapter.emitPipelineMetrics(pipeline, exporter: exporter)
```

Contract v2 payloads include top-level `event_version` and `contract_version`.

Read counters with `coalescerMetrics()`:

```swift
let metrics = await client.coalescerMetrics()
print("hits:", metrics.coalescedHits)
print("misses:", metrics.coalescedMisses)
print("waiter cancellations:", metrics.waiterCancellations)
print("finished:", metrics.finishedOperations)
```

## Error Handling

`NetworkClient` throws `NetworkError`.

```swift
do {
    let _: Data = try await client.load(request: request, authScope: nil)
} catch let error as NetworkError {
    switch error {
    case .httpStatus(let code, let body):
        print("HTTP status:", code, "body size:", body.count)
    case .invalidResponse:
        print("Invalid HTTP response")
    case .decoding(let underlying):
        print("Decoding error:", underlying)
    case .transport(let underlying):
        print("Transport error:", underlying)
    case .cancelled:
        print("Cancelled")
    }
} catch {
    print("Unexpected error:", error)
}
```

## Using Custom Transport

Implement `NetworkTransport` to plug in custom networking or mocks.

```swift
struct MockTransport: NetworkTransport {
    func execute(_ request: APIRequest) async throws -> Data {
        Data("{\"id\":42,\"name\":\"Alice\"}".utf8)
    }
}

let client = NetworkClient(transport: MockTransport())
```

This is useful for tests and environments with custom HTTP stacks.

## Using `RequestCoalescer` Directly

You can use coalescing without networking:

```swift
let coalescer = RequestCoalescer<String, Error>(policy: .keepRunning)

let value = try await coalescer.run(key: "same-work") {
    // Important: operation returns Result
    .success("done")
}

print(value)
```

This is useful for deduplicating any async operation identified by a stable key.

## Testing

Run package tests:

```bash
swift test
```

For deterministic retry tests, set `jitterRange: nil`.
