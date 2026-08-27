# Traceability Pack v3.3

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_3_DFR.md`
- Scope: the network path description, the policy that decides from it, the `Network.framework`
  adapter, and the routing of deferral into the existing offline queue.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-27, EC-23, EC-24 | `Sources/NovaNetworkClient/Networking/Policies/NetworkPathPolicy.swift` |
| FR-28 | `NetworkPathPolicy.decision(for:isEssential:)`, `RequestExecutionOptions.isEssential` |
| FR-29 | `NetworkClient+NetworkPath.swift`, reusing `NetworkClient.isOfflineError` |
| FR-30 | `NetworkClientConfiguration.networkPathPolicy` defaulting to `nil` |
| FR-31 | `SystemNetworkPathMonitor`, behind `#if canImport(Network)` |
| EC-25, EC-26 | `StaticNetworkPathMonitor`, `NetworkPath.isUsable` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-13.1…T-13.3 | FR-27, EC-23 | unit | `NetworkPathPolicyDecisionTests` |
| T-13.4, T-13.5 | FR-28, EC-24 | unit | `NetworkPathPolicyDecisionTests` |
| T-13.6, T-13.7 | EC-25, EC-26 | unit | `NetworkPathPolicyDecisionTests` |
| T-13.8 | FR-31 | unit | `StaticNetworkPathMonitorTests` |
| T-13.9…T-13.11 | FR-27, FR-28, FR-30 | integration | `NetworkPathClientTests` |
| T-13.12 | FR-29 | integration | `NetworkPathClientTests` |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `NetworkPathPolicy.swift` | every decision branch and both precedence orders |
| `NetworkClient+NetworkPath.swift` | send, defer, fail, and the unconfigured path |
| `SystemNetworkPathMonitor.swift` | `StaticNetworkPathMonitor` covered; the `NWPath` translation is not |

## Verification gaps

- `SystemNetworkPathMonitor.translate(_:)` is not tested. An `NWPath` cannot be constructed, and the
  machine running the tests has no cellular interface to produce one. This is why the type is thin:
  it translates and decides nothing, and everything that decides is covered.
- The policy is consulted once at request start; nothing tests a path that changes mid-request,
  because nothing implements that.
- Deferral is tested through `enqueueWrite`. A plain `load` on a deferred path is asserted to fail,
  not to queue, because it does not queue.
