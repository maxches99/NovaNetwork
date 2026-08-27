# What's New in 3.4

## An app and its extensions, sharing one queue

A share extension is a separate process with its own container. A write queued there is invisible to
the app, and a queue the app flushes is not the queue the extension filled. The only directory both
can see is the App Group container — and the moment they both use it, the actor that protects the
queue stops being enough. An actor serialises what happens inside one process; two processes can
both read "three entries", and both write a fourth over the top of the other's.

3.4 adds the two pieces that were missing and wires them together.

### Finding the shared directory

```swift
let directory = try AppGroupContainer.directory(
    forAppGroup: "group.com.example.app",
    subdirectory: "offline-queue"
)
```

A missing entitlement is the failure that looks exactly like an empty queue, so it is reported as
what it is — and the platforms disagree about where it surfaces, which the documentation now says
outright. iOS returns nothing without the entitlement. macOS hands back a path under
`~/Library/Group Containers` whether or not the process is entitled, so there the mistake is only
found when something tries to write. `directory(forAppGroup:subdirectory:)` is the call that finds
out, because creating the directory is what fails.

### Agreeing across processes

```swift
let lock = CrossProcessFileLock(url: directory.appendingPathComponent(".lock"))
try await lock.withLock { /* read, modify, write */ }
```

`flock` on a lock file, taken **without blocking** and retried on a timer: the blocking form would
park the cooperative thread it runs on and stall every other request in the process while a
different process worked. It is a value type, not an actor, because it holds no mutable state — the
mutual exclusion lives in the filesystem, and an actor would add an isolation boundary that protects
nothing.

Advisory means both sides have to ask. A process that writes the directory without taking the lock
is not stopped by it.

### Putting them together

```swift
configuration.offlineWriteStore = CoordinatedOfflineWriteStore(
    wrapping: DiskOfflineWriteStore(directoryURL: directory),
    lock: lock
)
```

A decorator, not a rewrite. The 625-line store keeps behaving exactly as it did and gains the one
thing it was missing; anything conforming to `OfflineWriteStore` can be wrapped the same way.

Most of `OfflineWriteStore` cannot report a failure — its methods do not throw, because the queue is
meant to degrade rather than break. Losing the lock is therefore reported the way the store already
reports a missing file: by doing nothing and answering with the empty result, rather than by
crashing a share extension.

## What was verified

- 11 tests. The lock is released when the work throws — a lock that survived its own failure would
  deadlock the next caller, which in an extension means a queue that never drains again.
- Real exclusion, without needing two processes: `flock` is per file descriptor, so two locks over
  one path contend inside a single process exactly as two processes do. The contender is refused
  while the holder has it and admitted the moment it does not.
- Two stores over one directory see each other's work, six concurrent enqueues from both sides all
  survive, and a queue dropped from one side is empty from the other.
- The full suite: 813 tests. The API-breakage gate is clean.

## Known limitations

- Only the offline write queue is shared. The response cache is not.
- The lock is advisory and per-directory: a process writing the directory without it is not stopped.
- `nextBatch` takes the lock but does not hold it while the caller replays, so two processes can
  still replay the same entry. Deduplication remains the replay identity's job.
- Nothing here spawns a second process, so the cross-process claim rests on `flock`'s semantics
  rather than on an end-to-end test.

## Migration notes

Additive. Nothing existing changes; a client that does not wrap its store behaves exactly as before.

## Source traceability

- DFR: `docs/dfr/NOVA_NETWORK_V3_4_DFR.md`
- Traceability pack: `docs/TRACEABILITY_PACK_v3.4.md`
