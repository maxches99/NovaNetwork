# ``NovaNetworkClient``

Deduplicate concurrent network requests with configurable fingerprinting, cancellation, retry policy, and observability.

## Overview

`NovaNetworkClient` ensures that simultaneous calls for the same logical request share a single underlying operation.

Use ``NetworkClient`` for a batteries-included integration with `URLSession`.

## Topics

### Request Deduplication

- ``RequestCoalescer``
- ``CancellationPolicy``

### Fingerprinting

- ``FingerprintPolicy``
- ``RequestFingerprint``

### Networking

- ``NetworkClient``
- ``CachePolicy``
- ``NetworkClientEvent``
- ``APIRequest``
- ``APIRequestBuilder``
- ``NetworkTransport``
- ``Transport``
- ``NetworkError``

### Resilience

- ``RetryPolicy``

### Observability

- ``RequestCoalescer/Metrics``
- ``RequestCoalescer/Event``
