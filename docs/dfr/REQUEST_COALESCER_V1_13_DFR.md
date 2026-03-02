# DFR: Realtime GA v1.13

## 1. Metadata
- Feature name: Realtime GA (WebSocket)
- Owner: Networking Platform
- Stakeholders: Product, QA, SRE, Backend Realtime
- Status: `In Development`
- Target version/build: `v1.13`
- Related links:
  - Design: this DFR
  - API contract: `Sources/NovaNetworkClient/Realtime/*`
  - Telemetry contract: `Sources/NovaNetworkClient/Networking/TelemetryHooks.swift`

## 2. Goal and Scope
### Goal
Вывести WebSocket-stack на уровень стабильного массового использования: предсказуемая доставка, контролируемый memory profile и операционная диагностика инцидентов.

### Non-goals
- Полноценный offline sync engine с доменными конфликтами.
- Новый realtime протокол (кроме WebSocket).

### Definition of Done
- [x] DFR updated and approved
- [x] Code implemented
- [x] Tests added/updated per matrix
- [x] Telemetry implemented and verified
- [x] "What's New" added/updated
- [x] Rollout plan documented

### MVP / V1 / Nice-to-have
- MVP: стабилизация backpressure/ack/reconnect/replay/diagnostics.
- V1: инцидентные playbooks и более строгие SLA alarms.
- Nice-to-have: adaptive replay budgets per subscription group.

## 3. User Value
### User problem
При деградации сети клиент терял предсказуемость отправки и replay-процессов: не хватало градации ACK timeout, bounded resend и диагностического контекста для triage. Это приводило к трудным расследованиям инцидентов и повышенному риску деградации пользовательского realtime-опыта.

### Success metrics
| Metric | Baseline | Target | Measurement method |
|---|---:|---:|---|
| Reconnect success rate under degraded network | n/a | >= 99% in stress scenarios | reconnect telemetry + stress tests |
| ACK success ratio | n/a | increase vs v1.12; lower timeout frequency | ack telemetry (`ack_timeout`, `ack_resend_attempt`) |
| Memory stability for long sessions | n/a | no unbounded queue/ack-tracker growth | diagnostics + soak tests |

## 4. Rollout, Dependencies, Risks
### Rollout plan
- Feature flag: none (additive API)
- Initial rollout percentage: 100% (library release)
- Segments: all WebSocket adopters
- Ramp plan: v1.13 release notes + runtime telemetry checks in first week
- Rollback trigger: sustained reconnect failure spikes or ACK timeout regression after release

### Dependencies
- Internal: WebSocket client, telemetry hooks, tests
- External: backend ack/replay semantics

### Risks and mitigations
| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Сложность state machine reconnect+ack+replay | High | Medium | explicit reconnect phase + recoverability + scenario tests |
| Избыточный resend увеличит дубли у backend | High | Medium | strict message identity + bounded resend attempts |
| Диагностика станет шумной | Medium | Medium | split event types and correlation id for replay lifecycle |

## 5. Requirements
### Functional requirements (FR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | Harden outbound backpressure contract | Configurable queue depth and overflow strategy with explicit defer/drop telemetry | `WebSocketConfiguration`, `WebSocketClient.queueOutboundEnvelope` |
| FR-2 | ACK lifecycle with bounded resend | ACK timeout classified; resend bounded by policy; timeout on budget exhaustion | `WebSocketAckPolicy`, `WebSocketClient.awaitAckLifecycle` |
| FR-3 | Reconnect robustness under flapping network | No duplicate reconnect loops; controlled reconnect burst after offline->online | reconnect loop + burst guard |
| FR-4 | Subscription replay 2.0 | Partial failures isolated; retry per failed subset; aggregate replay status emitted | `restoreSubscriptions(attempt:)` |

### UX requirements (UR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | Runtime introspection clarity | Diagnostics expose queue pressure, ack age buckets, reconnect phase/reason | `WebSocketDiagnostics` |

### Data requirements (DR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | Stable replay correlation | Replay telemetry includes correlation id across started/retry/completed/success/failed | `TelemetryWebSocketContext.correlationID` |

### Analytics requirements (AR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | Distinguish defer/drop/overflow outcomes | Deferred outbound, dropped overflow, and fail-fast are distinguishable in telemetry | `message_deferred`, `message_dropped`, `message_queued` |
| AR-2 | ACK telemetry contract | `ack_timeout` includes class and attempt; resend attempts emitted | `ack_timeout`, `ack_resend_attempt`, `ack_duplicate` |
| AR-3 | Replay aggregate visibility | replay completed event includes counts and correlation id | `subscription_restore_completed` |

### Non-functional requirements (NFR)
| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | Memory profile remains bounded | queue depth/ack tracked IDs/pending ack structures are bounded or pruned | queue limits + ack dedupe cap |
| NFR-2 | Long-session stability | reconnect/ack/replay stress paths do not leak waiters or unbounded state | stress/race tests |

