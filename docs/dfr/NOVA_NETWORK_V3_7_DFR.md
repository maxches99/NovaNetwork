# NovaNetwork 3.7 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.7 — tail latency, cold starts, contracts, and the tools around them
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering
- Status: `Implementation complete; pre-release CI gates pending`
- Target version: 3.7.0
- Source baseline: 3.6 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.7.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.7.md`

3.7 ships eight independent, additive, opt-in features. Each has its own section below with its
own requirement prefix, so a requirement ID names the feature it belongs to:

| § | Feature | Prefix |
|---|---|---|
| A | Hedged requests | `HEDGE` |
| B | Persisting the query cache across launches | `QPERSIST` |
| C | Checking responses against an OpenAPI contract | `CONTRACT` |
| D | Compressing request bodies | `COMPRESS` |
| E | GraphQL | `GQL` |
| F | Prefetching what is about to be on screen | `PREFETCH` |
| G | Copy as cURL and replay from the diagnostics panel | `CURL` |
| H | A cassette from a HAR | `HARCAS` |

### Definition of Done (whole release)

- Every testable FR/EC/AR in every section has at least one test, mapped in the traceability pack.
- Each feature is off unless the app asks for it; without it the client behaves exactly as in 3.6,
  asserted by a regression test per feature.
- DFR, traceability pack, release notes, README, and CHANGELOG updated together.
- Unit coverage stays at or above 90%; the E2E suite stays green.

### Rollout plan (whole release)

All eight are additive. New public types and new defaulted initializer parameters only; anything
the API digester reports is listed in `docs/api-breakage-allowlist.txt` with the reason.

---

## A. Hedged requests

### A.1 Goal

Cut the slow tail of read latency: when a request that is safe to repeat has not answered by the
time most requests to that host have, send it a second time and take whichever answer comes first.

### A.2 User value

A p50 of 80 ms and a p99 of 2 s is normal for mobile networks — a slow server instance, a lost
packet that waits on a retransmit timer, a cold cache on one replica. Retrying does not help: a
retry only starts after the first attempt has *failed*, and the slow one has not failed, it is just
slow. A hedge starts while the first is still running. Dean and Barroso's "The Tail at Scale"
reports a 99.9th percentile falling from 1,800 ms to 74 ms for 2% extra requests.

Every app that wants this writes it by hand around the client, and the hand-written versions
usually get one of three things wrong: they hedge writes, they never cancel the loser, or they have
no budget and double the load on a server that is slow because it is overloaded.

### A.3 Scope split

- MVP / required for 3.7:
  - opt-in `HedgingPolicy` on `NetworkClientConfiguration`;
  - hedge only requests that are safe to repeat: safe methods, or a request that carries an
    `Idempotency-Key`; replaceable by a predicate;
  - the hedge delay is a percentile of recent latencies to the same host, with a floor and a fixed
    delay until enough samples exist; or a fixed delay;
  - at most one hedge per attempt;
  - a budget: hedges never exceed a fraction of eligible requests, plus a small burst;
  - first success wins; the other request is cancelled;
  - telemetry for fired, won, and skipped-for-budget.
- Nice-to-have after MVP:
  - more than one hedge per attempt;
  - per-endpoint delays.

### A.4 Non-goals

- Hedging writes that carry no idempotency key. Never, whatever the predicate's author intended by
  default.
- Replacing retries. A hedge is for *slow*; a retry is for *failed*. A request that fails before
  the hedge delay is retried exactly as before.
- Hedging streams, uploads, downloads, or WebSocket traffic. Only the HTTP request/response path.

### A.5 Risks and mitigations

- **Doubling load on an overloaded server.** The budget caps hedges at a fraction of eligible
  requests (5% by default). A slow server makes more requests late, so without a budget the hedge
  rate would rise exactly when it hurts most.
- **Hedging a write.** The default predicate admits safe methods and requests with an
  `Idempotency-Key` only; the policy's documentation says that a custom predicate owns that
  decision.
- **A loser that is never cancelled** keeps a connection and a server worker busy. The race runs in
  a task group; the loser's task is cancelled the moment the winner returns, asserted.
- **Adaptive concurrency undercounts.** A hedge does not take a second permit from
  `AdaptiveConcurrencyLimiter`. Accepted and documented: the budget bounds the extra load, and a
  second permit could deadlock a limit of one.

### A.6 Requirements

#### Functional (FR)

- **FR-HEDGE-1** `NetworkClientConfiguration.hedging: HedgingPolicy?`, `nil` by default. With `nil`,
  the client sends exactly what it sent in 3.6.
- **FR-HEDGE-2** A request is eligible when the policy's predicate says so. The default predicate
  admits safe methods (`GET`, `HEAD`, `OPTIONS`) and any request with an `Idempotency-Key` header,
  matched case-insensitively.
- **FR-HEDGE-3** For an eligible request that has not completed after the hedge delay, the client
  sends the same prepared request a second time, at most once per attempt.
- **FR-HEDGE-4** The first successful response is returned, and the other request's task is
  cancelled.
- **FR-HEDGE-5** When one request fails while the other is still running, the client waits for the
  other; when both fail, the primary's error is returned.
- **FR-HEDGE-6** `HedgingDelay.fixed(seconds)` waits that long. `HedgingDelay.percentile(...)` waits
  the given percentile of the most recent successful latencies to the request's host, never less
  than its floor, and the fallback delay until the host has the minimum number of samples.
- **FR-HEDGE-7** A hedge is sent only when the budget allows it. Each eligible request earns
  `maximumHedgeRatio` of a hedge, up to `burst` saved; each hedge spends one.

#### Edge cases (EC)

- **EC-HEDGE-1** A request that fails before the hedge delay is not hedged; the error reaches the
  retry policy as before.
- **EC-HEDGE-2** An ineligible request (for example a `POST` without an idempotency key) is sent
  once, with no timer started.
- **EC-HEDGE-3** Cancelling the caller cancels both requests.
- **EC-HEDGE-4** Nonsensical policy values are clamped: a ratio outside `0...1`, a negative burst, a
  percentile outside `0...1`, negative delays.

#### Analytics (AR)

- **AR-HEDGE-1** `NetworkTelemetryHooks.onRequestHedged` receives `TelemetryHedgeContext` with type
  `fired` when the hedge is sent, carrying the delay waited.
- **AR-HEDGE-2** Type `won` when the hedge's response is the one returned. No `won` when the primary
  wins, and no `won` when the hedge fails.
- **AR-HEDGE-3** Type `budgetExhausted` when the delay elapsed but the budget refused the hedge.

### A.7 State machine

Per attempt of an eligible request:

| State | Event | Next | Report |
|---|---|---|---|
| `primary` | primary succeeds | done (primary) | — |
| `primary` | primary fails | done (error) | — |
| `primary` | delay elapses, budget allows | `racing` | fired |
| `primary` | delay elapses, budget refuses | `primaryOnly` | budgetExhausted |
| `racing` | either succeeds | done (that one), other cancelled | won, if the hedge |
| `racing` | one fails | `primaryOnly` / `hedgeOnly` | — |
| `primaryOnly`/`hedgeOnly` | it completes | done (its result; primary's error if both failed) | won, if the hedge succeeded |

### A.8 Engineering notes

The hedge wraps the transport the HTTP pipeline uses, not the client's `transport` property:
streaming, transfers, and WebSockets look the transport up by protocol conformance, and a wrapper
would hide those conformances. Wrapping below the middleware means both requests are the same
prepared request — same auth header, same signature, same idempotency key — and middleware runs
once.

The delay timer sleeps on `NetworkClientConfiguration.retryClock`, so a test that controls retry
time controls hedge time too. Latencies are measured on the system clock, like every other duration
the client reports.

Latency samples are kept per host, the most recent 128 successful ones. Failures are not samples: a
fast 503 would pull the percentile down and hedge everything.

### A.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-HEDGE-3, FR-HEDGE-4, AR-HEDGE-1, AR-HEDGE-2 | T-18.1 | unit | Engineering |
| FR-HEDGE-4, AR-HEDGE-2 | T-18.2 | unit | Engineering |
| FR-HEDGE-5 | T-18.3 | unit | Engineering |
| EC-HEDGE-1 | T-18.4 | unit | Engineering |
| FR-HEDGE-2, EC-HEDGE-2 | T-18.5 | unit | Engineering |
| FR-HEDGE-7, AR-HEDGE-3 | T-18.6 | unit | Engineering |
| FR-HEDGE-6 | T-18.7 | unit | Engineering |
| EC-HEDGE-3 | T-18.8 | unit | Engineering |
| EC-HEDGE-4 | T-18.9 | unit | Engineering |
| FR-HEDGE-1 (regression) | T-18.10 | unit | Engineering |

Negative tests: a `POST` without a key is never hedged (T-18.5); a hedge that fails reports no
`won` (T-18.3); a refused budget sends nothing (T-18.6).

E2E: not applicable. A hedge needs a request that is reliably slower than the delay, which no
public API provides on demand, and the E2E policy forbids a fake one.

---

## B. Persisting the query cache across launches

### B.1 Goal

A screen that showed data yesterday shows it again the moment the app launches, marked stale and
refreshed in the background, instead of a spinner until the network answers.

### B.2 User value

`QueryClient` keeps server state in memory only. On a cold start every screen is empty until its
first fetch returns — on a subway platform that is the whole session. Apps that want a warm start
write a second cache next to the query layer, and the two disagree about what is current.

### B.3 Scope split

- MVP / required for 3.7:
  - opt-in `QueryPersistence` on `QueryClient`, holding a store, a schema version, and a maximum age;
  - an explicit `persistedValue(for:...)` for `Codable` values — only queries that ask are written;
  - restoring a key lazily, the first time it is read after launch;
  - a file store (one file per key, atomic writes) and an in-memory store for previews and tests;
  - removing a key or everything removes it from the store too (sign-out);
  - events for restored, discarded (with the reason), and failed writes.
- Nice-to-have after MVP:
  - restoring every key eagerly at launch;
  - encrypting the store (the app can pass its own store today).

### B.4 Non-goals

- Persisting values that are not `Codable`, or queries read through `value(for:)`. Persisting is a
  decision per query, because a cache on disk outlives the session that filled it.
- Persisting optimistic values. They are a guess about a mutation's outcome; a crash before the
  mutation finishes would resurrect the guess as fact.
- Replacing a database. This is a warm start for screens, not offline storage of record.

### B.5 Risks and mitigations

- **A model changes shape between releases.** Decoding fails, or worse, succeeds wrongly. Records
  carry the schema version and the value's type name; either differing discards the record, and a
  record that fails to decode is discarded too. Bumping `version` invalidates everything.
- **Another user's data after sign-out.** `removeAll()` clears the store, asserted; the README's
  sign-out example calls it.
- **Out-of-order writes leave an older value on disk.** All writes from one client go through one
  serial chain in call order, asserted.
- **A full disk or unwritable directory.** Writes never throw into the query; they are reported as
  `writeFailed` and the in-memory value is unaffected.

### B.6 Requirements

#### Functional (FR)

- **FR-QPERSIST-1** `QueryClient(configuration:persistence:now:)`; `persistence` is `nil` by default,
  and with `nil` nothing is read or written.
- **FR-QPERSIST-2** `persistedValue(for:staleTime:fetch:)` behaves like `value(for:staleTime:fetch:)`
  and additionally writes each fetched value to the store.
- **FR-QPERSIST-3** When `persistedValue` finds nothing in memory, it restores the key from the store
  before deciding whether to fetch. A restored value's age is the time it was saved; it follows the
  same fresh/stale rules as any other value, so a stale one is returned at once and refreshed.
- **FR-QPERSIST-4** A record is discarded, and removed from the store, when its schema version or
  type name differs from the reader's, when it is older than `maximumAge`, or when it cannot be
  decoded.
- **FR-QPERSIST-5** `setValue` on a key read through `persistedValue` writes the value; optimistic
  values from `mutate` are never written.
- **FR-QPERSIST-6** `remove(_:)` removes the key from the store; `removeAll()` empties it.
- **FR-QPERSIST-7** `FileQueryPersistenceStore` keeps one file per key under a directory, written
  atomically; `InMemoryQueryPersistenceStore` keeps records in memory.
- **FR-QPERSIST-8** Writes from one client reach the store in the order they were made.

#### Edge cases (EC)

- **EC-QPERSIST-1** A key with nothing stored fetches exactly as without persistence.
- **EC-QPERSIST-2** A key already in memory is never overwritten by a restore.
- **EC-QPERSIST-3** A store that throws on write leaves the query's result and in-memory state intact.
- **EC-QPERSIST-4** Two keys whose file names would collide are told apart by the key stored inside
  the record.

#### Analytics (AR)

- **AR-QPERSIST-1** `QueryPersistence.onEvent` receives `.restored(key:age:)` when a record is used.
- **AR-QPERSIST-2** `.discarded(key:reason:)` with `versionMismatch`, `typeMismatch`, `expired`, or
  `unreadable`; no `restored` for that key.
- **AR-QPERSIST-3** `.writeFailed(key:)` when the store throws.

### B.7 State machine

Per key, on the first `persistedValue` read after launch:

| In memory | In store | Result | Report |
|---|---|---|---|
| value | — | in-memory rules, store untouched | — |
| none | none | fetch | — |
| none | valid, fresh | return it, no fetch | restored |
| none | valid, stale | return it, fetch in background | restored |
| none | wrong version / type, expired, unreadable | delete record, fetch | discarded(reason) |

### B.8 Engineering notes

`NovaNetworkQuery` depends on Foundation alone, so the file store names files with a 64-bit FNV-1a
hash of the key rather than SHA-256, and stores the key inside the record to rule out a collision.

Restore is lazy because a launch should not decode every screen the user has ever opened; the cost
lands on the first read of each key, where a warm value is what the read wants anyway.

The type name check uses `String(reflecting:)`, which includes the module, so two `User` types in two
modules do not read each other's records.

### B.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-QPERSIST-2, FR-QPERSIST-3, AR-QPERSIST-1 | T-19.1 | unit | Engineering |
| FR-QPERSIST-3 | T-19.2 | unit | Engineering |
| FR-QPERSIST-4, AR-QPERSIST-2 | T-19.3 | unit | Engineering |
| FR-QPERSIST-5 | T-19.4 | unit | Engineering |
| FR-QPERSIST-6 | T-19.5 | unit | Engineering |
| FR-QPERSIST-7, EC-QPERSIST-4 | T-19.6 | unit | Engineering |
| FR-QPERSIST-8 | T-19.7 | unit | Engineering |
| EC-QPERSIST-3, AR-QPERSIST-3 | T-19.8 | unit | Engineering |
| EC-QPERSIST-1, EC-QPERSIST-2 | T-19.9 | unit | Engineering |
| FR-QPERSIST-1 (regression) | T-19.10 | unit | Engineering |

Negative tests: an optimistic value is not on disk after a crash-equivalent (a new client on the same
store) (T-19.4); each discard reason produces no `restored` (T-19.3).

E2E: not applicable — nothing here touches the network.

---

## C. Checking responses against an OpenAPI contract

### C.1 Goal

Notice when the server stops matching its own specification — a field renamed, a type changed, a
new enum value — from real traffic, before a decode failure in production is the first sign.

### C.2 User value

API drift is found today by a crash report: a `DecodingError` on some users' devices, days after a
backend deploy. The spec that would have caught it is already in the repository — the generator
reads it — but nothing compares it with what the server actually sends. Contract-testing tools
exist for the backend side; on the client side, nothing in the Swift ecosystem does this.

### C.3 Scope split

- MVP / required for 3.7:
  - `OpenAPIContract`, built from the same document `nova-openapi` reads;
  - matching a response to its operation (method, path template, server base path) and to its
    response schema (exact status, `2XX`, `default`);
  - validating JSON bodies: types, `required`, `nullable` / `type: [.., "null"]`, `enum`, `items`,
    `properties`, `additionalProperties`, `$ref`, `allOf`, `oneOf`, `anyOf`;
  - two severities: *breaking* (what would fail a decode or mean wrong data) and *drift* (fields,
    status codes, or operations the spec does not mention);
  - a `NetworkMiddleware` with a sample rate that reports each distinct violation once, and can fail
    the request on a breaking violation for debug builds and tests.
- Nice-to-have after MVP:
  - error responses (the transport throws for non-2xx, so middleware never sees them);
  - `format` checks (`date-time`, `uuid`);
  - showing violations in the diagnostics panel.

### C.4 Non-goals

- Validating requests the app sends. The app's own code is what the generator already typed.
- A complete JSON Schema implementation. Numeric bounds, string patterns, and lengths are out of
  scope: they describe valid data, not the data's shape, and a drift detector that reported them
  would be noise.

### C.5 Risks and mitigations

- **Cost on the main path.** Parsing every body twice is waste in production. `sampleRate`
  (default 1 in debug use, recommended 0.01–0.05 in production) and an early exit for non-JSON
  content types bound it.
- **Report floods.** A renamed field fails on every response. Each distinct violation (operation,
  pointer, kind) is reported once per middleware instance by default.
- **A wrong spec reports a correct server.** That is the point: either the spec or the server is
  wrong, and the report says which field to look at.
- **`NovaNetworkOpenAPI` gains a dependency on `NovaNetworkCore`** to vend the middleware. Core is
  the transport-neutral layer the generated code already imports; no new external dependency.

### C.6 Requirements

#### Functional (FR)

- **FR-CONTRACT-1** `OpenAPIContract(specText:)` and `OpenAPIContract(document:)` build a contract
  from JSON or YAML; a document without `paths` is rejected.
- **FR-CONTRACT-2** A response is matched to an operation by method and path template, after
  stripping the first server URL's path; a literal segment outranks a `{parameter}` segment.
- **FR-CONTRACT-3** The response schema is chosen by exact status code, then `NXX`, then `default`.
- **FR-CONTRACT-4** A JSON body is checked against the schema for: type (`integer` admits only whole
  numbers; `number` admits any; `boolean` admits only booleans), `required`, null (allowed only by
  `nullable: true` or a `"null"` type), `enum`, array `items`, and object `properties`.
- **FR-CONTRACT-5** `$ref` is followed; `allOf` requires every member; `oneOf` / `anyOf` require at
  least one member to match, and report `noMatchingSchema` otherwise.
- **FR-CONTRACT-6** A property not described by `properties` (across every `allOf` member) is a
  drift violation, unless `additionalProperties` allows it; with an `additionalProperties` schema the
  extra values are validated against it; with `additionalProperties: false` the extra property is
  breaking.
- **FR-CONTRACT-7** A response whose operation or status code the spec does not describe is a drift
  violation; a body that is not valid JSON is breaking.
- **FR-CONTRACT-8** `NetworkMiddleware.openAPIContract(_:sampleRate:reportsEachViolationOnce:failOnBreaking:onReport:)`
  validates sampled successful responses and calls `onReport` with a `ContractReport` when there is
  at least one violation.
- **FR-CONTRACT-9** With `failOnBreaking`, a response with a breaking violation throws
  `ContractViolationError` carrying the report.

#### Edge cases (EC)

- **EC-CONTRACT-1** A response with a non-JSON content type is not validated.
- **EC-CONTRACT-2** A response whose schema has no content (`204`) is not validated, whatever the body.
- **EC-CONTRACT-3** A recursive schema (`Pet.parent: Pet`) validates as deep as the data goes.
- **EC-CONTRACT-4** A sample rate outside `0...1` is clamped; `0` validates nothing.
- **EC-CONTRACT-5** A server URL with variables (`https://{host}/v1`) still yields its base path.

