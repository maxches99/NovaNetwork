# What's New in 2.6

## Response decoding strategies

- Added `ResponseDecoding`, a protocol decoding a full `NetworkResponse` (status, headers, and
  body) into a `Decodable & Sendable` type. Unlike `load<T: Decodable>` and
  `Endpoint.decode(_:using:)`, which always use a fixed `JSONDecoder` and only see the body, a
  `ResponseDecoding` strategy can pick how to decode per response — most commonly by inspecting
  its `Content-Type` header.
- Added `JSONResponseDecoding`, matching `NetworkClient`'s existing default behavior, and
  `ContentTypeNegotiatingResponseDecoding`, which selects a registered strategy by media type
  (parameters like `charset` are ignored; matching is case-insensitive) and falls back to a
  configurable default (`JSONResponseDecoding` unless overridden) when the header is absent or
  unregistered.
- Added `NetworkClient.loadResponse(request:authScope:options:)`, returning the full response
  instead of just `Data`, and `NetworkClient.decode(request:authScope:as:responseDecoding:options:)`,
  which uses a `ResponseDecoding` strategy — a per-call one, or `NetworkClientConfiguration`'s new
  `responseDecoding` field as a client-wide default, or `JSONResponseDecoding` if neither is set.
  Both always bypass the response cache, matching `cachePolicy: .networkOnly`.
- Internally, `fetchNetworkAndOptionallyStore` (the shared network-fetch/cache-store helper
  behind every `NetworkClient.load` cache policy) now returns the full `NetworkResponse` instead
  of discarding headers after extracting the body; `load`'s own call sites were updated to
  extract `.body`, so its existing `Data`-returning behavior for every cache policy
  (`networkOnly`, `cacheFirst`, `staleWhileRevalidate`, conditional revalidation, `stale-if-error`)
  is unchanged. Verified with the full existing cache test suite plus the new response-decoding
  tests.

## Migration notes

- Additive only; no existing public API changed. `Endpoint.decode(_:using:JSONDecoder)` and
  `load<T: Decodable>(...)` keep their exact signatures and `JSONDecoder`-based behavior.
