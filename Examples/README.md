# Examples

Runnable examples for `NovaNetworkClient`.

## JSONPlaceholder Coalescing

Uses the public API [https://jsonplaceholder.typicode.com](https://jsonplaceholder.typicode.com) to show:
- typed decoding;
- request coalescing for identical concurrent requests.

Run:

```bash
swift run NovaNetworkClientJSONPlaceholderExample
```

## Batch Loading

Shows `loadBatch` with several JSONPlaceholder endpoints and typed decoding.

Run:

```bash
swift run NovaNetworkClientBatchTodosExample
```

## Middleware

Shows request middleware (`beforeSend`) by injecting custom headers and validating them via [https://httpbin.org/anything](https://httpbin.org/anything).

Run:

```bash
swift run NovaNetworkClientMiddlewareExample
```

## Offline Queue

Shows `enqueueWrite` with durable `DiskOfflineWriteStore` and queue depth inspection.

Run:

```bash
swift run NovaNetworkClientOfflineQueueExample
```
