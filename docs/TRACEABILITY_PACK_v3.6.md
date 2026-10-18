# Traceability Pack v3.6

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V3_6_DFR.md`
- Scope: resuming WebSocket event streams after a reconnect — per-stream cursors, resume
  subscriptions, overlap de-duplication, and gap and resync reporting.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-WS-RESUME-1, FR-WS-RESUME-8, EC-WS-RESUME-1 | `Sources/NovaNetworkClient/Realtime/WebSocketEventResume.swift` |
| FR-WS-RESUME-2, FR-WS-RESUME-4…6, EC-WS-RESUME-2, EC-WS-RESUME-4 | `WebSocketClient.swift` (`trackEventPosition(of:)`) |
| FR-WS-RESUME-3, EC-WS-RESUME-1 | `WebSocketClient.swift` (`resumedEnvelope(for:original:correlationID:)`, `restoreSubscriptions`) |
| FR-WS-RESUME-7, EC-WS-RESUME-3 | `WebSocketClient.swift` (`eventCursor`, `seedEventCursor`, `resetEventCursor`, `unregisterSubscription`, `clearSubscriptions`) |
| AR-WS-RESUME-1…4 | `Sources/NovaNetworkClient/Networking/Core/TelemetryHooks.swift` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-17.1 | FR-WS-RESUME-2, FR-WS-RESUME-3, AR-WS-RESUME-1 | unit | `WebSocketEventResumeTests.aReconnectAsksForTheEventsAfterTheLastOneDelivered` |
| T-17.2 | FR-WS-RESUME-4, AR-WS-RESUME-3 | unit | `WebSocketEventResumeTests.eventsTheAppAlreadyHasAreNotDeliveredAgain` |
| T-17.3 | FR-WS-RESUME-5, AR-WS-RESUME-2 | unit | `WebSocketEventResumeTests.aSkippedSequenceIsDeliveredAndReportedAsAGap` |
| T-17.4 | FR-WS-RESUME-6, AR-WS-RESUME-4 | unit | `WebSocketEventResumeTests.aResyncSignalClearsTheCursorAndStillReachesTheApp` |
| T-17.5 | FR-WS-RESUME-7, EC-WS-RESUME-3 | unit | `WebSocketEventResumeTests.theAppCanSeedResetAndForgetCursors` |
| T-17.6 | FR-WS-RESUME-1, FR-WS-RESUME-8, EC-WS-RESUME-1 | unit | `WebSocketEventResumeTests.theDefaultConventionReadsAndWritesJSON`, `aSubscriptionThePolicyCannotRewriteIsResentUnchanged` |
| T-17.7 | EC-WS-RESUME-2, EC-WS-RESUME-4 | unit | `WebSocketEventResumeTests.unsequencedFramesPassThroughAndTheFirstEventStartsTheCursor` |
| T-17.8 | regression | unit | `WebSocketEventResumeTests.withoutAPolicyTheClientBehavesAsBefore` |

## Analytics verification

- Trigger timing: `event_resume_requested` is emitted inside the subscription restore it belongs to and
  shares its `correlationID` (T-17.1).
- Payload: every event carries the stream in `reason` in the documented shape (T-17.1…T-17.4).
- No false success: a dropped duplicate emits `event_duplicate_dropped` and no `message_received`
  (T-17.2); without a policy none of the four events is emitted (T-17.8).

## E2E

Not applicable (see DFR §8). The existing E2E suite is unaffected.
