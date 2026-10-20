# What's New in 3.7

3.7 is eight separate features. Each is off until you ask for it; without them the client behaves
exactly as in 3.6.

## Hedged requests: the slow tail, not the failures

A retry starts after an attempt *fails*. Most of a mobile app's p99 is not failures, it is requests
that are just slow — a busy replica, a packet waiting on a retransmit timer — and a retry never
fires for those. A hedge does: when a request that is safe to repeat has not answered by the time
most requests to that host have, the client sends it again and takes whichever answer comes first.

```swift
var configuration = NetworkClientConfiguration()
configuration.hedging = HedgingPolicy(delay: .percentile(0.95))
let client = NetworkClient(configuration: configuration)
```

- **Only what is safe to send twice.** `GET`, `HEAD`, `OPTIONS`, and any request carrying an
  `Idempotency-Key`. `isEligible:` replaces the rule; a custom rule that admits a write without a
  key sends that write twice.
- **When.** `.percentile(0.95)` waits the p95 of the last 128 successful latencies to the same host,
  never less than `floorSeconds` (50 ms), and `fallbackSeconds` (1 s) until the host has
  `minimumSamples` (20). `.fixed(seconds:)` always waits the same. The timer sleeps on
  `retryClock`, so a test that controls retry time controls hedge time too.
- **A budget.** At most `maximumHedgeRatio` (5%) of eligible requests are hedged over time, with up
  to `burst` (2) saved up. A server that is slow because it is overloaded does not get twice the
  traffic.
- **The loser is cancelled.** First success wins and the other request's task is cancelled. If one
  fails, the client waits for the other; if both fail, you get the first request's error.
- **Failures are still the retry policy's.** A request that fails before the delay is not hedged.
  Each retry attempt can be hedged once.

### Telemetry

`NetworkTelemetryHooks(onRequestHedged:)` receives a `TelemetryHedgeContext` with the prepared
request and the delay waited:

| `type` | When |
|---|---|
| `fired` | the delay elapsed and the request was sent again |
| `won` | the second request's response is the one returned |
| `budget_exhausted` | the delay elapsed but the budget was spent, so nothing was sent |

`fired` minus `won` is what hedging cost you without helping.

### Edges

A hedge does not take a second slot from `AdaptiveConcurrencyLimiter`: the budget bounds the extra
load, and a second permit could deadlock a limit of one. Streams, transfers, and WebSockets are never
hedged.

## The query cache survives a relaunch

`QueryClient` kept server state in memory only, so every cold start began with empty screens until
the first fetch came back. It can now keep values on disk and put them back on screen the moment the
app launches:

```swift
let queries = QueryClient(
    persistence: QueryPersistence(
        store: try FileQueryPersistenceStore.inCachesDirectory(),
        version: 1,                       // bump after a model change
        maximumAge: 7 * 24 * 60 * 60,     // older records are not shown
        onEvent: { print($0) }            // restored / discarded / writeFailed
    )
)
let feed: Feed = try await queries.persistedValue(for: "feed") { try await api.feed() }
```

- **Per query, not per client.** Only `Codable` values read through `persistedValue(for:)` are
  written. `value(for:)` never touches the store, so nothing lands on disk that you did not ask for.
- **Lazy restore.** A key is read from the store the first time it is asked for after launch. Its
  age is the time it was saved, and the usual `staleTime` decides: a fresh value is returned with no
  fetch, a stale one is returned at once and refreshed in the background.
- **Distrust by default.** A record written under another `version`, for another type
  (`String(reflecting:)`, so module-qualified), older than `maximumAge`, or that fails to decode is
  discarded and deleted. `onEvent` receives `.discarded(key:reason:)` with the reason.
- **Never a guess.** Optimistic values from `mutate` are not written. `setValue` is.
- **Sign-out.** `remove(_:)` and `removeAll()` remove from the store too.
- **Ordered writes.** Writes run in the background, one at a time, in the order they were made.
  `flushPersistence()` waits for them, for `scenePhase == .background` or a test.
- **Stores.** `FileQueryPersistenceStore` keeps one atomically written JSON file per key;
  `InMemoryQueryPersistenceStore` is for previews and tests. Anything else — encryption, an app
  group — is a `QueryPersistenceStore` of your own.

A store that refuses writes reports `.writeFailed(key:)` and never fails the query.
