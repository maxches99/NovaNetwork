# ``NovaNetworkClient``

Build a typed, concurrency-safe Swift networking layer with shared in-flight work, resilience, and observability.

## Overview

`NovaNetworkClient` ensures that simultaneous calls for the same logical request share a single underlying operation.

Use ``NetworkClient`` for a batteries-included integration with `URLSession`, or import
`NovaNetworkCore` for transport-neutral request, response, endpoint, and error contracts.

If you're new to the package, start with <doc:GettingStarted> or follow the interactive
<doc:Tutorial-Table-of-Contents> tutorial path in Xcode.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:CoreConcepts>
- <doc:ChoosingAnAPI>
- <doc:DeclarativeEndpoints>
- <doc:RecordAndReplay>
- <doc:Diagnostics>
- <doc:Authentication>
- <doc:ProductionChecklist>
- <doc:Tutorial-Table-of-Contents>

### Request Deduplication

- ``RequestCoalescer``
- ``CancellationPolicy``

### Fingerprinting

- ``FingerprintPolicy``
- ``RequestFingerprint``

### Networking

- ``NetworkClient``
- ``NetworkClientConfiguration``
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
- ``EndpointDefinition``
- ``BatchExecutionOptions``
- ``BatchItemResult``
- ``StreamingNetworkTransport``
- ``TransferNetworkTransport``
- ``TransferProgress``
- ``UploadEvent``
- ``DownloadEvent``
- ``DownloadDestinationPolicy``
- ``WebSocketClient``
- ``WebSocketConfiguration``
- ``WebSocketConnectionState``
- ``WebSocketMessage``
- ``WebSocketError``

### Declarative Endpoints

- <doc:DeclarativeEndpoints>
- ``EndpointDefinition``
- ``EndpointRequestBuilder``
- ``EndpointParameterConvertible``
- ``EndpointQueryStyle``
- ``EndpointDefinitionError``
- ``NoContent``

### Server-Sent Events

- ``ServerSentEvent``
- ``SSEParsedElement``
- ``SSELineParser``
- ``SSEDecoder``
- ``ServerSentEventTransport``
- ``ServerSentEventError``
- ``SSEReconnectPolicy``

### Multipart Uploads

- ``MultipartFormDataPart``
- ``MultipartFormDataEncoder``
- ``MultipartFormDataError``

### Certificate Pinning and Mutual TLS (Apple platforms)

- ``CertificatePinningPolicy``
- ``CertificatePinningValidationEvent``
- ``SubjectPublicKeyInfoPin``
- ``ClientCertificateProvider``
- ``ClientCertificateIdentity``
- ``PinningURLSessionDelegate``

### Response Decoding

- ``ResponseDecoding``
- ``JSONResponseDecoding``
- ``ContentTypeNegotiatingResponseDecoding``

### Error Handling

- ``NetworkError``
- ``NetworkErrorContext``
- ``ContextualNetworkError``

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