#### Analytics (AR)

- **AR-CONTRACT-1** `onReport` receives the method, the URL path, the matched path template (when
  there is one), the status code, and every violation with its JSON pointer, kind, and severity.
- **AR-CONTRACT-2** A conforming response produces no report.
- **AR-CONTRACT-3** With `reportsEachViolationOnce`, a violation already reported for the same
  operation, pointer, and kind is left out; a report with nothing left is not sent.

### C.7 Flow

`response → sampled? → JSON content type? → operation found? (no: drift) → status documented? (no:
drift) → schema has content? → parse (fail: breaking) → validate → de-duplicate → report / throw`.

State → UI → action for the app: *breaking* → page someone, the next release's decode will fail;
*drift* → update the spec or ask the backend; both carry the pointer to the field.

### C.8 Engineering notes

Bodies are parsed with `JSONDecoder` into a small JSON value enum rather than with
`JSONSerialization`, because `JSONSerialization` returns `true` and `1` as the same `NSNumber` on
Linux, and telling a boolean from an integer is half of what a type check is.

For `oneOf` / `anyOf`, a member "matches" when it produces no breaking violation; drift inside a
candidate member is not reported, because which member the server meant is a guess.

`allOf` members are validated one by one for types and `required`, but undocumented properties are
judged against the union of every member's `properties` — otherwise a field documented in one member
would be reported as unknown by the other.

