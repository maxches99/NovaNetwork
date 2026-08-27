# What's New in 3.0

## NovaNetworkQuery: server state for the screens that render it

`NetworkClient` answers "perform this request". A screen asks something else: *what is the current
state of this resource, and tell me when it changes.* Every adopter has been building that layer, and
it is the same layer every time.

```swift
import NovaNetworkQuery

let queries = QueryClient()

let user: User = try await queries.value(for: QueryKey("users", 1)) {
    try await client.load(request: request, authScope: nil)
}
```

A query wraps any async work, so the module depends on Foundation alone — an HTTP call, a database
read, or a computation are all the same to it.

### What it fixes

| Without | With |
|---|---|
| Two screens fetch the same list twice | One entry per key, one in-flight fetch per key |
| Pull-to-refresh blanks the list to a spinner | The old value stays visible, marked stale, while the refresh runs |
| A successful delete leaves the row on screen | The mutation invalidates the key and every screen updates |
| A failed optimistic edit stays applied | The exact previous value is restored |

### Errors are state

A failure that is only thrown forces every screen to invent its own handling. `QueryState` carries
the error *and* the value that was already there, so a view can render both — a stale profile with a
"couldn't refresh" line beats an empty screen.

### Mutations roll back to a snapshot

```swift
try await queries.mutate(
    optimistic: [QueryKey("users", 1): editedUser],
    invalidating: [QueryKey("users", 1), "users"]
) {
    try await client.load(request: saveRequest, authScope: nil)
}
```

Rollback restores the exact value captured before the change rather than reversing a diff. That is
the only approach that stays correct when two mutations race, and there is a test that races them.

### Invalidation is hierarchical, and polite

Keys nest, so `invalidate(prefix: "users")` marks every user query stale. Entries with subscribers
refetch at once; entries nobody is watching are marked and left alone, because refetching data no
screen is showing spends the user's battery filling a cache that may never be read.

### Paging that a screen does not have to know about

`PagedQuery` accumulates pages and writes the accumulated elements into the cache under the query's
key, so a list subscribes the way it subscribes to anything else. Loading past the last page is a
no-op rather than an error — a scroll handler firing once more at the bottom is normal.

### The platform floor does not move

`@Observable` needs iOS 17 and this package supports iOS 13. The cache, the client, and subscriptions
are plain Swift over `AsyncSequence`; `ObservableQuery` is a thin layer behind `@available`. Moving
the floor to save the library work would have excluded consumers.

## Why 3.0

Because this is a new top-level way to use the package, not because anything breaks. No existing API
changes shape, the API breaking-changes gate passes with no new allowlist entries, and nothing needs
to be adopted — a codebase can keep using `NetworkClient` directly forever.

## What was verified

- 593 tests pass; 44 are new and cover keys and prefixes, in-flight deduplication, freshness and
  stale-while-revalidate, subscriptions and their lifetimes, invalidation by key and prefix,
  optimistic mutations including a race, paging, bounded capacity, error state, and the observable
  model.
- `Sources/NovaNetworkQuery` joins the ≥90% coverage gate at 95.23% line coverage.
- The Linux build gate compiles the new target; only `ObservableQuery` is platform-gated.
- `Examples/Query` demonstrates two screens sharing one request, an optimistic edit rolling back, a
  stale render during a refresh, and pagination — printing each state as it is rendered.

## Known limitations

- **Not a normalized entity cache.** Values are stored by key, not merged into a graph. Normalization
  is a different product with different failure modes.
- **Not persistent.** The cache is in memory; the offline queue remains the durable path for writes.
- **Not a view framework.** One observable model is provided; layout, navigation, and error
  presentation belong to the app.
- Dependent queries are expressed by awaiting one before another, not declaratively.

## Migration notes

Additive. New product `NovaNetworkQuery`; no existing API changed shape or behavior.

## Source traceability

- DFR: [NovaNetwork 3.0 DFR](dfr/NOVA_NETWORK_V3_0_DFR.md)
- Traceability pack: [v3.0](TRACEABILITY_PACK_v3.0.md)
- Requirement IDs: FR-1…FR-12, UR-1…UR-4, DR-1…DR-3, AR-1, NFR-1…NFR-5, EC-1…EC-8
