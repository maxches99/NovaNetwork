# What's New in 3.2

## A concurrency limit that is not a guess

Every client has a concurrency limit. Usually it is accidental — however many tasks the app happens
to start at once — and when it is deliberate it is a number someone picked. Both are guesses, and a
guess is wrong in one of two directions: too low and a fast server sits idle; too high and a
struggling one is buried under the retries its own slowness caused.

`AdaptiveConcurrencyPolicy` starts from a guess and then corrects it:

```swift
var configuration = NetworkClientConfiguration()
configuration.adaptiveConcurrency = AdaptiveConcurrencyPolicy(
    minimumLimit: 1,
    maximumLimit: 16,
    initialLimit: 6
)
let client = NetworkClient(configuration: configuration)
```

That is the whole installation. It is off by default: with no policy the client admits requests
exactly as it always has.

### Additive up, multiplicative down

The limit grows by one and shrinks by a factor, never the other way round. Backing off slowly from
an overloaded server is how a client turns a slowdown into an outage.

It grows only when the limit was actually the thing in the way — when a request had to wait for a
slot and then succeeded. Raising it while slots sit idle would let it drift to the maximum without
any evidence the server can take it.

### Slower counts as congestion, before refusals do

A server gets slower before it starts refusing. Comparing each response against the fastest one this
policy has seen turns that into a signal that arrives in time to matter:

```swift
AdaptiveConcurrencyPolicy(latencyDegradationFactor: 2.0)   // twice the best seen is congestion
AdaptiveConcurrencyPolicy(latencyDegradationFactor: .infinity)  // react only to refusals
```

Only failures that mean "too much at once" count: 429, 503, timeouts, connection loss. A 404 is a
fact about a URL, and a cancelled request is a fact about the caller — neither shrinks the limit.

### It queues, it does not refuse

`RateLimitPolicy` answers "too many, come back later". This answers "not yet, you are next": callers
that arrive while every slot is busy wait in arrival order. A cancelled caller leaves the queue and
the queue keeps its order; `queueTimeoutSeconds` gives up with `NetworkError.timeoutBudgetExceeded`
for callers that cannot wait forever.

Coalesced callers do not each take a slot. The limiter sits inside the coalescer, so it bounds
requests that reach the transport rather than callers that asked for one.

### Observable

```swift
configuration.telemetryHooks = NetworkTelemetryHooks(
    onConcurrencyLimitChanged: { print("limit \($0.previousLimit) → \($0.limit): \($0.reason)") }
)
let snapshot = await client.concurrencySnapshot()   // limit, in flight, waiting, best latency
```

The hook fires when the limit moves, not per request, so its volume follows the server's capacity
rather than traffic. A limit that moves on its own and cannot be looked at is a limit nobody trusts.

## What was verified

- 26 tests: the clamping of nonsensical bounds, every branch of the increase and decrease rules,
  arrival order, cancellation before and during the wait, the queue timeout, and the signal mapping
  for each error kind.
- Three of them go through the real client with a transport that counts how many requests overlap:
  a limit of 2 never overlaps 3, an unlimited client overlaps more, and six callers asking for one
  URL take one slot between them.
- The full suite: 790 tests.

## Known limitations

- One limiter per client, not per host. A client talking to several hosts pools their capacity
  together, which is wrong if one of them is the slow one.
- The limit is not shared across processes, so an app and its extension each keep their own.
- Retry backoff happens inside the slot: a request waiting to retry still holds capacity.
- No warm start. Every launch begins at `initialLimit` and rediscovers the server's capacity.

## Migration notes

Additive. `NetworkClientConfiguration.adaptiveConcurrency` and
`NetworkTelemetryHooks.onConcurrencyLimitChanged` are new parameters with defaults; existing call
sites compile and behave identically. The API-breakage gate reports no breaking changes.

## Source traceability

- DFR: `docs/dfr/NOVA_NETWORK_V3_2_DFR.md`
- Traceability pack: `docs/TRACEABILITY_PACK_v3.2.md`