### C.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-CONTRACT-1, EC-CONTRACT-5 | T-20.1 | unit | Engineering |
| FR-CONTRACT-2, FR-CONTRACT-3, FR-CONTRACT-7 | T-20.2 | unit | Engineering |
| FR-CONTRACT-4 | T-20.3 | unit | Engineering |
| FR-CONTRACT-5, EC-CONTRACT-3 | T-20.4 | unit | Engineering |
| FR-CONTRACT-6 | T-20.5 | unit | Engineering |
| FR-CONTRACT-8, AR-CONTRACT-1, AR-CONTRACT-2 | T-20.6 | unit | Engineering |
| AR-CONTRACT-3 | T-20.7 | unit | Engineering |
| FR-CONTRACT-9 | T-20.8 | unit | Engineering |
| EC-CONTRACT-1, EC-CONTRACT-2, EC-CONTRACT-4 | T-20.9 | unit | Engineering |
| Regression (petstore conforming traffic) | T-20.10 | unit | Engineering |

Negative tests: a boolean where an integer is expected, `1.5` where an integer is expected, `null`
where null is not allowed (T-20.3); a conforming response produces no report (T-20.6, T-20.10).

E2E: not applicable. The policy allows only real public APIs, and none publishes a spec it is known to
match exactly; a report against one would test the API, not the client.

