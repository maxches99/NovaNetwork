# What's New in 2.0

## Typed networking

- Added the `Endpoint<Response>` contract and `AnyEndpoint<Response>`.
- Added `NetworkClient.execute(endpoint:...)` while preserving the existing raw `APIRequest` APIs.

## Concurrency and batching

- Removed unchecked Sendable conformance from `NetworkClient` and isolated lifetime state.
- Improved waiter cancellation so cancelled callers return without waiting for shared work.
- Rebuilt `loadBatch` as bounded concurrent execution with stable output ordering.
- Added collecting `loadBatchResults` and aggregate batch telemetry.

## Streaming and transfers

- Added incremental 64 KiB response streaming with bounded buffering on supported platforms.
- Added native URLSession upload/download APIs with progress, cancellation, typed destination
  policies, and transfer lifecycle telemetry.

## Authentication

- Added an auth-scope-isolated, single-flight HTTP refresh coordinator.
- Unauthorized requests can be replayed after refreshed headers with a bounded attempt policy.
- Added typed refresh failures and start/success/failure telemetry without credential values.

## Modular core

- Added the standalone `NovaNetworkCore` product for transport-neutral models and protocols.
- `NovaNetworkClient` re-exports core types for source compatibility.

## HTTP Cache 2.0

- Added `Last-Modified` / `If-Modified-Since` revalidation alongside ETag.
- Added corrected freshness age using `Age`, `Date`, and resident time.
- Added request `no-cache` and `no-store`, response `stale-if-error`, and safe `Vary: *` behavior.
- Disk cache metadata remains compatible with entries written before the new validator field.

## Toolchain support

- Swift 6.2 remains the package minimum.
- CI now verifies complete concurrency checking and Swift 6.3 compatibility.

## Verification

- Added real-public-API E2E coverage for typed endpoints, bounded collecting batches,
  incremental streaming, upload, download, auth refresh replay, and ETag revalidation.
- The complete E2E suite contains 31 scenarios and does not use fake transports.

## Migration notes

- New APIs are opt-in; existing request loading remains source compatible.
- Upload/download progress uses native async URLSession delegate APIs on iOS 15, macOS 12,
  watchOS 8, and tvOS 15 or newer. Existing minimum platforms use buffered fallbacks.
- `DownloadDestinationPolicy.failIfExists` is the safe default; replacement must be explicit.
