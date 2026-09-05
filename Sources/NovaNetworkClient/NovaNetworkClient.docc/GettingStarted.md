# Getting Started with NovaNetworkClient

Install the package, make a typed request, and understand the defaults before adding production policies.

## Overview

`NovaNetworkClient` is a concurrency-safe HTTP client for Swift. When equivalent requests overlap,
the client performs one network operation and shares its result with every caller. The same request
pipeline can also apply caching, retries, middleware, authentication refresh, and telemetry.

This guide starts with the smallest useful integration. For a hands-on path with numbered steps,
follow <doc:BuildYourFirstRequest>.

### Requirements

- Swift 6.2 or later
- iOS 13, macOS 10.15, tvOS 13, or watchOS 6 or later
- An app or package that uses Swift Package Manager

> Note: The `NovaNetworkClient` product includes the URLSession-based client. The
> `NovaNetworkCore` product contains transport-neutral request, response, endpoint, and error
> contracts for integrations that provide their own client layer.

### Add the package in Xcode

1. Choose **File > Add Package Dependencies**.
2. Enter `https://github.com/maxches99/NovaNetwork`.
3. Select a version rule appropriate for your release policy.
4. Add the `NovaNetworkClient` product to your app target.

For a package manifest, add the repository and product explicitly:

```swift
dependencies: [
    .package(
        url: "https://github.com/maxches99/NovaNetwork",
        from: "2.0.0"
    )
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(
            name: "NovaNetworkClient",
            package: "NovaNetwork"
        )
    ]
)
```

### Model the response

Start with a `Decodable` and `Sendable` type. The public sample endpoint in this guide returns a
todo item:

```swift
struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}
```

`Sendable` lets the value safely cross Swift concurrency boundaries.

### Describe the request

An `APIRequest` is an immutable, transport-neutral description of an HTTP operation:

```swift
let request = APIRequest(
    method: .get,
    url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
    headers: ["Accept": "application/json"]
)
```

For production URLs, avoid force-unwrapping. Store a validated base URL in configuration and
construct endpoint paths from it.

### Create a client and load the model

The default client uses URLSession, keeps underlying work running if every waiter cancels, does
not retry, and goes to the network on every completed call:

```swift
let client = NetworkClient()

let todo: Todo = try await client.load(
    request: request,
    authScope: "public"
)
```

The `authScope` is a stable, non-secret identity for the credentials used by a request. It is
included in the request fingerprint as a digest. Use the same scope for callers that may safely
share work, different scopes for different users or tenants, and `nil` when there is genuinely no
credential partition to preserve.

### Handle typed failures

Network operations can fail because of transport, HTTP, decoding, cancellation, or client policy.
Handle `NetworkError` when you need structured behavior, and retain a general fallback for
request-construction errors:

```swift
do {
    let todo: Todo = try await client.load(
        request: request,
        authScope: "public"
    )
    print(todo.title)
} catch let error as NetworkError {
    switch error {
    case .httpStatus(let code, _, _):
        print("Server returned HTTP \(code)")
    case .cancelled:
        print("Request was cancelled")
    default:
        print(error.localizedDescription)
    }
} catch {
    print("Could not create or execute the request: \(error)")
}
```

### See what it did

Three lines turn on a record of every request the client makes — attempts, retries, timings, whether
the cache answered — and it is worth adding before the first thing goes wrong rather than after:

```swift
import NovaNetworkDiagnostics

let recorder = DiagnosticsRecorder()
var configuration = NetworkClientConfiguration()
configuration.telemetryHooks = recorder.hooks
let client = NetworkClient(configuration: configuration)
recorder.startConsuming(client.events())
```

`await recorder.summary().shortDescription` then reads like
`4 requests · 50% failed · 25% coalesced · 66% cache hits`, and `try await recorder.exportHAR()`
produces a HAR file to attach to a bug report. A "server not found" that turns out to be a VPN on the
developer's machine is visible here in seconds rather than half a day; read <doc:Diagnostics> for the
rest.

### Choose your next step

- Follow <doc:ShareConcurrentRequests> to see request coalescing in action.
- Follow <doc:AddResilience> to add bounded retries and response caching.
- Follow <doc:ModelRequestsAsEndpoints> to move repeated request logic into typed endpoints.
- Read <doc:CoreConcepts> before customizing fingerprints or authentication scopes.
- Read <doc:ChoosingAnAPI> to choose between raw loads, endpoints, batches, streams, and transfers.
- Read <doc:OfflineFirst> if the app owns a local database and the network is a synchronizer.
- Review <doc:ProductionChecklist> before shipping.

## See Also

- ``NetworkClient``
- <doc:CoreConcepts>
- <doc:ChoosingAnAPI>
- <doc:Tutorial-Table-of-Contents>
