# What's New in 2.5

## NetworkClientConfiguration

- Added `NetworkClientConfiguration`, a mutable value struct grouping every `NetworkClient`
  construction option (transport, policies, cache, offline queue, middleware, telemetry,
  authentication refresh, decoder). Start from `NetworkClientConfiguration()`, mutate the
  fields you need, and pass the result to the new `NetworkClient.init(configuration:)`.
- Added `NetworkClientConfiguration.addMiddleware(_:)` to append one middleware without
  rebuilding the array.
- `NetworkClient`'s existing labeled-argument initializer is now a `convenience init` that
  builds a `NetworkClientConfiguration` internally and delegates to `init(configuration:)`; both
  initializers are equivalent and produce identically behaving clients (verified in tests: same
  retry-attempt count for the same retry policy, same middleware and telemetry wiring).

## Migration notes

- Additive only; no existing public API changed. `NetworkClient.init`'s labeled-argument form
  keeps its existing signature, defaults, and behavior.