---

## D. Compressing request bodies

### D.1 Goal

Send large request bodies — a sync batch, an analytics flush, a JSON document — gzip-compressed to
servers that accept it, so uploads on a slow or metered link take a fraction of the bytes.

### D.2 User value

Responses have been compressed by `URLSession` for as long as it has existed; request bodies never
are. JSON compresses 5–10×, and the requests that are large are exactly the ones a mobile app sends
on reconnect: the offline queue's replay, a batch of events. Hand-rolled compression usually breaks
request signing (the signature covers the uncompressed bytes) or compresses for a server that
rejects it.

### D.3 Scope split

- MVP / required for 3.7:
  - `NetworkMiddleware.compressingRequestBodies(_:onEvent:)`, opt-in, with a `RequestCompressionPolicy`;
  - compress only for hosts the app names (or every host, explicitly), only bodies above a minimum
    size, only compressible content types, only when the result is smaller;
  - `gzip` (RFC 1952) and `deflate` (RFC 1950 zlib) encodings;
  - an event per decision: compressed with sizes, or skipped with the reason.
- Nice-to-have after MVP:
  - learning from a `415 Unsupported Media Type` to stop compressing for that host;
  - Brotli and zstd.

### D.4 Non-goals

- Compressing for every server by default. Most servers do not decompress request bodies unless
  configured to; compressing for one that does not turns every write into a 400.
