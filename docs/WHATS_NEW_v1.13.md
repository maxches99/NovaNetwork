## What's New in v1.13

### Realtime GA (WebSocket)

#### Delivery contract hardening
- Extended outbound backpressure contract with explicit defer telemetry (`message_deferred`) and improved overflow signaling.
- Added bounded ACK resend policy via `WebSocketAckPolicy.maxResendAttempts`.
- Added ACK timeout classes (`fast`, `slow`, `stalled`) and enriched ACK telemetry fields (`ackTimeoutClass`, `ackAttempt`).
- Added duplicate ACK diagnostics (`ack_duplicate`) for transparent dedupe behavior.

#### Reconnect and recovery robustness
- Added reconnect burst guard jitter (`WebSocketReconnectPolicy.burstGuardMaxJitterNanoseconds`) to reduce synchronized reconnect bursts after offline/online recovery.
- Added recoverability classification (`recoverable`, `nonRecoverable`, `manualInterventionRequired`) exposed in runtime diagnostics and telemetry context.

#### Subscription replay 2.0
- Added per-subscription replay retry policy (`WebSocketSubscriptionReplayPolicy`).
- Replay now supports isolated retries for failed subset without breaking whole replay pass.
- Added replay aggregate lifecycle telemetry with correlation id:
  - `subscription_restore_started`
  - `subscription_restore_retry`
  - `subscription_restore_completed`

#### Production diagnostics
- `WebSocketDiagnostics` now includes:
  - queue capacity and pressure level,
  - ACK pending age buckets,
  - reconnect phase and last transition reason,
  - latest recoverability classification.
- Added v1.13 incident triage guide: `docs/REALTIME_INCIDENT_TRIAGE_v1.13.md`.

#### Validation and traceability
- Added/updated WebSocket unit coverage for bounded ACK resend, replay aggregate correlation, and diagnostics snapshot fields.
- Added DFR and v1.13 test-matrix traceability: `docs/dfr/REQUEST_COALESCER_V1_13_DFR.md`.

### Compatibility notes
- Existing WebSocket client callsites remain source-compatible; all new configuration knobs are additive and optional.
