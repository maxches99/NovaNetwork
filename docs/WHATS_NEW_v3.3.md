# What's New in 3.3

## The network is not a yes-or-no question

`OfflineConnectivityMonitor` answers one bit: can we reach anything. That bit is not enough to
decide whether to start a 40 MB upload. A phone on a metered hotspot with Low Data Mode turned on is
connected, and sending it anyway is the wrong answer — the user asked for less data and the client
ignored them.

`NetworkPath` carries what the bit leaves out: the interfaces in use, whether the path costs money
by the byte, and whether the user has asked for less data on it.

```swift
var configuration = NetworkClientConfiguration()
configuration.networkPathMonitor = SystemNetworkPathMonitor()   // reads Network.framework
configuration.networkPathPolicy = .respectMeteredPaths
```

Off by default: with no policy the client never looks at the path, exactly as before.

### Three answers, not two

```swift
NetworkPathPolicy(
    onExpensive: .deferUntilPathImproves,
    onConstrained: .deferUntilPathImproves,
    onUnsatisfied: .deferUntilPathImproves
)
```

`send` goes now. `fail` does not go and is not kept. `deferUntilPathImproves` does not go now but is
kept — and it reaches the offline queue through the machinery that was already there, rather than a
second path beside it: a deferral is reported as the `URLError` the queue already recognises, so
`enqueueWrite` stores it and replays it when the path improves. A failure carries
`NetworkPathRestrictionError` instead, which the queue does not recognise, so it propagates.

### Essential requests still go

```swift
try await client.load(request: signIn, authScope: nil, options: .init(isEssential: true))
```

A policy that also blocked the sign-in would be a policy nobody could adopt. Essential requests pass
a metered or constrained path; a path that cannot carry anything still stops them, and the policy
decides whether that is a deferral or a failure.

### Low Data Mode outranks the cost guess

`isConstrained` is the user saying "use less data here". `isExpensive` is an inference about the
link. When they disagree, the instruction wins.

### Thin at the edge

`SystemNetworkPathMonitor` translates `NWPath` and does nothing else, so everything that decides
anything is testable on a machine that has never had a cellular interface:

```swift
configuration.networkPathMonitor = StaticNetworkPathMonitor(
    NetworkPath(status: .satisfied, interfaces: [.cellular], isExpensive: true)
)
```

`Network.framework` is behind `#if canImport(Network)`, so the Linux build is unaffected.

## What was verified

- 14 tests: every decision the policy can reach, the precedence of constrained over expensive, the
  essential escape hatch, and a path that requires bringing up a connection.
- Through the real client: a ruled-out path stops the request before the transport sees it, an
  allowed path sends normally, an essential request goes out over a metered path, and a client with
  no policy sends over a path that any policy would have rejected.
- The routing test that matters: a deferred write lands in the offline queue, a failed one does not.
- The full suite: 802 tests. The API-breakage gate passes with one allowlisted, source-compatible
  initializer change.

## Known limitations

- The policy is consulted once, when the request starts. A path that degrades mid-request does not
  stop it.
- Deferral only reaches the queue for requests that go through `enqueueWrite`; a plain `load` gets
  an offline error, which is truthful but is not a queue.
- No per-host or per-endpoint policies: one policy for the client.
- Nothing reacts to a path *improving* on its own; the queue's existing replay does that.

## Migration notes

Additive. `NetworkClientConfiguration.networkPathPolicy`, `.networkPathMonitor`, and
`RequestExecutionOptions.isEssential` are new parameters with defaults. The
`RequestExecutionOptions` initializer change is source-compatible and allowlisted, as its
predecessors were.

## Source traceability

- DFR: `docs/dfr/NOVA_NETWORK_V3_3_DFR.md`
- Traceability pack: `docs/TRACEABILITY_PACK_v3.3.md`
