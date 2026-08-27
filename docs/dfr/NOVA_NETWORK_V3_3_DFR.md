# NovaNetwork 3.3 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.3 — Network path policies
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, Product
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 3.3.0
- Source baseline: 3.1 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.3.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.3.md`

## 2. Goal and Scope

### Goal

Let a client decide what to send from the *kind* of network path it has, not only from whether it
has one.

### User value

`OfflineConnectivityMonitor` answers one bit. A phone on a metered hotspot with Low Data Mode on is
connected, so the bit says yes, and a 40 MB prefetch goes out over the user's cellular allowance
after they explicitly asked for less data. The information to avoid that has been in
`Network.framework` all along; the package never looked at it.

### Scope split

- MVP / required for 3.3:
  - a path description carrying interfaces, expense, and constraint;
  - a policy mapping those to send / defer / fail;
  - an escape hatch for requests that must go regardless;
  - a `Network.framework` adapter, and a static one for tests;
  - deferral routed into the offline queue that already exists.
- Nice-to-have after MVP:
  - re-checking the path mid-request;
  - per-host or per-endpoint policies;
  - a size threshold, so only large requests are held back;
  - reacting to the path improving rather than waiting for the queue's replay.

### Non-goals

- Replacing `OfflineConnectivityMonitor`. It answers the queue's question — are we back — and keeps
  doing that.
- Measuring bandwidth or predicting it.
- A second offline queue. Deferral reaches the existing one or it does not happen.

### Definition of Done

- Every decision the policy can reach is covered by a test.
- The routing of deferral into the queue, and the non-routing of failure, are both asserted.
- The `Network.framework` dependency is behind `canImport`, and the Linux build is unaffected.
- DFR, traceability pack, release notes, README, and CHANGELOG updated together.

## 3. User Value

### User problem

"Do not sync over cellular" is a setting almost every app has, and every app implements it by hand,
usually by reading a reachability flag that does not distinguish a hotspot from home Wi-Fi.

### Success metrics

- With `respectMeteredPaths`, no non-essential request reaches the transport on an expensive or
  constrained path.
- An essential request reaches the transport on the same path.
- A deferred write is in the offline queue afterwards; a failed one is not.

## 4. Rollout, Dependencies, Risks

### Rollout plan

Additive and off by default. A policy requires a monitor; with neither set, nothing changes.

### Dependencies

`Network.framework` on Apple platforms only, behind `#if canImport(Network)`.

### Risks and mitigations

- **Blocking something essential.** Mitigated by `isEssential`, and by tests that assert a sign-in
  goes out on a path everything else is held back from.
- **A second queue.** Mitigated by expressing deferral as an error the existing queue already
  recognises, so there is exactly one queue.
- **An untestable dependency.** Mitigated by keeping the adapter to a translation with no decisions
  in it, and by shipping `StaticNetworkPathMonitor` so a policy can be tested against any path.

## 5. Requirements

### Functional requirements (FR)

- **FR-27** The policy decides from status, expense, and constraint, not only from reachability.
- **FR-28** A request marked essential is not stopped by expense or constraint.
- **FR-29** A deferral is reported so that the existing offline queue stores it; a failure is
  reported so that it does not.
- **FR-30** With no policy configured, the client does not consult the path and behaves as before.
- **FR-31** A system monitor reads `Network.framework`; a static one reports a fixed path.

### Edge cases (EC)

- **EC-23** A path that is expensive *and* constrained follows the constrained rule: the user's
  explicit instruction outranks an inference about cost.
- **EC-24** An essential request on an unusable path is still stopped, and the policy decides
  whether that is a deferral or a failure.
- **EC-25** `requiresConnection` is not usable yet.
- **EC-26** A static monitor's stream finishes rather than hanging its consumer forever.

## 6. State Machine and Flows

`path → policy → {send | deferUntilPathImproves | fail}`, evaluated once, before the rate limiter —
a request ruled out should not consume a rate-limit token either.

`deferUntilPathImproves → NetworkError.transport(URLError) → existing offline queue → replay`.
`fail → NetworkError.transport(NetworkPathRestrictionError) → caller`.

## 7. Engineering Notes

Expressing deferral as an error the queue already recognises is what keeps this from being a second
queue. `URLError.dataNotAllowed` is not a fabrication for the purpose: it is what the system reports
when cellular data is not permitted, which is exactly the situation.

The policy is consulted before the rate limiter and before the circuit breaker, because the cheapest
request is the one that never starts.

## 8. Test Matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-27 | T-13.1…T-13.3, T-13.9 | unit, integration | Engineering |
| FR-28 | T-13.4, T-13.11 | unit, integration | Engineering |
| FR-29 | T-13.12 | integration | Engineering |
| FR-30 | T-13.10 | integration | Engineering |
| FR-31 | T-13.8 | unit | Engineering |
| EC-23…EC-26 | T-13.5…T-13.8 | unit | Engineering |

### Negative tests

- A ruled-out path leaves the transport call count at zero.
- A failed write leaves the queue depth at zero.
- A client with no policy sends over a path every policy would reject.
