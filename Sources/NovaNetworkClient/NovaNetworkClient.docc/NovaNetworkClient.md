# ``NovaNetworkClient``

Deduplicate concurrent network requests with configurable fingerprinting, cancellation, retry policy, and observability.

## Overview

`NovaNetworkClient` ensures that simultaneous calls for the same logical request share a single underlying operation.

Use ``NetworkClient`` for a batteries-included integration with `URLSession`, or import
`NovaNetworkCore` for transport-neutral request, response, endpoint, and error contracts.

## Topics

### Request Deduplication

- ``RequestCoalescer``
- ``CancellationPolicy``

### Fingerprinting

- ``FingerprintPolicy``
- ``RequestFingerprint``

### Networking

- ``NetworkClient``
- ``NetworkClientPreset``
- ``NetworkClientPresetOverlayKind``
- ``NetworkClientProductionProfileGenerator``
- ``CachePolicy``
- ``NetworkClientEvent``
- ``APIRequest``
- ``APIRequestBuilder``
- ``NetworkTransport``
- ``Transport``
- ``Endpoint``
- ``AnyEndpoint``
- ``BatchExecutionOptions``
- ``BatchItemResult``
- ``StreamingNetworkTransport``
- ``TransferNetworkTransport``
- ``TransferProgress``
- ``UploadEvent``
- ``DownloadEvent``
- ``DownloadDestinationPolicy``
- ``NetworkError``
- ``WebSocketClient``
- ``WebSocketConfiguration``
- ``WebSocketConnectionState``
- ``WebSocketMessage``
- ``WebSocketError``

### Resilience

- ``RetryPolicy``
- ``HTTPAuthRefreshProvider``
- ``HTTPAuthRefreshPolicy``

### Caching

- ``CachePolicy``
- ``ResponseCache``
- ``CachedResponse``
- ``MemoryResponseCache``
- ``DiskResponseCache``

### Observability

- ``RequestCoalescer/Metrics``
- ``RequestCoalescer/Event``
- ``NetworkTelemetryHooks``
- ``TelemetryContractVersion``
- ``OpenTelemetryAdapter``
- ``OpenTelemetryExporting``
- ``TelemetryBatchContext``
- ``TelemetryTransferContext``
- ``TelemetryHTTPAuthRefreshContext``
