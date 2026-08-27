# What's New in 2.12

## Record and replay

Capture real HTTP traffic once and replay it forever — in tests, in SwiftUI previews, and in an
app's offline demo build.

```swift
import NovaNetworkCassette

try await withCassette(at: fixtureURL, upstream: Transport()) { transport in
    let client = NetworkClient(transport: transport)
    let user: User = try await client.load(request: request, authScope: nil)
    #expect(user.name == "Ada")
}
```

The first run performs the real request and writes a cassette; every run after that is offline and
deterministic. `CassetteTransport` is an ordinary `NetworkTransport`, so coalescing, caching, retry,
middleware, and telemetry above it behave exactly as they do against a live server — a replayed
request is not a special case anywhere in the pipeline.

### Why a recording beats a stub

A hand-written stub says what you believe the server returns. A cassette says what it actually
returned, including the header casing, the null field, and the error envelope nobody remembered.
When the server changes, re-recording shows the difference as a reviewable diff rather than as a
decoding failure in production.

### Three modes

| Mode | Upstream contacted | Use it for |
|---|---|---|
| `.replay` | never | tests and demo builds that must not touch the network |
| `.record` | always | capturing a fresh recording of a scenario |
| `.recordMissing` | only for unrecorded requests | day-to-day work: record once, replay after |

An unmatched request in `.replay` is an error naming the request, never a silent empty response: a
test that quietly passes against a fixture it never matched is worse than one that fails.

### Matching, and why the defaults are what they are

Method plus full URL, with query item order ignored. Headers and bodies can join the rule but are
off by default on purpose — matching a header that carries a nonce, a trace id, or a timestamp makes
every replay fail for a reason that is invisible in the file. `.methodAndPath`, `.includingBody`, and
`.matchingHeaders(_:)` are there when the identity really is different.

Repeated requests replay as episodes: first recording consumed first, then the second, then the
third. Polling and pagination are exactly what people record, and serving the first response forever
would quietly turn a sequence test into a constant. `.repeatLast` covers the steady-state poll.

### Credentials never reach the file

Redaction runs as the exchange is captured, not as the file is written — a redactor that ran at save
time would leave the token sitting in a value some other code could serialize elsewhere.
`Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie`, `X-API-Key`, and `X-Auth-Token` are
replaced by default, and headers, query items, and bodies all take custom redactors. Because headers
are not matched by default, a redacted recording still replays for a request carrying a live token.

### The file

Pretty-printed JSON, sorted keys, UTF-8 bodies stored as text, binary bodies base64, and no
timestamps — so a cassette reads like the payloads it holds and re-saving an unchanged recording
produces identical bytes. Commit it and review it like any other fixture.

## What was verified

- 591 tests pass; 42 of them are new and cover the format, all three modes, every match rule,
  episode ordering, both exhaustion policies, redaction, the scoped helper, concurrent access, and
  every typed error.
- `Sources/NovaNetworkCassette` joins the ≥90% unit coverage gate at 95.47% line coverage.
- The Linux build gate now compiles the new target; it depends on `NovaNetworkCore` alone.
- `Examples/Cassette` records a live request against a public API, asserts the credential did not
  reach the file, and replays through a transport that throws if called — so "offline replay" is
  demonstrated rather than claimed.

## Known limitations

- Only completed HTTP exchanges are recorded. A transport that throws — the network is down — is not
  an exchange: the error propagates and nothing is appended.
- Streaming responses, Server-Sent Events, and managed transfers are not recorded. The transport
  conforms to `NetworkTransport` alone, so the client uses its non-streaming path.
- Cassettes recorded by other libraries are not read, and no migration is provided.
- `withCassette` saves only when its scope returns normally. A scope that threw halfway recorded an
  incomplete scenario, and a half-written cassette that later replays silently is worse than none.

## Migration notes

Additive. New product `NovaNetworkCassette`; no existing API changed shape or behavior, and the API
breaking-changes gate passes with no new allowlist entries. `NovaNetworkClientTestSupport` re-exports
the module, so a test target that already depends on it needs no extra import.

## Source traceability

- DFR: [NovaNetwork 2.12 DFR](dfr/NOVA_NETWORK_V2_12_DFR.md)
- Traceability pack: [v2.12](TRACEABILITY_PACK_v2.12.md)
- Requirement IDs: FR-1…FR-14, UR-1…UR-4, DR-1…DR-3, AR-1, NFR-1…NFR-5, EC-1…EC-8
