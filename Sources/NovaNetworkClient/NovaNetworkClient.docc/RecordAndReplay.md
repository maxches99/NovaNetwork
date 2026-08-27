# Record and Replay

Capture real traffic once, then replay it forever — in tests, in previews, and in an offline demo
build.

## Overview

A hand-written stub says what you *believe* the server returns. A cassette says what it *actually*
returned: the header casing, the null field, the error envelope nobody remembered. It is a fixture
with the fidelity of the real exchange and the determinism of a file — and when the server changes,
re-recording shows the difference as a diff instead of as a decoding failure in production.

`CassetteTransport` is an ordinary `NetworkTransport`, so everything above it — coalescing,
caching, retry, middleware, telemetry — behaves exactly as it does against a live server.

```swift
import NovaNetworkCassette

try await withCassette(at: fixtureURL, upstream: Transport()) { transport in
    let client = NetworkClient(transport: transport)
    let user: User = try await client.load(request: request, authScope: nil)
    #expect(user.name == "Ada")
}
```

The first run performs the real request and writes the cassette. Every run after that is offline and
deterministic, because `recordMissing` replays what the file already holds.

## Three modes

| Mode | Upstream contacted | Use it for |
|---|---|---|
| `replay` | never | tests and demo builds that must not touch the network |
| `record` | always | capturing a fresh recording of a scenario |
| `recordMissing` | only for unrecorded requests | day-to-day work: record once, replay after |

In `replay`, a request with no recording is an error naming the request — never a
silent empty response. That is the whole point: a test that quietly passes against a fixture it
never matched is worse than one that fails.

## What gets matched

By default a recording answers a request when the **method and full URL** agree. Query item order
does not matter. Headers and bodies are available but off by default, on purpose: matching a header
that carries a nonce, a trace id, or a timestamp makes every replay fail for a reason that is
invisible in the file.

```swift
// A cache-busting query parameter you do not want to match on:
CassetteMatchRule.methodAndPath

// An endpoint that varies its response by request payload:
CassetteMatchRule.includingBody

// A content-negotiated API where the language really is part of the identity:
CassetteMatchRule.default.matchingHeaders("Accept-Language")
```

Repeated requests replay as **episodes**: the first recording is consumed first, then the second,
then the third. Polling and pagination are exactly what people record, and serving the first
response forever would quietly turn a sequence test into a constant. When the recordings run out,
`error` says so; `repeatLast` keeps serving the final
one for a steady-state poll.

## Credentials never reach the file

Redaction runs as the exchange is captured, not as the file is written — a redactor that ran at save
time would leave the token sitting in a value some other code could serialize elsewhere.

`default` replaces `Authorization`, `Proxy-Authorization`, `Cookie`,
`Set-Cookie`, `X-API-Key`, and `X-Auth-Token`. That is a floor, not a promise that your API keeps its
secrets where everyone else does:

```swift
let redaction = CassetteRedaction.default
    .redacting(headers: "X-Tenant-Signature")
    .redacting(queryItems: "api_key")
    .redactingBodies { data in
        // Strip the token out of a login response before it is stored.
        Data(String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: liveToken, with: "<token>").utf8)
    }
```

Because headers are not matched by default, a cassette recorded with a redacted `Authorization`
header still replays for a request carrying a different live token.

## The file

The format is pretty-printed JSON with sorted keys, UTF-8 bodies stored as text, and no timestamps —
so it reads like the payloads it holds, and re-saving an unchanged recording produces identical
bytes. Commit it and review it like any other fixture.

```json
{
  "interactions" : [
    {
      "request" : {
        "headers" : { "Accept" : "application/json" },
        "method" : "GET",
        "url" : "https://api.example.com/users/1"
      },
      "response" : {
        "body" : { "text" : "{\"id\":1,\"name\":\"Ada\"}" },
        "headers" : { "Content-Type" : "application/json" },
        "status" : 200
      }
    }
  ],
  "version" : 1
}
```

Binary bodies are stored base64 and replay byte-identically.

## Beyond tests

`NovaNetworkCassette` is its own product and depends only on `NovaNetworkCore`, so a preview or a
demo build can link it without pulling in a test-support module:

```swift
#Preview {
    ProfileView(client: NetworkClient(transport: CassetteTransport(
        mode: .replay,
        cassette: try! Cassette.load(from: Bundle.main.url(forResource: "profile", withExtension: "json")!)
    )))
}
```

## Limitations

- Only completed HTTP exchanges are recorded. A transport that *throws* — the network is down — is
  not an exchange; the error propagates and nothing is appended.
- Streaming responses, Server-Sent Events, and managed transfers are not recorded. The transport
  conforms to `NetworkTransport` alone, so the client uses its non-streaming path.
- Cassettes recorded by other libraries are not read.

## The symbols

`CassetteTransport` and `withCassette(at:…)` do the work; `CassetteMode` and `CassetteRepeatPolicy`
say how. `Cassette`, `RecordedInteraction`, `RecordedRequest`, `RecordedResponse`, and `RecordedBody`
are the recording itself. `CassetteMatchRule`, `CassetteURLMatching`, and `CassetteRedaction`
configure matching and redaction, and every failure is a `CassetteError`.

They live in the `NovaNetworkCassette` module. `import NovaNetworkClientTestSupport` re-exports it,
so a test target that already depends on the test-support module needs no extra import.

## See Also

- <doc:ChoosingAnAPI>
