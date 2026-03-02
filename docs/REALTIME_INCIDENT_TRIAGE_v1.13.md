# Realtime Incident Triage Guide (v1.13)

## 1. Primary signals
- Connection lifecycle: `connect_*`, `reconnect_*`, `disconnect`.
- Backpressure: `message_deferred`, `message_queued`, `message_dropped`.
- ACK lifecycle: `ack_timeout`, `ack_resend_attempt`, `ack_duplicate`.
- Subscription replay: `subscription_restore_started/retry/succeeded/failed/completed`.

## 2. Runtime diagnostics snapshot fields
Use `webSocketDiagnostics()` and inspect:
- `queuePressureLevel` and `queuedOutboundMessages` / `queueCapacity`.
- `ackPendingAgeBuckets` and `pendingAckCount`.
- `reconnectPhase` and `lastTransitionReason`.
- `recoverability` and `lastError`.

## 3. Degradation thresholds
Treat as degraded if one or more conditions hold for sustained windows:
- `queuePressureLevel == high/critical` for > 60s.
- rising `ack_timeout` ratio with frequent `stalled` class.
- repeated `reconnect_attempt` without `reconnect_success`.
- replay runs repeatedly ending with `subscription_restore_completed` reason `partial_failure` or `failed`.

## 4. Triage workflow
1. Validate reconnect phase:
- If `waitingForConnectivity`, confirm network availability transitions.
- If `backoff/recovering`, inspect attempt progression and terminal errors.

2. Validate delivery pressure:
- Compare deferred vs dropped signals.
- Check if queue saturation is policy-driven (`dropOldest/dropNewest/failFast`).

3. Validate ACK health:
- Inspect timeout classes and resend attempt counts.
- Confirm duplicates are not falsely interpreted as success regressions.

4. Validate replay integrity:
- Group replay telemetry by `correlationID`.
- Check aggregate totals/failures in `subscription_restore_completed`.

## 5. Allowed runtime mitigations
- Force reconnect: `forceReconnect(reason:)`.
- Temporarily increase outbound queue depth (`WebSocketOutboundQueuePolicy`) for transient degradation windows.
- Tune ACK resend budget (`WebSocketAckPolicy.maxResendAttempts`) conservatively.
- Tune replay retry budget (`WebSocketSubscriptionReplayPolicy.maxAttemptsPerSubscription`) for unstable sessions.

## 6. Escalation criteria
Escalate to backend/SRE when:
- reconnect remains unsuccessful across max attempts with healthy connectivity,
- ACK stalled class dominates despite bounded resend,
- replay repeatedly fails same subscription IDs across correlation groups.