- Compressing streams, multipart uploads, or files on disk.
- Linux. Foundation on Linux has no compressor; there the middleware reports `unavailable` and sends
  the body unchanged.

### D.5 Risks and mitigations

- **A server that does not decompress.** Hosts are opt-in; the policy cannot be built without naming
  them or choosing `.anyHost` explicitly.
- **Signing covers the wrong bytes.** Middleware runs in array order; the documentation and the
  README example put compression before signing, so the signature covers the bytes that are sent.
- **Double compression.** A request that already has a `Content-Encoding` header is left alone.
- **CPU on the main path.** Bodies below `minimumBodyBytes` (1 KB by default) are not compressed: the
  saving is smaller than the cost.

### D.6 Requirements

#### Functional (FR)

- **FR-COMPRESS-1** `NetworkMiddleware.compressingRequestBodies(_:onEvent:)` returns a `beforeSend`
  middleware; without it no body is ever compressed.
- **FR-COMPRESS-2** A body is compressed only when the request's host is in the policy's hosts (or the
  policy is `.anyHost`), the body is at least `minimumBodyBytes`, the request has no
  `Content-Encoding`, and its `Content-Type` is compressible (JSON, `+json`, text, XML,
  `application/x-www-form-urlencoded`, or absent).
- **FR-COMPRESS-3** The compressed body replaces the original only when it is smaller; the request
  then carries `Content-Encoding: gzip` or `deflate`.
- **FR-COMPRESS-4** `gzip` output is a valid RFC 1952 member (header, DEFLATE data, CRC-32, size);
  `deflate` output is a valid RFC 1950 stream (header, DEFLATE data, Adler-32).
- **FR-COMPRESS-5** The policy's `isEligible` closure, when given, replaces the content-type rule.

#### Edge cases (EC)

- **EC-COMPRESS-1** A request with no body, or an empty one, passes through without an event.
- **EC-COMPRESS-2** Data that does not compress (already compressed, random) is sent unchanged.
- **EC-COMPRESS-3** A host is matched case-insensitively.
- **EC-COMPRESS-4** A negative `minimumBodyBytes` is clamped to `0`.

#### Analytics (AR)

- **AR-COMPRESS-1** `onEvent` receives `.compressed(url:encoding:originalBytes:compressedBytes:)`.
- **AR-COMPRESS-2** `.skipped(url:reason:)` with `hostNotListed`, `tooSmall`, `alreadyEncoded`,
  `notCompressible`, `notSmaller`, or `unavailable`; no `compressed` for that request.

### D.7 Flow

`request → has body? (no: pass, silent) → host listed? → large enough? → not encoded? → compressible
type? → compress → smaller? → replace body + header, report compressed`; each "no" reports skipped
with its reason and sends the original.

### D.8 Engineering notes

DEFLATE comes from Apple's Compression framework (`COMPRESSION_ZLIB`, which is raw RFC 1951 data);
the gzip and zlib framing and their checksums are written here, because the framework produces
neither. That is 40 lines, against a dependency.

It is a middleware rather than a configuration field because where it sits relative to signing
matters, and middleware order is the one place in the client where that is already explicit.

### D.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-COMPRESS-3, FR-COMPRESS-4, AR-COMPRESS-1 | T-21.1 | unit | Engineering |
| FR-COMPRESS-4 | T-21.2 | unit | Engineering |
| FR-COMPRESS-2, AR-COMPRESS-2, EC-COMPRESS-3 | T-21.3 | unit | Engineering |
| EC-COMPRESS-2 | T-21.4 | unit | Engineering |
| FR-COMPRESS-5 | T-21.5 | unit | Engineering |
| EC-COMPRESS-1, EC-COMPRESS-4 | T-21.6 | unit | Engineering |
| FR-COMPRESS-1 (through the client, with ordering) | T-21.7 | unit | Engineering |

Negative tests: an unlisted host, a small body, an encoded body, and a multipart body are each sent
unchanged with their reason (T-21.3); random bytes are not "compressed" larger (T-21.4).

E2E: `https://httpbin.org/anything` echoes what it receives but does not decompress request bodies,
so it cannot confirm the server side; the round trip is verified by decompressing in the unit tests.

---

## E. GraphQL

### E.1 Goal

Run GraphQL operations through `NetworkClient` — and so through its coalescing, retries, hedging,
auth refresh, diagnostics, and offline-aware policies — with typed operations, partial results that
are not thrown away, and automatic persisted queries.

### E.2 User value

An app with a GraphQL backend either adopts Apollo iOS — a second network stack, with its own cache,
code generator, and interceptors — or posts JSON by hand through `NetworkClient` and loses the parts
of GraphQL that HTTP does not know about: an error list beside the data, `PersistedQueryNotFound`,
and the fact that two identical mutations must never be merged into one.

### E.3 Scope split

