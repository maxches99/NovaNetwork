# Traceability Pack v3.4

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_4_DFR.md`
- Scope: App Group container resolution, the cross-process advisory lock, and the store decorator
  that puts one around the other.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-32, FR-33, EC-27, EC-28 | `Sources/NovaNetworkClient/Networking/OfflineQueue/CrossProcessFileLock.swift` |
| FR-34, EC-30 | `CoordinatedOfflineWriteStore.swift` |
| FR-35, EC-29 | `AppGroupContainer.swift` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-14.1, T-14.2 | FR-32, FR-33 | unit | `CrossProcessFileLockTests` |
| T-14.3 | FR-32 | unit | `CrossProcessFileLockTests` (two descriptors contend) |
| T-14.4, T-14.5 | EC-27, EC-28 | unit | `CrossProcessFileLockTests` |
| T-14.6, T-14.7 | FR-35, EC-29 | unit | `AppGroupContainerTests` |
| T-14.8 | FR-34 | unit | `CoordinatedOfflineWriteStoreTests` |
| T-14.9, T-14.10 | FR-34, EC-30 | unit | `CoordinatedOfflineWriteStoreTests` |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `CrossProcessFileLock.swift` | acquire, contend, time out, release on throw, directory creation |
| `CoordinatedOfflineWriteStore.swift` | every wrapped method through the two-store tests |
| `AppGroupContainer.swift` | the macOS branch and the failure text; the iOS branch is not reachable here |

## Verification gaps

- **No second process.** `flock` is per descriptor, so two locks in one process contend exactly as
  two processes do, and that is what the test asserts. The step from "two descriptors" to "two
  processes" rests on `flock`'s documented semantics, not on an executed test.
- The iOS branch of `AppGroupContainer.url(forAppGroup:)` — the one that returns `nil` without an
  entitlement — cannot run on the test host.
- `nextBatch` releases the lock before the caller replays, so nothing here prevents two processes
  replaying the same entry. That is the replay identity's job and is tested elsewhere.
- The response cache is not shared and nothing tests it as if it were.
