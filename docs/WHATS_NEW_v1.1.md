### What’s New in v1.1

- Added response cache policies: `networkOnly`, `cacheFirst(maxAge:)`, and `staleWhileRevalidate(maxAge:staleAge:)`.
- Added cache management APIs: `preload`, targeted `invalidate`, and `invalidateAll`.
- Improved coalescing safety with limits for `maxInFlightKeys`, `maxWaitersPerKey`, and timed eviction of stuck in-flight operations.
- Expanded observability with coalescer bypass/timeout events and detailed network/cache/retry events via `networkObserver`.
- Made retry behavior deterministic and testable with injectable `RetryClock` and `RetryRandomGenerator`.
- Added a fluent `APIRequestBuilder` and a typed `jsonBody` initializer for safer request construction.
- Updated docs and usage examples for the new APIs.
- Extended test coverage for cache policies, invalidation flows, limits, timeouts, and retry behavior.
