# Query Layer

Ask for server state by key and get back something a screen can render: a value, whether it is
loading, whether it is stale, and what went wrong.

## Overview

`NetworkClient` answers "perform this request". A screen asks something else: *what is the current
state of this resource, and tell me when it changes.* Every adopter builds that layer, and it is the
same layer every time — a cache keyed by something, a loading flag, a stale flag, an error, a
refetch, an invalidation after a mutation.

```swift
import NovaNetworkQuery

let queries = QueryClient()

let user: User = try await queries.value(for: QueryKey("users", 1)) {
    try await client.load(request: request, authScope: nil)
}
```

A query wraps any async work, so `NovaNetworkQuery` depends on Foundation alone: an HTTP call, a
database read, or a computation are all the same to it.

## What it fixes

| Without | With |
|---|---|
| Two screens fetch the same list twice | One entry per key, one in-flight fetch per key |
| Pull-to-refresh blanks the list to a spinner | The old value stays visible, marked stale, while the refresh runs |
| A delete leaves the row on screen | The mutation invalidates the key and every screen updates |
| A failed optimistic edit stays applied | The exact previous value is restored |

## Reading

`value(for:staleTime:fetch:)` returns a fresh value without touching the network, and a stale one
*immediately* while refreshing behind it. Blanking a screen over a value half a minute old is the
behavior this layer exists to remove.

Concurrent callers share the fetch: two screens asking at the same moment produce one request.

## Rendering

Subscribe and switch:

```swift
for await state in await queries.states(for: QueryKey("users", 1), as: User.self) {
    switch state {
    case .idle, .loading(nil):            showSpinner()
    case let .loading(.some(user)),
         let .success(user, _):           show(user, stale: state.isStale)
    case let .failure(error, previous):   show(error, keeping: previous)
    }
}
```

A subscriber receives the current state first, so a screen that arrives late is not left blank.
Errors are part of the state rather than only thrown: a failure that is only thrown forces every
screen to invent its own handling, while one in the state lets a view render the problem beside a
value it already had.

On iOS 17 and later, `ObservableQuery` wraps the same stream for SwiftUI. It is the only part of this
layer behind an availability gate — the package supports iOS 13, and moving the floor to save the
library work would exclude consumers.

## Invalidating and mutating

```swift
try await queries.mutate(
    optimistic: [QueryKey("users", 1): editedUser],
    invalidating: [QueryKey("users", 1), "users"]
) {
    try await client.load(request: saveRequest, authScope: nil)
}
```

The optimistic value appears immediately. If the work throws, the **exact previous value** is
restored — a captured snapshot, not a reversed diff, which is the only approach that stays correct
when two mutations race. On success the listed keys are invalidated.

Keys are hierarchical, so `invalidate(prefix: "users")` marks every user query stale. Entries with
subscribers refetch at once; entries nobody is watching are marked and left alone, because
refetching data no screen is showing spends the user's battery filling a cache that may never be
read.

## Paging

```swift
let feed = PagedQuery<Post, String>(key: "feed", client: queries) { cursor in
    let page: FeedPage = try await client.load(request: feedRequest(after: cursor), authScope: nil)
    return QueryPage(elements: page.posts, nextCursor: page.next)
}

let posts = try await feed.loadNextPage()   // everything loaded so far, not just the new page
```

Accumulated pages are written into the cache under the query's key, so a screen subscribes the same
way it subscribes to anything else and never has to know pagination is happening. Loading past the
last page is a no-op rather than an error — a scroll handler firing once more at the bottom is
normal.

## Bounded

The cache holds 100 entries by default and evicts the least recently used entry **that nobody is
subscribed to**, so a screen's data cannot disappear from under it.

## What this is not

- **A replacement for `NetworkClient`.** It sits above and calls it.
- **A normalized entity cache.** Values are stored by key, not merged into a graph. Normalization is
  a different product with different failure modes.
- **Persistence.** The cache is in memory; the offline queue remains the durable path for writes.
- **A view framework.** One observable model is provided; layout, navigation, and error presentation
  belong to the app.

## The symbols

`QueryClient` holds everything; `QueryKey` identifies it; `QueryState` is what a screen renders.
`QueryConfiguration` sets staleness and capacity, `QueryError` reports a key read as the wrong type,
`PagedQuery` and `QueryPage` handle lists, and `ObservableQuery` bridges to SwiftUI.

They live in the `NovaNetworkQuery` module.

## See Also

- <doc:ChoosingAnAPI>
- <doc:CoreConcepts>
