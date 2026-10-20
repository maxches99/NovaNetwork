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

## Responses checked against their OpenAPI spec

API drift used to be found by a crash report: a `DecodingError` on some devices, days after a backend
deploy. The spec that would have caught it was already in the repository — `nova-openapi` reads it —
but nothing compared it with what the server sent. `OpenAPIContract` does:

```swift
import NovaNetworkOpenAPI

let contract = try OpenAPIContract(specText: String(contentsOf: specURL, encoding: .utf8))
configuration.addMiddleware(
    .openAPIContract(contract, sampleRate: 0.05) { report in
        for violation in report.violations {
            logger.warning("\(report.method) \(report.operationPath ?? report.path) \(violation)")
            // breaking: /id: expected integer, got string
            // drift: body: field 'color' is not in the spec
        }
    }
)
```

- **Matching.** The operation is found by method and path template, after the first server URL's
  path (`https://{host}/v1` → `/v1`); a literal segment beats a `{parameter}`. The response schema is
  the exact status, then `2XX`, then `default`.
- **Breaking** — would fail a decode or mean wrong data: a type mismatch (`integer` admits only whole
  numbers, `boolean` only booleans), a missing `required` field, `null` without `nullable` or a
  `"null"` type, a string outside its `enum`, no `oneOf`/`anyOf` member matching, a field
  `additionalProperties: false` forbids, a body that is not JSON.
- **Drift** — what the spec does not mention: a field (judged against every `allOf` member at once),
  a status code, an operation.
- **Each violation once.** A renamed field fails on every response; it is reported the first time,
  per operation, pointer, and kind. `reportsEachViolationOnce: false` reports every time.
- **Sampling.** Checking parses the body a second time; `sampleRate` bounds that. A few percent is
  plenty in production.
- **Fail loudly in debug.** `failOnBreaking: true` throws `ContractViolationError`, which reaches the
  caller as `NetworkError.transport`.

Only successful responses are checked, because the transport throws for other status codes before
middleware runs. `$ref`, `allOf`, `oneOf`, `anyOf`, `items`, `properties`, and
`additionalProperties` are followed; bounds, patterns, and `format` are not checked.

`NovaNetworkOpenAPI` now depends on `NovaNetworkCore`, to vend the middleware.

## Compressed request bodies

`URLSession` has always decompressed responses; request bodies went out as they were. JSON compresses
5–10×, and the large requests are the ones an app sends on a reconnect — the offline queue's replay,
an analytics flush.

```swift
configuration.middlewares = [
    .compressingRequestBodies(RequestCompressionPolicy(hosts: ["sync.example.com"])),
    signingMiddleware,
]
```

- **Named hosts.** Most servers do not decompress request bodies unless configured to, so the policy
  names the hosts that do. `.anyHost()` exists, and has to be chosen.
- **Only when it pays.** Bodies of at least `minimumBodyBytes` (1 KB), with a JSON, `+json`, text,
  XML, form, or GraphQL content type (or none), without a `Content-Encoding` already, and only when
  the compressed body is smaller. `isEligible:` replaces the content-type rule.
- **`gzip` or `deflate`.** RFC 1952 gzip by default; `.deflate` sends an RFC 1950 zlib stream, which
  is what HTTP's `deflate` means.
- **Order matters.** Middleware runs in array order. Put compression before anything that signs or
  hashes the body.
- **Reported.** `onEvent` receives `.compressed(url:encoding:originalBytes:compressedBytes:)` or
  `.skipped(url:reason:)` — `host_not_listed`, `too_small`, `already_encoded`, `not_compressible`,
  `not_smaller`, `unavailable`.

On Linux the middleware sends every body unchanged and reports `unavailable`.

## GraphQL, through the client you already have

A GraphQL backend used to mean adopting a second network stack, or posting JSON by hand and losing
what HTTP does not know about GraphQL. `NovaNetworkGraphQL` is a new product that runs operations
through `NetworkClient`, so coalescing, retries, hedging, auth refresh, and diagnostics apply to them
unchanged.

```swift
struct CountryQuery: GraphQLOperation {
    static let document = "query Country($code: ID!) { country(code: $code) { name capital } }"
    static let operationName: String? = "Country"
    struct Variables: Encodable, Sendable { let code: String }
    struct Data: Decodable, Sendable { /* … */ }
    let variables: Variables
}

let graphQL = GraphQLClient(endpoint: endpoint, client: client, persistedQueries: .automatic)
let data = try await graphQL.data(for: CountryQuery(variables: .init(code: "NO")))
```

- **Partial results are kept.** GraphQL resolves fields independently; one failed field leaves the
  rest of `data` intact. `response(for:)` returns data and errors together. `data(for:)` throws
  `GraphQLResponseError`, which still carries `partialData`.
- **Errors in full.** `message`, `path` (field names and list indices), `locations`, `extensions`,
  and `code` for `extensions.code`.
- **Automatic persisted queries.** The first request sends only the document's SHA-256; on
  `PersistedQueryNotFound` it is resent with the document. On `PersistedQueryNotSupported` the
  client stops sending hashes for the rest of its life.
- **Mutations are never merged.** Identical concurrent queries share one request, as any request
  does. Mutations are sent with coalescing disabled — two identical likes are two likes.
- **`GET` for queries**, opt-in with `usesGETForQueries`, so a CDN or the HTTP cache can answer.
  With persisted queries the URL carries only the hash.
- **GraphQL errors inside a 4xx** are read as a GraphQL response; any other non-2xx stays the
  client's `NetworkError`.

`onEvent` reports `.persistedQueryRegistered`, `.persistedQueriesUnsupported`, and
`.partialResponse(operationName:errorCount:hasData:)`.

Not included: subscriptions, a normalized cache, code generation.
