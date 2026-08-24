# Choosing an API

Start with the smallest API that matches the shape and lifetime of your operation.

## Overview

### Decision guide

| Need | Start with |
|---|---|
| One raw response body | ``NetworkClient/load(request:authScope:cachePolicy:options:)`` |
| One `Decodable` value | ``NetworkClient/load(request:authScope:cachePolicy:as:decoder:options:)`` |
| Reusable request construction and decoding | `Endpoint` and ``NetworkClient/execute(endpoint:authScope:cachePolicy:decoder:options:)`` |
| Several bounded requests with stable result ordering | ``NetworkClient/loadBatch(requests:authScope:cachePolicy:options:batchOptions:)`` |
| Incremental response bytes | ``NetworkClient/loadStream(request:authScope:cachePolicy:options:)`` |
| Server-Sent Events | ``NetworkClient/loadServerSentEvents(request:authScope:options:reconnectPolicy:)`` |
| WebSocket messages | ``WebSocketClient`` |
| Foreground upload or download progress | ``NetworkClient/upload(request:fromFile:authScope:options:)`` or ``NetworkClient/download(request:to:policy:authScope:options:)`` |
| Durable, resumable transfer | ``ManagedTransferManager`` |
| Transport-neutral models only | Import `NovaNetworkCore` |

### Prefer typed endpoints for repeated operations

An endpoint owns the request and decoder for one server operation. It prevents URL, header, and
model knowledge from spreading across views and feature code while keeping resilience policies in
the shared client.

Use a raw load for a small integration or a genuinely dynamic request. Move to `Endpoint` when
the same operation is called from multiple places, needs custom decoding, or deserves isolated tests.

### Keep the client long-lived

A feature, account session, or application should normally share a client. Recreating a client for
every request prevents callers from sharing in-flight work and discards in-memory cache state.

## See Also

- <doc:ModelRequestsAsEndpoints>
- ``NetworkClientConfiguration``
- ``NetworkClientPreset``
