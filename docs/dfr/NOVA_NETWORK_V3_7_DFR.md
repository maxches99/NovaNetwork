# NovaNetwork 3.7 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.7 — tail latency, cold starts, contracts, and the tools around them
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering
- Status: `In Development`
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
