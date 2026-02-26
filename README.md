# RequestCoalescer

`RequestCoalescer` is a Swift library for deduplicating concurrent requests with the same logical identity.

When multiple callers ask for the same resource at the same time, only one underlying operation runs and all callers await the shared result.

## Documentation

- [Setup & Usage Guide](docs/SETUP_GUIDE.md)
- [Unit Test Policy](docs/UNIT_TEST_POLICY.md)

## Installation (SwiftPM)

```swift
dependencies: [
    .package(url: "https://github.com/your-org/RequestCoalescer.git", from: "1.0.0")
]
```

```swift
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "RequestCoalescer", package: "RequestCoalescer")
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
- Per-request execution options (priority, per-request limits override, capacity scheduling, circuit breaker).
- Client-side per-key rate limiting (`RateLimitPolicy`).
- Request middleware pipeline (`beforeSend` / `afterResponse`).
- Cancellation policies:
  - `keepRunning`
  - `cancelWhenNoWaiters`
- Retry/backoff policy for transient failures (for example `429`, `5xx`, network timeouts).
- Adaptive retry options (`Retry-After` support, retry budget).
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
- Optional telemetry hooks for tracing/metrics adapters.

## Quick Start

```swift
import Foundation
import RequestCoalescer

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
    .appendingPathComponent("RequestCoalescerCache")

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
        circuitBreakerPolicy: CircuitBreakerPolicy(
            scope: .host,
            failureThreshold: 3,
            cooldownSeconds: 10
        )
    )
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

## Streaming

```swift
for try await chunk in client.loadStream(request: request, authScope: "user:42") {
    print("chunk bytes:", chunk.count)
}
```

## In-Flight Diagnostics

```swift
let inFlight = await client.inFlightRequests()
print(inFlight.map(\.key))
```

## Benchmark Baseline Check

```bash
swift run RequestCoalescerBenchmarks --check-baseline
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
| Non-retriable error | Fails immediately |

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