- MVP / required for 3.7:
  - a `NovaNetworkGraphQL` product with a `GraphQLOperation` protocol (document, variables, data type,
    query or mutation);
  - `GraphQLClient.response(for:)` returning data and errors together, and `data(for:)` that throws
    when there are errors;
  - errors with `message`, `path`, `locations`, and `extensions`;
  - automatic persisted queries (Apollo's protocol): send the hash, and the document only when the
    server asks;
  - identical concurrent queries share one request; mutations never do;
  - optionally sending queries as `GET`, so a CDN or the HTTP cache can serve them;
  - a GraphQL error body inside a non-2xx response is read as GraphQL, not reported as a bare status.
- Nice-to-have after MVP:
  - subscriptions over `graphql-transport-ws`;
  - a normalized cache;
  - generating operations from `.graphql` files.

### E.4 Non-goals

- A normalized cache. `NovaNetworkQuery` caches by key, which is what most screens need; a graph
  cache is a different product.
- Code generation. Operations are written by hand or by an external generator against the protocol.

### E.5 Risks and mitigations

- **Merging two mutations.** Coalescing is by request fingerprint, so two identical mutation bodies
  would be one request. Mutations are sent with coalescing disabled, asserted.
- **A server without APQ support.** It answers `PersistedQueryNotSupported`; the client resends with
  the document and stops sending hashes for the rest of its lifetime.
- **`GET` URLs too long.** `GET` is opt-in, only for queries, and only carries the hash when APQ is on;
  without APQ the document goes in the URL and the README says so.

### E.6 Requirements

#### Functional (FR)

- **FR-GQL-1** `GraphQLOperation` declares `document`, `operationName`, `kind`, `variables`, and a
  `Decodable` `Data` type.
- **FR-GQL-2** `response(for:)` posts `{query, operationName, variables}` as JSON (keys sorted) with
  `Accept: application/graphql-response+json, application/json`, and returns a `GraphQLResponse`
  holding the decoded `data` (if any) and every error.
- **FR-GQL-3** `data(for:)` returns the data when there are no errors, and throws
  `GraphQLResponseError` carrying the errors and any partial data otherwise.
- **FR-GQL-4** `GraphQLError` decodes `message`, `path` (strings and integers), `locations`, and
  `extensions` (any JSON).
- **FR-GQL-5** With `persistedQueries: .automatic`, the first request sends only
  `extensions.persistedQuery {version: 1, sha256Hash}`; on `PersistedQueryNotFound` it is resent with
  the document and the hash; on `PersistedQueryNotSupported` it is resent with the document, and APQ
  is turned off for that client.
- **FR-GQL-6** Queries are coalesced by their body; mutations are sent with coalescing disabled.
- **FR-GQL-7** With `usesGETForQueries`, queries are sent as `GET` with `operationName`, `variables`,
  and `extensions` (or `query`) in the URL; mutations are always `POST`.
- **FR-GQL-8** A non-2xx response whose body is a GraphQL response is returned as one; any other
  non-2xx is rethrown unchanged.

#### Edge cases (EC)

- **EC-GQL-1** `data: null` with errors yields a response with no data; `data(for:)` throws.
- **EC-GQL-2** An operation with no variables sends no `variables` key.
- **EC-GQL-3** The persisted-query error is recognised by `extensions.code`
  (`PERSISTED_QUERY_NOT_FOUND`, `PERSISTED_QUERY_NOT_SUPPORTED`) or by the message.
- **EC-GQL-4** A body that is not a GraphQL response surfaces as `NetworkError.decoding`.

#### Analytics (AR)

- **AR-GQL-1** `onEvent` receives `.persistedQueryRegistered(operationName:)` when the document had
  to be sent after a miss, and `.persistedQueriesUnsupported` once when APQ is turned off.
- **AR-GQL-2** `.partialResponse(operationName:errorCount:hasData:)` for every response with errors;
  none for a clean one.

### E.7 State machine (APQ, per client)

`enabled → (PersistedQueryNotSupported) → disabled`. Per request under `enabled`:
`hash only → ok | NotFound → hash + document → ok`. A request under `disabled` sends the document.

### E.8 Engineering notes

The body is encoded with sorted keys so that two identical operations always produce the same bytes,
which is what the coalescer keys on.

`GraphQLClient` is an actor only for the APQ switch; requests do not wait on each other.

### E.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-GQL-1, FR-GQL-2, EC-GQL-2 | T-22.1 | unit | Engineering |
| FR-GQL-3, FR-GQL-4, EC-GQL-1, AR-GQL-2 | T-22.2 | unit | Engineering |
| FR-GQL-5, EC-GQL-3, AR-GQL-1 | T-22.3 | unit | Engineering |
| FR-GQL-5 (unsupported), AR-GQL-1 | T-22.4 | unit | Engineering |
| FR-GQL-6 | T-22.5 | unit | Engineering |
| FR-GQL-7 | T-22.6 | unit | Engineering |
| FR-GQL-8, EC-GQL-4 | T-22.7 | unit | Engineering |
| End-to-end against a public GraphQL API | T-22.8 | E2E | Engineering |

Negative tests: two identical mutations are two requests (T-22.5); a non-GraphQL 500 stays a 500
(T-22.7); a clean response emits no `partialResponse` (T-22.2).

E2E: `https://countries.trevorblades.com/graphql` is a public GraphQL API; T-22.8 runs a typed query
against it under `RUN_E2E_TESTS=1`.

---

## F. Prefetching what is about to be on screen

### F.1 Goal

Let a list warm the cache for rows as they come into view, and stop warming rows the user has
scrolled past — without those prefetches crowding out the requests for what is on screen now.

### F.2 User value

`QueryClient.prefetch` starts a fetch and forgets it. A fast scroll through a feed calls it for
every row: fifty detail requests in flight, most for rows already gone, each competing with the one
row the user stopped on. Apps that care write a queue, a concurrency limit, and cancellation around
it, and usually get the race between "cancel the prefetch" and "the row reappeared and is now
waiting on it" wrong.

### F.3 Scope split

- MVP / required for 3.7:
  - `prefetchWhileVisible(_:staleTime:fetch:)` and `cancelPrefetch(_:)`, for `onAppear` and
    `onDisappear`;
  - a limit on concurrent prefetches (`QueryConfiguration.maximumConcurrentPrefetches`, 4 by
    default); the rest wait, most recent first;
  - cancelling a waiting prefetch removes it; cancelling a running one cancels its task — unless a
    reader or a subscriber has started waiting on it, in which case it is left to finish;
  - a read of a key with a waiting prefetch fetches it at once instead;
  - an event stream: queued, started, completed, skipped (fresh), cancelled, promoted.
- Nice-to-have after MVP:
  - passing a priority into the fetch closure so `NetworkClient` can schedule it lower;
  - a SwiftUI modifier.

### F.4 Non-goals

- Deciding what is about to be visible. The list knows; it calls `prefetchWhileVisible` from
  `onAppear` or a prefetching data source.
- Changing `prefetch(_:staleTime:fetch:)`, which keeps its fire-and-forget behaviour.

### F.5 Risks and mitigations

- **Cancelling a fetch someone is waiting on.** Every read and refetch "promotes" the key; a promoted
  or subscribed fetch is never cancelled by `cancelPrefetch`, asserted.
- **A cancelled fetch that completes anyway** (a fetch closure that ignores cancellation) arriving
  after a newer fetch. Each prefetch carries an identity; a result from an abandoned one is dropped.
- **A cancellation shown as a failure.** A cancelled prefetch leaves the key as it was, with no error.

### F.6 Requirements

#### Functional (FR)

- **FR-PREFETCH-1** `prefetchWhileVisible` does nothing for a fresh key or a key already being
  fetched; otherwise it queues the key.
- **FR-PREFETCH-2** At most `maximumConcurrentPrefetches` (at least 1) prefetches run at once; queued
  keys start most recent first as running ones finish or are cancelled.
- **FR-PREFETCH-3** `cancelPrefetch` removes a queued key; for a running prefetch with no subscriber
  that nobody has promoted, it cancels the task and restores the key's previous state.
- **FR-PREFETCH-4** `value(for:)` and `refetch(_:)` on a queued key take it out of the queue and fetch
  it at once; on a running prefetch they wait for it and mark it promoted.
- **FR-PREFETCH-5** A result from a cancelled prefetch is not stored.

#### Edge cases (EC)

- **EC-PREFETCH-1** Calling `prefetchWhileVisible` twice for one key queues it once.
- **EC-PREFETCH-2** `cancelPrefetch` for a key that is not being prefetched does nothing.
- **EC-PREFETCH-3** A failing prefetch records its error like any fetch and frees its slot.
- **EC-PREFETCH-4** A `maximumConcurrentPrefetches` below 1 behaves as 1.

#### Analytics (AR)

- **AR-PREFETCH-1** `prefetchEvents()` yields `.queued`, `.started`, `.completed`, `.failed`,
  `.skippedFresh`, `.cancelled(wasRunning:)`, and `.promoted` with the key.
- **AR-PREFETCH-2** No `.completed` for a cancelled prefetch.

### F.7 State machine

Per key: `idle → queued → running → (completed | failed)`; `queued → (cancelled | promoted→fetch)`;
`running → cancelled` (no subscriber, not promoted) | `running → promoted → completed`.

### F.8 Engineering notes

Most recent first, because in a scrolling list the row that appeared last is the one nearest the
user's attention; the oldest queued row has usually scrolled away.

The limit is the query layer's own. `NetworkClient` has priorities and adaptive concurrency, but the
query layer is deliberately independent of it, so the slot count lives here.

### F.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-PREFETCH-1, EC-PREFETCH-1, AR-PREFETCH-1 | T-23.1 | unit | Engineering |
| FR-PREFETCH-2, EC-PREFETCH-4 | T-23.2 | unit | Engineering |
| FR-PREFETCH-3, AR-PREFETCH-2 | T-23.3 | unit | Engineering |
| FR-PREFETCH-4 | T-23.4 | unit | Engineering |
| FR-PREFETCH-5 | T-23.5 | unit | Engineering |
| EC-PREFETCH-2, EC-PREFETCH-3 | T-23.6 | unit | Engineering |

Negative tests: cancelling a promoted prefetch does not cancel it (T-23.4); a cancelled prefetch's
late result is dropped (T-23.5).

E2E: not applicable — the query layer does no networking of its own.

---

## G. Copy as cURL and replay from the diagnostics panel

### G.1 Goal

Turn a recorded request into something a backend engineer can run — a `curl` command — and let a
developer send it again from the panel, without either path leaking a credential.

### G.2 User value

"It fails on my phone" ends in a screenshot of the panel and a backend engineer retyping the request.
A `curl` command is the lingua franca for "this is exactly what was sent". Replaying from the panel
answers "is it still failing?" without reproducing the steps that led there.

### G.3 Scope split

- MVP / required for 3.7:
  - `RequestDiagnostic.curlCommand()`: method, URL, headers, and body as recorded;
  - `RequestDiagnostic.replayRequest(redactionPlaceholder:)`: an `APIRequest` rebuilt from the
    record, or the reason it cannot be;
  - `NetworkClient.replay(_:authScope:)` sending it through the client, uncoalesced and uncached;
  - "Copy as cURL" and "Replay" in the panel's request detail.
- Nice-to-have after MVP:
  - exporting every request as a shell script;
  - HTTPie and `fetch()` formats.

### G.4 Non-goals

- Restoring redacted values. The record never held them; replay leaves redacted headers out so the
  app's middleware adds fresh ones.

### G.5 Risks and mitigations

- **A token in a pasted command.** The command is built from the record, which is redacted when it
  is made; a redacted header appears with the placeholder, so the reader knows it existed.
- **Replaying a write twice.** Replay is a button a developer presses on a request they are looking
  at; the panel labels it with the method, and the README says it sends the request again.
- **Replaying a partial body.** A body that was not captured, or was truncated, makes replay
  unavailable with that reason rather than sending something else.

### G.6 Requirements

#### Functional (FR)

- **FR-CURL-1** `curlCommand()` produces `curl` with `-X <method>` (omitted for `GET` without a body),
  the URL, one `-H` per header in name order, and `--data-raw` with the body when it was captured
  in full and is UTF-8; every argument is single-quoted with embedded quotes escaped.
- **FR-CURL-2** A binary body becomes `--data-binary @body.bin` with a comment giving its size; a
  truncated or uncaptured body becomes a comment saying so.
- **FR-CURL-3** `replayRequest` returns the method, URL, and body of the record, and every header
  except those whose value is the redaction placeholder.
- **FR-CURL-4** `replayRequest` fails with `bodyNotCaptured`, `bodyTruncated`, `urlRedacted`, or
  `invalidRecord` (an unknown method or an unparseable URL) instead of guessing.
- **FR-CURL-5** `NetworkClient.replay(_:authScope:)` sends the rebuilt request with coalescing
  disabled and `CachePolicy.networkOnly`, so it reaches the server.
- **FR-CURL-6** The panel's request detail offers "Copy as cURL" and, when the panel is given an
  `onReplay` closure, "Replay".

#### Edge cases (EC)

- **EC-CURL-1** A header value or body containing `'` is still a single valid shell word.
- **EC-CURL-2** A record with no body sends none; a recorded empty body is sent empty.

#### Analytics (AR)

Not applicable: these are developer actions inside a debug tool, not product events.

### G.7 Flow

`record → curlCommand() → pasteboard`; `record → replayRequest() → (request | reason) →
client.replay → new record in the recorder`.

### G.8 Engineering notes

`replay` lives in `NovaNetworkDiagnostics` as an extension on `NetworkClient` because rebuilding a
request from a record is a diagnostics concern, and the client should not know records exist.

### G.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-CURL-1, EC-CURL-1 | T-24.1 | unit | Engineering |
| FR-CURL-2 | T-24.2 | unit | Engineering |
| FR-CURL-3, EC-CURL-2 | T-24.3 | unit | Engineering |
| FR-CURL-4 | T-24.4 | unit | Engineering |
| FR-CURL-5 | T-24.5 | unit | Engineering |
| FR-CURL-6 | T-24.6 (demo app UI test; the view is excluded from coverage) | UI | Engineering |

E2E: not applicable — replay sends whatever was recorded; the transport path it uses is already
covered by the E2E suite.

---

## H. A cassette from a HAR

### H.1 Goal

Turn a HAR file — from a tester's device via `HARExporter`, from Safari or Chrome, from Charles or
Proxyman — into a cassette, so a bug seen on someone else's device becomes a test that replays the
exact responses.

### H.2 User value

A HAR attached to a bug report can be read in the inspector, but reproducing the bug still means
finding a server state that produces the same responses. A cassette replays them deterministically;
the missing step is converting one into the other, by hand, entry by entry.

### H.3 Scope split

- MVP / required for 3.7:
  - `Cassette.fromHAR(_:redaction:include:)` returning the cassette and a list of skipped entries
    with reasons;
  - redaction applied during conversion with the cassette's own `CassetteRedaction`, so no secret
    from the HAR reaches the file;
  - an `include` filter, because a browser HAR also holds every image, font, and analytics beacon;
  - entries that cannot be replayed faithfully are skipped and listed rather than recorded wrong.
- Nice-to-have after MVP:
  - a `nova-har-to-cassette` command-line tool.

### H.4 Non-goals

- Timing. Cassettes replay without delays; HAR timings stay in the HAR.
- Reconstructing bodies HAR did not keep.

### H.5 Risks and mitigations

- **Secrets in the HAR.** Browsers export cookies and authorization headers verbatim. Conversion
  runs the redaction on headers, query items, and bodies before anything is in the cassette; the
  default policy is the cassette's default.
- **A replay that lies.** An entry whose response body was not captured, or was truncated, would
  replay as an empty or partial body. Such entries are skipped and reported.
- **Headers that no longer describe the body.** HAR stores decoded content, so `Content-Encoding` and
  `Content-Length` from the original response are wrong for it; both are dropped, as are HTTP/2
  pseudo-headers (`:authority`).

### H.6 Requirements

#### Functional (FR)

- **FR-HARCAS-1** `Cassette.fromHAR` reads HAR 1.x and returns one interaction per usable entry, in
  file order, with method, URL, headers, and bodies.
- **FR-HARCAS-2** Response bodies come from `content.text`, base64-decoded when `content.encoding` is
  `base64`; request bodies from `postData.text`.
- **FR-HARCAS-3** Redaction is applied to request and response headers, the URL's query items, and
  both bodies.
- **FR-HARCAS-4** An entry is skipped, with its index, URL, and reason, when it is malformed, was
  aborted (status `0` or below), has a response body HAR did not keep, has a truncated body
  (`HARExporter`'s comment), or is excluded by `include`.
- **FR-HARCAS-5** `Content-Encoding`, `Content-Length`, and pseudo-headers are dropped from recorded
  headers.
- **FR-HARCAS-6** A file that is not JSON, not a HAR log, or a HAR major version other than 1 throws
  `HARConversionError`.

#### Edge cases (EC)

- **EC-HARCAS-1** Repeated header names are joined with `, ` as HTTP allows.
- **EC-HARCAS-2** An entry with an empty response body records no body.

#### Analytics (AR)

Not applicable: a developer tool with no runtime events. The `skipped` list is the report.

### H.7 Flow

`HAR → parse → per entry: well-formed? → included? → not aborted? → bodies kept? → redact → strip
stale headers → interaction`; every "no" adds a skipped entry.

### H.8 Engineering notes

The conversion lives in `NovaNetworkCassette` and parses HAR itself rather than going through
`HARImporter`: the cassette module depends on `NovaNetworkCore` alone so preview and demo builds can
link it, and `HARImporter` lives in the diagnostics module, which needs the whole client. HAR's
shape is small enough that a second reader is cheaper than the dependency.

### H.9 Test matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-HARCAS-1, FR-HARCAS-2, EC-HARCAS-1 | T-25.1 | unit | Engineering |
| FR-HARCAS-3 | T-25.2 | unit | Engineering |
| FR-HARCAS-4, EC-HARCAS-2 | T-25.3 | unit | Engineering |
| FR-HARCAS-5 | T-25.4 | unit | Engineering |
| FR-HARCAS-6 | T-25.5 | unit | Engineering |
| Round trip: `HARExporter` → `fromHAR` → `CassetteTransport` replay | T-25.6 | unit | Engineering |

E2E: not applicable — conversion reads a file and makes no request.