### Edge cases (EC)
| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Frequent offline/online toggles | single reconnect orchestration survives flaps without bursts | reconnect flap tests |
| EC-2 | ACK duplicated by backend | duplicate ack ignored and diagnosed transparently | `ack_duplicate` event |
| EC-3 | Replay subset fails | failed subset retried independently; aggregate status remains emitted | replay retry + completed events |

## 6. State Machine and Flows
### States
- `disconnected`
- `connecting`
- `connected`
- `unhealthy`
- `reconnectingWaitingForConnectivity`
- `reconnecting`
- `failed`

### Transitions
| From | Trigger | To | Notes |
|---|---|---|---|
| disconnected | `connect()` | connecting | reconnect phase `connecting` |
| connecting | transport connected | connected | phase `connected` |
| connected | receive/ping failure | unhealthy | recoverability classified |
| unhealthy | recoverable failure | reconnecting/reconnectingWaitingForConnectivity | phase `recovering/backoff/waitingForConnectivity` |
| reconnecting | connect success | connected | replay + queue flush + pending ACK resend |
| any | terminal failure | failed | phase `failed`, recoverability set |

### State to UI/Actions/Analytics mapping
| State | UI | Allowed actions | Analytics |
|---|---|---|---|
| connected | realtime active | send/register subscription/force reconnect | `connect_success`, `message_sent` |
| unhealthy | degraded | wait/reconnect/force reconnect | `reconnect_attempt` |
| reconnectingWaitingForConnectivity | offline suppression | none except disconnect | `reconnect_suppressed_offline` |
| reconnecting | recovery backoff | force reconnect/disconnect | `reconnect_attempt`, `reconnect_success` |
| failed | terminal | manual reconnect / re-auth flow | `connect_failed`, `reconnect_exhausted` |

## 7. Engineering Notes
- ACK resend is bounded by `WebSocketAckPolicy.maxResendAttempts` and keeps message identity stable.
- Replay retries are isolated per subscription via `WebSocketSubscriptionReplayPolicy`.
- Reconnect burst desynchronization uses `burstGuardMaxJitterNanoseconds` after offline->online recovery.

## 8. Test Matrix
| Requirement ID | Test ID | Test type (`unit/integration/ui`) | Owner | Status |
|---|---|---|---|---|
| FR-1 | T-1.1 `queuedMessagesDropNewestWhenPolicyConfigured` | unit | Eng | passing |
| FR-1 | T-1.2 `queuedMessagesFlushOnConnectWithDropOldestPolicy` | unit | Eng | passing |
| FR-2 | T-2.1 `sendWithAckTimeoutThrowsTypedErrorAndEmitsTelemetry` | unit | Eng | passing |
| FR-2 | T-2.2 `ackTimeoutUsesBoundedResendAttemptsAndEmitsResendTelemetry` | unit | Eng | passing |
| FR-3 | T-3.1 `connectivityFlapStabilityDoesNotSpawnDuplicateReconnectLoops` | unit | Eng | passing |
| FR-3 | T-3.2 `reconnectIsSuppressedWhileOfflineAndResumesOnOnlineWithTelemetry` | unit | Eng | passing |
| FR-4 | T-4.1 `reconnectSubscriptionRestorePartialFailureEmitsFailureWithoutSuccess` | unit | Eng | passing |
| FR-4 | T-4.2 `subscriptionReplayEmitsRetryAndAggregateCompletionWithCorrelationID` | unit | Eng | passing |
| UR-1 | T-5.1 `diagnosticsExposeQueuePressureAckAgeBucketsAndReconnectPhase` | unit | Eng | passing |
| AR-2 | T-6.1 `ackTimeoutUsesBoundedResendAttemptsAndEmitsResendTelemetry` | unit | Eng | passing |
| AR-3 | T-6.2 `subscriptionReplayEmitsRetryAndAggregateCompletionWithCorrelationID` | unit | Eng | passing |
| NFR-1 | T-7.1 `ackDedupeStoreRemainsBoundedUnderSoak` | unit | Eng | passing |
| NFR-2 | T-7.2 `sendForceReconnectRaceStressDoesNotLeakAckWaitersOrDeadlock` | unit | Eng | passing |

### Negative tests
- ACK timeout after resend budget exhausted.
- Replay partial failure and failed subset tracking.
- Non-recoverable reconnect failures transition to terminal failed state.

### Regression risks
- Existing telemetry consumers expecting only previous event set.
- Reconnect timing behavior shifts due burst guard jitter.

## 9. Release Notes Input ("What's New")
### Customer impact
- Realtime reconnect/ack/replay behavior became more deterministic and diagnosable.

### User-facing changes
- New ACK resend controls and timeout classes.
- Enhanced runtime diagnostics and replay correlation telemetry.

### Behavior changes / migration notes
- Existing callsites remain source-compatible; all additions are optional with defaults.

### Known limitations
- Full offline domain conflict resolution remains out of scope.
