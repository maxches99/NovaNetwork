# What's New in 3.6

## A WebSocket reconnect no longer loses what happened while it was down

`WebSocketClient` has reconnected and re-sent registered subscriptions since 1.x. But a re-sent
subscribe starts from "now": every event the server published while the socket was down — a lift, a
tunnel, a backgrounded app — was gone, and nothing said so. The screen looked live and was missing
whatever happened during the drop. The server-sent-events path has resumed with `Last-Event-ID` for a
long time; the WebSocket path had no equivalent.

From 3.6, pass an `eventResume` policy:

```swift
let socket = WebSocketClient(
    configuration: .init(url: URL(string: "wss://example.com/ws")!),
    eventResume: .default
)
await socket.registerSubscription(id: "orders", message: .text(#"{"type":"subscribe","channel":"orders"}"#))
```

The client then:

- records the last sequence it delivered for each stream;
- after a reconnect, re-sends each registered subscription asking for the events after it
  (`{"afterSeq":42,"channel":"orders","type":"subscribe"}` under `.default`);
- drops events at or below the cursor, so the overlap a resume produces never reaches `messages()`;
- reports what it cannot recover on `eventResumeEvents()`:
  - `.gapDetected` — a sequence skipped ahead; the event is delivered and the cursor moves on;
  - `.resyncRequired` — the server can no longer replay that far back; the cursor is cleared.

Both are the app's cue to refetch a snapshot over HTTP and seed the cursor from it with
`seedEventCursor(_:forStream:)`.

### The convention, and leaving it

`.default` reads `{"stream": "<id>", "seq": <n>}`, resumes a JSON-object subscription by adding
`"afterSeq"`, and recognises `{"type": "resync_required", "stream": "<id>"}`. A subscription that is not
a JSON object is re-sent unchanged. Any other protocol is
`WebSocketEventResumePolicy(position:resumeMessage:resyncSignal:)`.

The stream ID must be the subscription ID: that is the subscription the client re-sends with the
cursor. The `position` closure is where an app maps one name to the other.

### Across a relaunch

Cursors live in the client. Read one with `eventCursor(forStream:)`, persist it with the rest of your
state, and hand it back with `seedEventCursor(_:forStream:)` after the next launch.
`resetEventCursor(forStream:)` forgets one, for a server that resets its numbering in a way the resync
signal does not cover.

### Telemetry

Four new `TelemetryWebSocketEventType` cases, each with the stream in `reason`:

| Event | `reason` |
|---|---|
| `event_resume_requested` | `<stream>:<afterSeq>`, with the restore `correlationID` |
| `event_gap_detected` | `<stream>:<expected>-<received>` |
| `event_duplicate_dropped` | `<stream>:<seq>` — and no `message_received` for that frame |
| `event_resync_required` | `<stream>` |

## Migration

None. The policy is opt-in through a new initializer; without it the client behaves exactly as in
3.5. An exhaustive `switch` over `TelemetryWebSocketEventType` needs the four new cases.
