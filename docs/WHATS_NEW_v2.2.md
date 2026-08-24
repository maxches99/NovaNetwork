# What's New in 2.2

## Server-Sent Events

- Added `NetworkClient.loadServerSentEvents(request:authScope:options:reconnectPolicy:)`, an
  `AsyncThrowingStream<ServerSentEvent, Error>` for `text/event-stream` endpoints.
- Added a spec-compliant, platform-independent SSE wire-format parser in `NovaNetworkCore`
  (`SSELineParser`, `SSEDecoder`, `ServerSentEvent`, `SSEParsedElement`): CR/LF/CRLF line endings,
  multi-line `data:` joining, comment lines, leading BOM stripping, and `retry:` handling. It has
  no platform dependencies, so it is usable standalone on every supported platform, including
  Linux, independent of the URLSession-backed transport.
- Added `ServerSentEventTransport`, implemented by the default `Transport` using
  `URLSession.bytes(for:)` where available, with a single-response fallback on older OS versions
  matching `StreamingNetworkTransport`'s existing fallback behavior.
- Added automatic reconnection: `Last-Event-ID` is resent once the server has provided one, and a
  server-sent `retry:` field updates the reconnect delay for subsequent attempts. Added
  `SSEReconnectPolicy` (`isEnabled`, `maxAttempts`, `defaultDelayNanoseconds`,
  `maxDelayNanoseconds`); pass `.disabled` for a single-attempt stream.
- Reconnect and cancellation are integration-tested against a scripted transport, including a
  fix for a busy-loop: the reconnect loop was only checking for task cancellation inside the
  per-attempt event loop, so an attempt that reconnected without ever yielding an event (a clean
  empty stream, or an immediate transport error) would not observe cancellation. Cancellation is
  now checked at the top of every reconnect cycle.
- Reuses the existing `.stream` telemetry transfer kind (`started`/`progress`/`completed`/
  `failed`/`cancelled`) rather than extending the Observability Contract v2 payload; no telemetry
  contract version change is required.

## Migration notes

- Additive only; no existing public API changed.
- SSE support requires a transport conforming to `ServerSentEventTransport`. A transport that
  does not implement it fails `loadServerSentEvents` immediately with
  `NetworkError.transport(underlying: ServerSentEventError.transportUnsupported)`.
