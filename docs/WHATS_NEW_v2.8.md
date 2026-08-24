# What's New in 2.8

## NetworkError: Equatable, LocalizedError, and error context

- `NetworkError` now conforms to `Equatable`. Payload-free cases and cases with `Equatable`
  associated values (`.httpStatus`, `.clientRateLimited`, `.queueCapacityExceeded`) compare
  exactly. Cases wrapping an `any Error` (`.decoding`, `.transport`,
  `.authenticationRefreshFailed`) compare that error by dynamic type and description, since `any
  Error` has no general equality contract — a best-effort comparison intended for tests and
  deduplication, verified against `URLError`, `NSError`-bridged errors, and plain custom `Error`
  types.
- `NetworkError` now conforms to `LocalizedError`, with an `errorDescription` for every case
  (for example, `"The server returned HTTP status 429."`), so `error.localizedDescription` reads
  sensibly without a custom mapping.
- Added `NetworkErrorContext` (URL, method, attempt number, auth scope) and
  `ContextualNetworkError`, which pairs a `NetworkError` with that context — additive types, so
  `NetworkError`'s existing cases and every exhaustive `switch` over them are unchanged.
  `NetworkError.with(request:attempt:authScope:)` builds one from a request.
- Added `NetworkClient.loadWithContext(request:authScope:cachePolicy:options:)`, identical to
  `load(request:...)` except it wraps any thrown `NetworkError` as `ContextualNetworkError`, for
  call sites that want request/attempt context attached automatically (logging, crash
  reporting).

## Migration notes

- Additive only; no existing public API changed, and no existing `NetworkError` case gained new
  associated values (which would have broken exhaustive `switch` statements matching them).
