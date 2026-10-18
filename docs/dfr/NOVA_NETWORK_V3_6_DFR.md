# NovaNetwork 3.6 DFR

## 1. Metadata

- Feature name: NovaNetwork 3.6 — Resuming a WebSocket event stream after a reconnect
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering
- Status: `Implementation complete; pre-release CI gates pending`
- Target version: 3.6.0
- Source baseline: 3.5 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v3.6.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v3.6.md`

## 2. Goal and Scope

### Goal

After a reconnect, ask the server for the events the client missed while it was away, drop the ones
it already has, and say so when the server can no longer fill the gap.

### User value

`WebSocketClient` already reconnects and re-sends registered subscriptions, but a re-sent subscribe
starts from "now". Every event published while the socket was down — a lift, a tunnel, a backgrounded
app — is lost, and nothing tells the app. The server-sent-events path has had `Last-Event-ID` since
2.x; the WebSocket path had no equivalent.

### Scope split

- MVP / required for 3.6:
  - read a stream and sequence number from inbound events, through a closure the app can replace;
  - keep the last sequence per stream and send it with the re-sent subscription after a reconnect;
  - drop inbound events at or below the last sequence (the overlap a resume produces);
  - report a gap, and a server's "history no longer reaches back", as events the app can act on;
  - a default JSON convention, so a backend that follows it needs no closures.
- Nice-to-have after MVP:
  - persisting cursors inside the client across launches (the app can read and seed them today);
  - resuming automatically when a gap is seen on a live connection.

### Non-goals

- Defining a server protocol. The default is one convention; any other is three closures.
- Buffering or reordering out-of-order events. WebSocket runs over one ordered connection; a gap on a
  live connection is the server's, and is reported rather than hidden.
- Changing what happens on the first `connect()`. Subscriptions are still only re-sent on reconnect.

### Definition of Done

- A reconnect re-sends each registered subscription carrying its stream's last sequence, asserted on
  the wire.
- An event at or below the last sequence never reaches `messages()`, asserted.
- A gap and a resync signal each surface once on `eventResumeEvents()` and in telemetry, asserted.
- Without a resume policy the client behaves exactly as in 3.5, asserted.
- DFR, traceability pack, release notes, README, and CHANGELOG updated together.

## 3. User Value

### User problem

A chat, an order book, or a delivery tracker that reconnects silently is worse than one that shows
an error: the screen looks live and is missing whatever happened during the drop. The fix is a
protocol detail — "send me everything after 41" — that every app re-implements around the client,
usually without the de-duplication of the overlap.

### Success metrics

- A backend that tags events with `stream` and `seq` gets resume, de-duplication, and gap reporting
  by passing `.default`.
- No duplicate event reaches the app after a resume.
- Every lost range that the client can observe is reported, never swallowed.

## 4. Rollout, Dependencies, Risks

### Rollout plan

Additive and opt-in: a new `WebSocketClient` initializer takes the policy. The existing initializers
are unchanged and behave as before.

### Dependencies

None beyond Foundation.

### Risks and mitigations

- **Stream ID and subscription ID drift apart.** Resume keys the cursor by the subscription ID; a
  backend whose stream names differ would never resume. Mitigated by documenting the rule on the
  type and in the README, and by the `position` closure, which is where the app maps one to the other.
- **A sequence reset on the server (new deployment, compacted log).** Every later event would be
  dropped as a duplicate. Mitigated by the resync signal, which clears the cursor, and by
  `resetEventCursor(forStream:)` for backends that announce a reset differently.
- **Telemetry enum gains cases.** A source break for an exhaustive `switch` over
  `TelemetryWebSocketEventType`. Judged acceptable, as for every telemetry addition since 1.13;
  listed in the API-breakage allowlist.

## 5. Requirements

### Functional requirements (FR)

- **FR-WS-RESUME-1** `WebSocketEventResumePolicy` reads an inbound message's stream and sequence,
  builds a resume subscription from the original subscription and a sequence, and recognises a
  server's resync signal; each is a replaceable closure.
- **FR-WS-RESUME-2** The client records the highest sequence seen per stream.
- **FR-WS-RESUME-3** On reconnect, a registered subscription whose ID has a recorded sequence is
  re-sent as the policy's resume message; one without a sequence is re-sent unchanged.
- **FR-WS-RESUME-4** An inbound event whose sequence is at or below the recorded one is not delivered
  to `messages()`.
- **FR-WS-RESUME-5** An event whose sequence skips past the next expected one is delivered, advances
  the cursor, and is reported as a gap with the expected and received sequence.
- **FR-WS-RESUME-6** A resync signal clears the stream's cursor, is reported, and is still delivered
  to `messages()`.
- **FR-WS-RESUME-7** The app can read, seed, and reset a stream's cursor, so it can persist one
  across launches.
- **FR-WS-RESUME-8** `.default` reads `{"stream": String, "seq": Int}`, resumes by adding
  `"afterSeq"` to a JSON-object subscription, and recognises `{"type": "resync_required", "stream": String}`.

### Edge cases (EC)

- **EC-WS-RESUME-1** A resume closure that returns `nil` (for example a non-JSON subscription under
  `.default`) re-sends the original subscription.
- **EC-WS-RESUME-2** Messages the policy does not recognise — acks, pongs, application frames — pass
  through untouched and do not move any cursor.
- **EC-WS-RESUME-3** Unregistering a subscription forgets its cursor; clearing subscriptions forgets
  all of them.
- **EC-WS-RESUME-4** The first event of a stream with no cursor is delivered and starts the cursor,
  whatever its sequence.

### Analytics (AR)

- **AR-WS-RESUME-1** `event_resume_requested` per resumed subscription, with `reason`
  `"<stream>:<afterSeq>"` and the restore `correlationID`.
- **AR-WS-RESUME-2** `event_gap_detected` with `reason` `"<stream>:<expected>-<received>"`.
- **AR-WS-RESUME-3** `event_duplicate_dropped` with `reason` `"<stream>:<seq>"`; no
  `message_received` for that frame.
- **AR-WS-RESUME-4** `event_resync_required` with `reason` `"<stream>"`.

## 6. State Machine and Flows

Per stream: `no cursor → tracking(n)`. In `tracking(n)`:

| Inbound | Delivered | Next state | Report |
|---|---|---|---|
| `seq ≤ n` | no | `tracking(n)` | duplicate dropped |
| `seq = n + 1` | yes | `tracking(seq)` | — |
| `seq > n + 1` | yes | `tracking(seq)` | gap `(n+1, seq)` |
| resync signal | yes | `no cursor` | resync required |

`unregisterSubscription` / `clearSubscriptions` / `resetEventCursor` → `no cursor`.
Reconnect → for each registered subscription: `tracking(n)` sends `resumeMessage(original, n)`;
`no cursor` sends the original.

State → UI → action mapping for the app: *resync required* → refetch a snapshot over HTTP and seed the
cursor from it; *gap* → same, or show a "may be incomplete" marker.

## 7. Engineering Notes

The policy is an initializer argument rather than a `WebSocketConfiguration` field because it holds
closures and the configuration is `Equatable`; `ackMatcher` is passed the same way for the same reason.

A new initializer rather than a defaulted parameter on the existing ones keeps the 3.5 initializers
and their API-digester signatures intact.

The cursor is keyed by subscription ID because that is the only name the client and the app share for
"the thing to re-send". The `position` closure is where an app whose server says `"orders.v2"` for
subscription `"orders"` maps one to the other.

A gap on a live connection does not trigger a resume: the server produced it on an ordered
connection, and re-subscribing to a server that drops events would loop. It is reported instead.

## 8. Test Matrix

| Requirement ID | Test IDs | Type | Owner |
|---|---|---|---|
| FR-WS-RESUME-2, FR-WS-RESUME-3, AR-WS-RESUME-1 | T-17.1 | unit | Engineering |
| FR-WS-RESUME-4, AR-WS-RESUME-3 | T-17.2 | unit | Engineering |
| FR-WS-RESUME-5, AR-WS-RESUME-2 | T-17.3 | unit | Engineering |
| FR-WS-RESUME-6, AR-WS-RESUME-4 | T-17.4 | unit | Engineering |
| FR-WS-RESUME-7, EC-WS-RESUME-3 | T-17.5 | unit | Engineering |
| FR-WS-RESUME-1, FR-WS-RESUME-8, EC-WS-RESUME-1 | T-17.6 | unit | Engineering |
| EC-WS-RESUME-2, EC-WS-RESUME-4 | T-17.7 | unit | Engineering |
| Regression (no policy) | T-17.8 | unit | Engineering |

### Negative tests

- Without a policy, an event with a repeated `seq` is still delivered and a reconnect re-sends the
  original subscription (T-17.8).
- A non-JSON subscription is re-sent unchanged under `.default` (T-17.6).

### E2E

Not applicable: no public WebSocket echo service implements a resumable event log, and the E2E policy
forbids a fake one. The existing E2E suite must stay green.
