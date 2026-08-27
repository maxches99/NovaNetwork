# NovaNetwork 3.2 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.2 — Adaptive concurrency limits
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, SRE
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 3.2.0
- Source baseline: 3.1 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.2.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.2.md`
  - Telemetry contract: `docs/TELEMETRY_CONTRACT_V2.md`

## 2. Goal and Scope

### Goal

Replace the accidental concurrency limit every client has — however many tasks the app happens to
start at once — with one that follows what the server can actually take.

### User value

The package already decides *whether* to send a request: coalescing, caching, retry, circuit
breaking, rate limiting. It has never decided *how many at once*. That number is either accidental
or a constant someone picked, and a constant is wrong in one of two directions: too low wastes a
fast server, too high buries a struggling one under the retries its own slowness caused.

### Scope split

- MVP / required for 3.2:
  - a policy with bounds and an algorithm that increases additively and decreases multiplicatively;
  - latency degradation as a congestion signal, not only refusals;
  - an admission actor that queues in arrival order and handles cancellation and a queue timeout;
  - wiring inside the coalescer so merged callers do not each take a slot;
  - a telemetry hook and a snapshot for reading the limit.
- Nice-to-have after MVP:
  - one limiter per host rather than per client;
  - holding no slot while a retry waits out its backoff;
  - a warm start from the last known good limit;
  - sharing a limit across an app and its extensions.

### Non-goals

- Replacing `RateLimitPolicy`. That refuses; this queues. They answer different questions and
  compose.
- Server-side fairness or quota enforcement.
- Deciding request priority — `RequestExecutionOptions` already does that.

### Definition of Done

- The algorithm is a value type tested by calling a function, not by racing tasks.
- Admission order, cancellation, and the queue timeout are each tested on observable state rather
  than on a sleep.
- The ceiling is proven through the real client with a transport that counts overlap.
- DFR, traceability pack, release notes, telemetry contract, README, and CHANGELOG updated together.

## 3. User Value

### User problem

A screen that fires twelve requests at once against an API that comfortably serves four does not get
faster; it gets slower, and then it starts failing, and then the retries make it worse. Nothing in
the client currently notices.

### Success metrics

- With a limit of N, no more than N requests reach the transport at once.
- A server that starts refusing or slowing down sees the limit fall within a few requests.
- A client with no policy behaves exactly as before, byte for byte in its request pattern.

## 4. Rollout, Dependencies, Risks

### Rollout plan

Additive and off by default. `NetworkClientConfiguration.adaptiveConcurrency` is `nil` unless set.

### Dependencies

None added.

### Risks and mitigations

- **A limiter is a place to deadlock.** Mitigated by keeping all admission state on one actor, by
  releasing in the same function that acquires, and by tests for cancellation before and during the
  wait.
- **Growth without evidence.** A limit that rises whenever a request succeeds drifts to the maximum.
  Mitigated by only growing on a request that actually waited for a slot.
- **A slow first response poisons the yardstick.** The best latency only ever improves, and the
  first sample is never compared against itself.
- **Retry backoff inside the slot.** A retrying request holds capacity while it waits. Stated as a
  limitation rather than hidden; moving the slot boundary is follow-up work.

## 5. Requirements

### Functional requirements (FR)

- **FR-19** The limit rises by one when a request that waited for a slot succeeds, capped at the
  maximum.
- **FR-20** The limit is multiplied by the backoff factor when congestion is observed, floored at
  the minimum, whether or not the request waited.
- **FR-21** A response slower than `latencyDegradationFactor` times the best seen counts as
  congestion. Failures unrelated to capacity — 404, cancellation, a malformed response — do not.
- **FR-22** Callers beyond the limit wait in arrival order rather than being refused.
- **FR-23** A cancelled caller stops waiting and leaves the queue intact; `queueTimeoutSeconds`
  makes a waiter give up with `NetworkError.timeoutBudgetExceeded`.
- **FR-24** No more than `limit` requests reach the transport at once.
- **FR-25** Callers merged by the coalescer share one slot, because they share one request.
- **FR-26** With no policy configured the client's behaviour is unchanged and no slot is taken.

### Analytics requirements (AR)

- **AR-2** Every limit movement is reported once through
  `NetworkTelemetryHooks.onConcurrencyLimitChanged`, carrying the previous limit, the new limit, and
  the reason. No URL, header, or body.

### Non-functional requirements (NFR)

- **NFR-7** Additive public API only; the API-breakage gate reports no breaking changes.

### Edge cases (EC)

- **EC-17** Nonsensical bounds — a negative minimum, a maximum below the minimum, a backoff factor
  above 1 — are clamped rather than trusted.
- **EC-18** The first response cannot be slow relative to itself.
- **EC-19** A negative, infinite, or NaN latency is ignored rather than believed.
- **EC-20** A task cancelled before it ever suspends is still cancelled, not admitted.
- **EC-21** Releasing a permit twice cannot drive the in-flight count negative.
- **EC-22** A limit that grows is an opening in its own right: one release can admit two waiters.

## 6. State Machine and Flows

Limit: `initial → (headroom) → +1 → … → maximum`, and `any → (congestion | latency) → ×factor →
minimum`.

Caller: `arrive → (slot free) admitted` or `arrive → queued → (release | growth) admitted`, with
`queued → cancelled` and `queued → timed out` as the two ways out that never reach the transport.

## 7. Engineering Notes

The algorithm is a `struct` with a `mutating func record` returning an optional `Change`. Keeping it
free of concurrency is what makes every branch testable by calling a function; the actor holds the
queue and nothing else about the decision.

`wasSaturated` rides on the permit rather than being read at release time, because it is only true
at the moment of admission and by the time the request finishes the answer has usually changed.

Admission and cancellation both run on the actor, which is what makes the ordering safe without
tracking cancellations that arrived before their continuation was stored.

## 8. Test Matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-19 | T-11.3…T-11.5 | unit | Engineering |
| FR-20 | T-11.6, T-11.7 | unit | Engineering |
| FR-21 | T-11.8…T-11.10, T-12.4, T-12.5 | unit | Engineering |
| FR-22 | T-11.13, T-11.14 | unit | Engineering |
| FR-23 | T-11.15, T-11.16 | unit | Engineering |
| FR-24, FR-26 | T-12.1, T-12.2 | integration | Engineering |
| FR-25 | T-12.3 | integration | Engineering |
| EC-17…EC-22 | T-11.1, T-11.2, T-11.11, T-11.12 | unit | Engineering |

### Negative tests

- A 404 and a cancellation do not shrink the limit.
- A hostname that does not resolve is not read as the server being busy.
- The limit does not grow while slots sit idle.
- Releasing the same permit twice does not corrupt the count.
