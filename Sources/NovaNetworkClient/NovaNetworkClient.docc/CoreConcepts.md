# Core Concepts

Understand how NovaNetworkClient decides which callers can share work and where policies apply.

## Overview

### Request identity

Every request receives a stable fingerprint. By default, identity includes the HTTP method,
canonical URL and query, headers, body digest, and a digest of `authScope`. Two calls coalesce only
when their fingerprints match and their execution overlaps.

Coalescing is not a permanent response cache. After shared work completes, a later call starts a
new operation unless its ``CachePolicy`` can serve a stored response.

### Authentication scope

`authScope` separates requests that use different credentials even when their URLs are identical.
Pass a stable label such as `"user:42"` or `"tenant:acme"`; never pass an access token. A token can
rotate while the logical authorization boundary remains the same.

### Fingerprints and sensitive headers

``FingerprintPolicy`` controls whether query items, bodies, and particular headers participate in
identity. Narrowing the header set can improve sharing, but only exclude a header after proving it
cannot change authorization, content negotiation, localization, or the response body.

### Cancellation

With ``CancellationPolicy/keepRunning``, cancelling the last waiter does not cancel the shared
operation. With ``CancellationPolicy/cancelWhenNoWaiters``, the operation is cancelled when nobody
is waiting. Cancelling one of several callers does not cancel work that the other callers still need.

### Retry and idempotency

``RetryPolicy`` retries selected transient HTTP and URL errors. GET and other idempotent requests
are eligible by default. A non-idempotent write needs an explicit idempotency strategy; do not make
POST retries broadly eligible without a server contract that prevents duplicate effects.

### Cache and coalescing

These mechanisms solve different problems:

| Mechanism | Lifetime | Primary value |
|---|---|---|
| Coalescing | While equivalent work is in flight | Avoid duplicate concurrent operations |
| `cacheFirst` | Until the cached response is older than `maxAge` | Avoid a network round trip |
| `staleWhileRevalidate` | Fresh and stale windows | Return quickly while refreshing in the background |

HTTP request and response directives can further constrain cache behavior.

### The request pipeline

A load passes through request identity, capacity and runtime policies, cache lookup, coalescing,
middleware, authentication refresh, retry, transport, response validation, caching, decoding, and
telemetry. `Endpoint` keeps request construction and decoding together; it still uses this same
pipeline.

## See Also

- <doc:ShareConcurrentRequests>
- <doc:AddResilience>
- ``RequestFingerprint``
- ``RequestCoalescer``
