# Offline-First Apps

Whose job it is to remember an edit made with no network — the offline queue's, or your database's —
and how to tell which case you are in.

## Overview

The package ships an offline write queue: ``NetworkClient/enqueueWrite(request:authScope:options:)``
stores a request that could not be sent, and ``NetworkClient/flushOfflineQueue(limit:)`` replays it
when the network returns. Adopters with a local database reasonably ask whether that is the mechanism
for them, and the honest answer is usually no. The two solve different problems, and running both
over the same edit sends it twice.

## One question decides it

**What is the unit of the edit — a request, or a row?**

A request is the unit when nothing local has to change for the user to be satisfied. Recording an
analytics event, uploading a photo, posting a comment that appears optimistically and is otherwise
never touched again: the app has nothing to reconcile, so a durable queue of requests *is* the
feature, and the queue owns it.

A row is the unit when the app already holds the record and the user edits it directly. Renaming a
cocktail in a local database, ticking an ingredient, editing a note: the local value is what the user
sees, it is what the next edit is applied to, and the server is a place it eventually reaches. The
app owns it.

## When the row is the unit, the queue is the wrong shape

Not because it fails, but because it duplicates state that already exists:

- **Two sources of truth.** The row says "dirty" and the queue holds a request for the same edit. A
  crash between them, or a replay that succeeds while the row is edited again, leaves them
  disagreeing, and nothing in the library can adjudicate that — it cannot read your database.
- **Superseding is invisible.** Editing the same name three times offline should send one request.
  The queue sees three unrelated requests; the row sees one field, changed three times. Only the row
  can collapse them, and collapsing them is most of what makes a sync feel fast.
- **Conflicts arrive as HTTP, not as data.** `replayConflictPolicy` decides what to do with a
  terminal failure. Deciding whether the server's version or the local one wins is a merge over your
  own model, and it belongs where the model is.

So: keep the dirty flag on the row, walk the dirty rows when connectivity returns, and call
``NetworkClient/load(request:authScope:cachePolicy:options:)`` normally for each. That is the same
pattern this package's `OfflineQueueExample` shows in miniature — the difference is only where the
"not yet sent" fact is written down.

## What the client still owns in that case

Choosing your own durability does not mean writing the transport concerns again:

- ``RequestExecutionOptions`` carries the ``IdempotencyPolicy`` — a stable key derived from the
  request fingerprint, so a retried write is not a second write.
- ``RetryPolicy`` bounds attempts and honors `Retry-After`; a deadline budget bounds the whole
  operation.
- ``NetworkPathPolicy`` keeps a large sync off cellular or off an expensive path.
- ``OfflineConnectivityMonitor`` is the signal to start walking dirty rows; it is the same one the
  queue uses.
- Coalescing means two screens that both trigger a sync produce one request.
- Telemetry and <doc:Diagnostics> report what actually went out, which is the part a hand-rolled
  sync loop is usually missing when it misbehaves.

## Use both only along a seam

Both mechanisms can coexist in one app as long as no single edit is in both. A drinks app might own
its recipes in a local database and queue photo uploads through the offline queue: different edits,
different units, no shared state. What must not happen is a dirty row *and* a queued request for the
same change.

## Where `QueryClient` fits

<doc:QueryLayer> caches **server state you do not persist** — a feed, a search result, a profile you
are happy to refetch. It is in-memory and keyed by query, and it is above `NetworkClient`, not beside
your database.

If the app already has SwiftData, Core Data, or GRDB holding the same entities, that store is the
cache, and `QueryClient` on top of it would be a second one with its own staleness. Read from your
store, write to your store, and let the sync loop reconcile. `QueryClient` still earns its place for
the screens your store does not cover, and `PagedQuery` for lists you never persist.

## See Also

- <doc:QueryLayer>
- <doc:ProductionChecklist>
- ``OfflineQueuePolicy``
- ``IdempotencyPolicy``
