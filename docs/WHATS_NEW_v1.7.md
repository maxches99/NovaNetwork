## What's New in v1.7

- Added offline queue support for write requests (`POST`/`PUT`/`PATCH`) via `enqueueWrite(...)`.
- Added durable offline write storage with `DiskOfflineWriteStore` and schema-aware persistence.
- Added replay APIs for queued writes:
  - `flushOfflineQueue(limit:)`
  - automatic replay trigger when `OfflineConnectivityMonitor` reports online.
- Added queue management APIs:
  - `offlineQueueDepth()`
  - `offlineQueueSnapshot()`
  - `dropQueuedWrite(queueID:)`
  - `dropAllQueuedWrites()`
- Added offline queue lifecycle event stream:
  - `offlineQueueEvents()`.
- Added offline queue telemetry contract:
  - `TelemetryOfflineQueueContext`
  - `onOfflineQueueEvent` hook in `NetworkTelemetryHooks`.
- Added comprehensive test coverage for offline store behavior, enqueue/replay flows, queue management APIs, and telemetry correctness.
