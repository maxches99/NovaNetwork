# NovaNetwork 3.4 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.4 — Sharing the offline queue across processes
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-27
- Target version: 3.4.0
- Source baseline: 3.3 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.4.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.4.md`

## 2. Goal and Scope

### Goal

Let an app and its extensions use one offline write queue without corrupting it.

### User value

A share extension is a separate process with its own container. A write queued there is invisible to
the app. Pointing both at an App Group container fixes the visibility and creates a worse problem:
the actor that protects the queue only serialises one process, so two can both read "three entries"
and both write a fourth over the other's.

### Scope split

- MVP / required for 3.4:
  - resolving the App Group container, and saying clearly when it cannot be resolved;
  - a cross-process advisory lock that never blocks a cooperative thread;
  - a store decorator that takes the lock around every operation.
- Nice-to-have after MVP:
  - sharing the response cache the same way;
  - holding the lock across a replay so two processes cannot replay one entry;
  - a shared, cross-process view of in-flight requests;
  - Darwin file coordination for iCloud-backed containers.

### Non-goals

- Rewriting `DiskOfflineWriteStore`. It behaves correctly within a process and keeps doing so.
- A distributed lock. This is one device, several processes.
- Making the lock mandatory. A client that does not want sharing pays nothing.

### Definition of Done

- Exclusion is asserted by a test that observes a contender being refused, not by inspection.
- The lock is released when the work throws, asserted.
- Two stores over one directory are shown to see each other's writes.
- DFR, traceability pack, release notes, README, and CHANGELOG updated together.

## 3. User Value

### User problem

"Share a photo from Photos, and have the app upload it" is a routine feature, and today it needs the
adopter to write cross-process coordination themselves — which almost nobody does correctly on the
first attempt.

### Success metrics

- A write queued by one store is visible to another store over the same directory.
- Six concurrent enqueues from two stores produce six entries, not fewer.
- A contended lock refuses the second caller and admits it as soon as the first is done.

## 4. Rollout, Dependencies, Risks

### Rollout plan

Additive and opt-in. Nothing changes for a client that does not wrap its store.

### Dependencies

`flock` from Darwin or Glibc. `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` on
Apple platforms.

### Risks and mitigations

- **A lock that is never released.** Mitigated by `defer` around the work and a test that throws
  from inside the critical section and then checks the lock is free.
- **Blocking a cooperative thread.** Mitigated by taking the lock with `LOCK_NB` and retrying on a
  timer rather than using the blocking form.
- **A silent failure that looks like an empty queue.** Mitigated by naming the entitlement in the
  error text, and by documenting that macOS does not report the missing entitlement at all.
- **A false sense of safety.** The lock is advisory and does not cover the replay window. Both are
  stated in the release notes rather than left to be discovered.

## 5. Requirements

### Functional requirements (FR)

- **FR-32** Two holders of the same lock path are mutually exclusive; the second waits and then
  times out rather than proceeding.
- **FR-33** The lock is released however the work ends, including by throwing.
- **FR-34** A wrapped store behaves exactly as the store it wraps, and two wrapped stores over one
  directory see each other's writes.
- **FR-35** App Group resolution reports a missing entitlement as such, naming what to check.

### Edge cases (EC)

- **EC-27** The lock file's directory does not exist yet: it is created.
- **EC-28** A negative timeout or a zero poll interval is clamped rather than trusted.
- **EC-29** macOS returns a container path for an unentitled identifier; the documentation says so
  and a test pins it down.
- **EC-30** The lock cannot be taken and the protocol method cannot throw: the operation does
  nothing and answers with the empty result, rather than crashing an extension.

## 6. State Machine and Flows

`free → held → free`, with `held → contended → timed out` for a second caller.

Store call → take lock → delegate → release lock → return. On failure to take the lock: return the
empty result for the reading methods, do nothing for the writing ones, throw only where the protocol
allows it.

## 7. Engineering Notes

`CrossProcessFileLock` is a value type. It has no mutable state — the mutual exclusion lives in the
filesystem — so making it an actor would add an isolation boundary for the work closure to cross and
protect nothing. The closure parameters are `sending` because the callers are actor-isolated.

The decorator exists because the alternative was threading a lock through twenty call sites in a
625-line actor, which is more code, more risk, and works for exactly one store.

## 8. Test Matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-32 | T-14.1, T-14.3 | unit | Engineering |
| FR-33 | T-14.2 | unit | Engineering |
| FR-34 | T-14.8, T-14.9, T-14.10 | unit | Engineering |
| FR-35 | T-14.6, T-14.7 | unit | Engineering |
| EC-27, EC-28 | T-14.4, T-14.5 | unit | Engineering |

### Negative tests

- A contender is refused while the holder has the lock.
- The lock is free after the work throws.
- Six concurrent enqueues do not lose entries.
