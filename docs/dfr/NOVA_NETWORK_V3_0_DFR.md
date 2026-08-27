# NovaNetwork 3.0 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.0 — NovaNetworkQuery, a request layer for the UI
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, Design
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 3.0.0
- Source baseline: 2.14 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.0.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.0.md`
  - DocC article: `Sources/NovaNetworkClient/NovaNetworkClient.docc/QueryLayer.md`

## 2. Goal and Scope

### Goal

Give screens a way to ask for server state and get back something they can render: a value, whether
it is loading, whether it is stale, and what went wrong — kept consistent across every screen that
asked for the same thing, and updated when something changes it.

### User value

`NetworkClient` answers "perform this request". A screen needs the answer to a different question:
"what is the current state of this resource, and tell me when it changes". Every adopter builds that
layer themselves, and it is the same layer every time: a cache keyed by something, a loading flag, a
stale flag, an error, a way to refetch, a way to invalidate after a mutation, and a way to keep two
screens showing the same list from disagreeing.

Getting it wrong is normal. Two screens fetch the same list twice. A pull-to-refresh clears the list
to a spinner instead of showing the old value while it revalidates. A successful delete leaves the
row on screen until the app is relaunched. An optimistic update stays on screen after the request
fails.

### Scope split

- MVP / required for 3.0:
  - stable query keys and typed query state;
  - a query client with in-flight deduplication and stale-while-revalidate reads;
  - subscriptions delivering state changes as an `AsyncSequence`;
  - invalidation by exact key and by prefix, plus direct cache writes for optimistic updates;
  - mutations with optimistic application, automatic rollback on failure, and invalidation on success;
  - paged queries that accumulate pages and expose whether another page exists;
  - an `@Observable` model for SwiftUI, gated by availability so the package's platform floor stays.
- Nice-to-have after MVP:
  - persistence of the cache across launches;
  - garbage collection policies beyond an explicit capacity;
  - dependent queries expressed declaratively;
  - a devtools panel built on the diagnostics recorder.

### Non-goals

- Replacing `NetworkClient`. This sits above it and calls it, and a query can wrap any async work.
- A view framework. One `@Observable` model is provided; layouts, navigation, and error presentation
  belong to the app.
- Normalized entity caching. Values are stored by key, not merged into a graph; a normalized cache is
  a different product with different failure modes.
- Offline persistence. The cache is in memory; the offline queue remains the durable path for writes.

### Definition of Done

- [x] DFR updated and approved
- [x] Code implemented
- [x] Tests added/updated per matrix, unit coverage stays above 90%
- [x] Telemetry reviewed (see AR-1)
- [x] "What's New" added
- [x] Traceability pack added
- [x] Documentation (DocC, README, examples) updated
- [x] Rollout plan documented

## 3. User Value

### User problem

A list screen and a detail screen both need the same user. Without a shared layer they fetch it
twice, disagree after an edit, and each reinvent loading and error handling. With one, they ask by
key, share the in-flight request, render the cached value immediately, and both update when a
mutation invalidates it.

### Success metrics

| Metric | Baseline | Target | Measurement method |
|---|---|---|---|
| Network calls for two screens asking the same key at once | 2 | 1 | `T-2.1` |
| Lines to render loading, value, stale, and error | ~40 hand-written | ≤ 10 | `Examples/Query` |
| Stale value shown during a refetch | none — a spinner replaces it | shown, marked stale | `T-3.1` |
| Optimistic updates left on screen after a failure | 1 | 0 | `T-6.2` |

## 4. Rollout, Dependencies, Risks

### Rollout plan

- Feature flag: none. New product `NovaNetworkQuery`; nothing existing changes behavior.
- Version: 3.0.0 because it introduces a new top-level way to use the package, not because anything
  breaks. No existing API changes shape.
- Segments: all consumers; opt-in by linking the product.
- Rollback trigger: none applicable — the layer is additive and callable per screen.

### Dependencies

- Internal: `NovaNetworkCore` only. A query wraps any async work, so the layer does not require the
  HTTP client at all.
- External: none. `Observation` is used behind availability.

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| The cache grows without bound | High | Medium | Explicit capacity with least-recently-used eviction, and entries with no subscribers evicted first |
| Two screens see different values for one key | High | Low | One entry per key, one in-flight task per key, and every subscriber reads the same state |
| An optimistic update survives a failed mutation | High | Medium | The previous value is captured before applying and restored on failure, verified by test |
| `@Observable` forces the platform floor up | High | High | The core is plain Swift with `AsyncSequence`; the observable model is gated by availability |
| Stale-while-revalidate hides a failing refetch | Medium | Medium | State carries both the stale value and the refetch error, so the UI can show a value and a warning |

## 5. Requirements

### Functional requirements (FR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | Query keys are stable, comparable values with a hierarchy for prefix operations | Equal keys hash equally; `["users", 1]` has prefix `["users"]` | T-1.1 |
| FR-2 | Concurrent reads of one key share a single in-flight fetch | Two simultaneous callers cause one fetch | T-2.1 |
| FR-3 | A cached value newer than its stale time is returned without fetching | No fetch occurs within the stale window | T-3.1 |
| FR-4 | A stale value is returned immediately and refreshed in the background | The caller sees the old value, then a new one, and the state says it is stale | T-3.1 |
| FR-5 | Subscribers receive state changes as an `AsyncSequence`, starting with the current state | A late subscriber receives the current state first | T-4.1 |
| FR-6 | Invalidation by exact key and by key prefix marks entries stale and refetches those with subscribers | Both forms verified; unsubscribed entries are marked but not refetched | T-5.1 |
| FR-7 | Values can be written directly for optimistic updates, and removed | Written values are published to subscribers | T-5.2 |
| FR-8 | Mutations apply an optimistic value, roll it back on failure, and invalidate on success | Rollback restores the exact previous value | T-6.1, T-6.2 |
| FR-9 | Paged queries accumulate pages and report whether another exists | Fetching two pages yields both, in order | T-7.1 |
| FR-10 | The cache is bounded, evicting the least recently used entry without subscribers first | Capacity respected; subscribed entries survive | T-8.1 |
| FR-11 | Errors are delivered as state, not only as throws, so a screen can render them | Failure state carries the error and any previous value | T-9.1 |
| FR-12 | An `@Observable` model exposes state to SwiftUI where the platform allows | Compiles under availability; the core works without it | Build |

### UX requirements (UR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Rendering the four states is a switch over one value | `QueryState` covers idle, loading, success, failure with stale marked | T-9.1 |
| UR-2 | Refreshing never blanks the screen | A refetch keeps the previous value visible | T-3.1 |
| UR-3 | Every public symbol carries DocC documentation | No missing-doc warnings | DocC build |
| UR-4 | The article says plainly what this is not: no normalized cache, no persistence | Documented | `QueryLayer.md` |

### Data requirements (DR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | The cache is in memory only | Nothing written to disk | Diff review |
| DR-2 | Cached values are `Sendable`, so sharing across tasks is safe by construction | Enforced by the type system | Build |
| DR-3 | Capacity is explicit, with a documented default | Default stated and tested | T-8.1 |

### Analytics requirements (AR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | No new telemetry. Queries execute whatever work the caller supplies, and HTTP work reports through the existing client contract | A query wrapping a client call emits the client's usual events | T-10.1 |

### Non-functional requirements (NFR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | No new package dependencies | `swift package show-dependencies` unchanged | CI |
| NFR-2 | Compiles on Linux under complete concurrency checking | Linux gate extended | CI |
| NFR-3 | Additive: no existing public symbol changes shape | API breaking-changes gate passes | CI |
| NFR-4 | Unit coverage stays above 90% | Coverage gate includes the new target | CI |
| NFR-5 | The package's platform floor does not rise | `Package.swift` platforms unchanged; `Observation` gated | Build |

### Edge cases (EC)

| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | A fetch fails while a cached value exists | Failure state carries the error and keeps the previous value | T-9.1 |
| EC-2 | A subscriber cancels mid-fetch | The fetch continues for other subscribers; a lone subscriber's cancellation does not corrupt the entry | T-4.2 |
| EC-3 | Invalidation of a key nobody is watching | Marked stale, not refetched | T-5.1 |
| EC-4 | An optimistic mutation on a key with no cached value | Rollback removes the value it added | T-6.2 |
| EC-5 | Two mutations racing on one key | Each rolls back to the value it captured; the last write wins | T-6.3 |
| EC-6 | A paged query whose next page is empty | `hasNextPage` becomes false and pages stop accumulating | T-7.1 |
| EC-7 | Capacity of zero | Nothing is cached and every read fetches | T-8.1 |
| EC-8 | The same key requested as two different value types | Rejected with a typed error rather than an unsafe cast | T-1.2 |

## 6. State Machine and Flows

| From | Trigger | To | Notes |
|---|---|---|---|
| `idle` | first read | `loading` | No cached value to show |
| `loading` | fetch succeeds | `success` | Value cached with a timestamp |
| `loading` | fetch fails | `failure` | Error published; no value |
| `success` | read within stale time | `success` | No fetch |
| `success` | read after stale time | `success(isStale: true)` then `success` | Old value stays visible while the refetch runs |
| `success` | refetch fails | `failure(previousValue:)` | Screen can show the value and the problem |
| `success` | invalidated | `success(isStale: true)` | Refetched when someone is subscribed |
| any | optimistic mutation applied | `success` | Previous value captured for rollback |
| `success` | mutation fails | previous state | Optimistic value rolled back exactly |

## 7. Engineering Notes

- **The platform floor does not move.** `@Observable` needs iOS 17, and this package supports iOS 13.
  The cache, the client, and subscriptions are plain Swift with `AsyncSequence`; the observable model
  is a thin layer behind `@available`. Anything else would exclude consumers to save the library
  work.
- **Above the client, not inside it.** A query wraps any async closure, so the layer depends on
  `NovaNetworkCore` alone and works for a database read or a computation as readily as an HTTP call.
  The client's own coalescing already dedupes identical HTTP requests; query-level dedup covers the
  rest and keeps one entry authoritative per key.
- **Stale-while-revalidate is the default read.** Blanking a screen to a spinner because a value is
  four minutes old is the behavior this layer exists to remove.
- **Rollback captures the previous value, not a diff.** Restoring an exact snapshot is the only
  approach that stays correct when two mutations race.
- **Errors are state.** A failure that is only thrown forces every screen to invent its own error
  handling; a failure in the state lets a screen render it beside a stale value.

## 8. Test Matrix

| Requirement ID | Test ID | Test type | Owner | Status |
|---|---|---|---|---|
| FR-1, EC-8 | T-1.1, T-1.2 | unit | Engineering | done |
| FR-2 | T-2.1 | unit | Engineering | done |
| FR-3, FR-4, UR-2 | T-3.1 | unit | Engineering | done |
| FR-5, EC-2 | T-4.1, T-4.2 | unit | Engineering | done |
| FR-6, FR-7, EC-3 | T-5.1, T-5.2 | unit | Engineering | done |
| FR-8, EC-4, EC-5 | T-6.1…T-6.3 | unit | Engineering | done |
| FR-9, EC-6 | T-7.1 | unit | Engineering | done |
| FR-10, DR-3, EC-7 | T-8.1 | unit | Engineering | done |
| FR-11, EC-1, UR-1 | T-9.1 | unit | Engineering | done |
| AR-1 | T-10.1 | integration | Engineering | done |

### Negative tests

- T-1.2 asserts requesting one key as two value types fails with a typed error instead of casting.
- T-4.2 asserts a cancelled subscriber does not cancel work other subscribers are waiting on.
- T-6.2 and T-6.3 assert rollback restores the exact captured value, including removing one that was never there.
- T-9.1 asserts a failed refetch keeps the previous value available to the UI.
