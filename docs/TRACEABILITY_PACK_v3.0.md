# Traceability Pack v3.0

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_0_DFR.md`
- Scope: query keys and state, the query client's cache and fetching semantics, subscriptions,
  invalidation, optimistic mutations, paged queries, and the observable model.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-1, EC-8 | `Sources/NovaNetworkQuery/QueryKey.swift`, `QueryConfiguration.swift` (`QueryError`) |
| FR-2, FR-3, FR-4, UR-2 | `QueryClient.value(for:staleTime:fetch:)`, `startFetch`, `isFresh` |
| FR-5, EC-2 | `QueryClient.states(for:as:)`, subscriber bookkeeping |
| FR-6, FR-7, EC-3 | `QueryClient.invalidate(_:)`, `invalidate(prefix:)`, `setValue(_:for:)`, `remove(_:)` |
| FR-8, EC-4, EC-5 | `QueryClient.mutate(optimistic:invalidating:perform:)` |
| FR-9, EC-6 | `PagedQuery.swift` |
| FR-10, DR-3, EC-7 | `QueryClient.evictIfNeeded()`, `QueryConfiguration.capacity` |
| FR-11, EC-1, UR-1 | `QueryState.swift` |
| FR-12, NFR-5 | `ObservableQuery.swift` behind `@available` |
| AR-1, DR-1, DR-2 | no telemetry, no persistence, `Sendable` values throughout |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-1.1, T-1.2 | FR-1, EC-8 | unit | `QueryKeyTests`, `QueryFetchingTests` |
| T-2.1 | FR-2 | unit | `QueryFetchingTests.twoScreensAskingAtOnceCauseOneFetch` |
| T-3.1 | FR-3, FR-4, UR-2 | unit | `QueryFetchingTests` |
| T-4.1, T-4.2 | FR-5, EC-2 | unit | `QuerySubscriptionTests` |
| T-5.1, T-5.2 | FR-6, FR-7, EC-3 | unit | `QueryInvalidationTests` |
| T-6.1…T-6.3 | FR-8, EC-4, EC-5 | unit | `MutationTests` |
| T-7.1 | FR-9, EC-6 | unit | `PagedQueryTests` |
| T-8.1 | FR-10, DR-3, EC-7 | unit | `QueryCacheBehaviorTests` |
| T-9.1 | FR-11, EC-1, UR-1 | unit | `QueryCacheBehaviorTests`, `QueryStateTests` |
| T-10.1 | AR-1 | integration | `QueryOverNetworkClientTests` |
| — | FR-12 | unit | `ObservableQueryTests` |
| T-GATE-1…4 | NFR-1…NFR-4 | CI | zero-dependency check, coverage gate, Linux gate, API breakage gate |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `Sources/NovaNetworkQuery` | 95.23% |

No file is excluded from the gate. `ObservableQuery` is covered by tests guarded with `#available`,
since the toolchain used in CI is new enough to run them.

## Security and data contract

- Nothing is persisted; the cache is memory only.
- Cached values are `Sendable`, so sharing across tasks is safe by construction rather than by
  convention.
- Capacity is bounded and eviction never removes an entry a screen is subscribed to.
- The layer stores whatever the caller fetched; it neither inspects nor redacts payloads, which is
  worth knowing when a query holds something sensitive.

## Verification gaps

- The observable model is exercised headlessly; no SwiftUI view is rendered in tests.
- Cache behavior under memory pressure is not modelled; capacity is the only bound.
- The example target is built in CI, not executed.
