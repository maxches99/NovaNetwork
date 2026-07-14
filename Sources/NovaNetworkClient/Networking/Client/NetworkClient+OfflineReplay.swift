import NovaNetworkCore
import Foundation

extension NetworkClient {
    func effectiveSchedulerPolicy(from entries: [OfflineWriteStoreEntry]) -> OfflineReplaySchedulerPolicy {
        entries.first?.replayMetadata.schedulerPolicy ?? .init()
    }

    func percentile(ages: [TimeInterval], p: Double) -> TimeInterval {
        guard !ages.isEmpty else { return 0 }
        let clipped = min(1, max(0, p))
        let index = Int((Double(ages.count - 1) * clipped).rounded())
        return ages[index]
    }

    func replayOfflineEntry(_ entry: OfflineWriteStoreEntry, store: any OfflineWriteStore) async {
        if await store.hasReplayTerminalSuccess(
            replayIdentity: entry.replayMetadata.replayIdentity,
            within: entry.replayMetadata.dedupeWindowSeconds,
            now: Date()
        ) {
            await store.markSucceeded(queueID: entry.receipt.queueID)
            await emitOfflineQueueEvent(
                .replaySuppressed(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    replayIdentity: entry.replayMetadata.replayIdentity,
                    reason: "dedupe_success_window"
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replaySuppressed,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: entry.attempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: "dedupe_success_window",
                    willRetry: false,
                    resultType: "dedupe_suppressed",
                    priority: entry.replayMetadata.priority
                )
            )
            await offlineReplayCoordinator.markOutcome(.dedupeSuppressed)
            return
        }

        let nextAttempt = max(1, entry.attempt + 1)
        await store.markReplaying(queueID: entry.receipt.queueID, attempt: nextAttempt, now: Date())
        await offlineReplayCoordinator.markReplay()
        await emitOfflineQueueEvent(
            .replayStarted(queueID: entry.receipt.queueID, requestKey: entry.receipt.requestKey, attempt: nextAttempt),
            telemetry: telemetryOfflineQueueContext(
                type: .replayStarted,
                queueID: entry.receipt.queueID,
                requestKey: entry.receipt.requestKey,
                attempt: nextAttempt,
                enqueuedAt: entry.receipt.enqueuedAt,
                resultType: nil,
                priority: entry.replayMetadata.priority
            )
        )

        do {
            _ = try await fetchNetworkAndOptionallyStore(
                request: entry.request,
                authScope: nil,
                key: entry.receipt.requestKey,
                storeInCache: false,
                cachedETag: nil,
                options: .init()
            )
            await store.markSucceeded(queueID: entry.receipt.queueID)
            await store.recordReplayTerminalSuccess(
                replayIdentity: entry.replayMetadata.replayIdentity,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .replaySucceeded(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    statusCode: 200
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replaySucceeded,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    resultType: "executed",
                    priority: entry.replayMetadata.priority
                )
            )
            await offlineReplayCoordinator.markOutcome(.succeeded)
        } catch let error as NetworkError {
            let reason = Self.failureReason(error: error)
            let conflictMetadata = OfflineQueueConflictMetadata(
                queueID: entry.receipt.queueID,
                requestKey: entry.receipt.requestKey,
                replayIdentity: entry.replayMetadata.replayIdentity,
                attempt: nextAttempt,
                maxReplayAttempts: entry.replayMetadata.maxReplayAttempts,
                failureReason: reason,
                statusCode: error.statusCode,
                priority: entry.replayMetadata.priority,
                enqueuedAt: entry.receipt.enqueuedAt
            )
            if shouldDeadLetterReplay(error: error, attempt: nextAttempt, maxReplayAttempts: entry.replayMetadata.maxReplayAttempts) {
                let resolution: OfflineConflictResolutionDecision
                if let offlineConflictResolver {
                    resolution = offlineConflictResolver(conflictMetadata)
                } else {
                    switch entry.replayMetadata.conflictPolicy {
                    case .drop:
                        resolution = .drop(reason: nil)
                    case .manualReview:
                        resolution = .manualReview(reason: nil)
                    case .retry:
                        resolution = .retry(afterSeconds: nil)
                    }
                }

                switch resolution {
                case .drop(let explicitReason):
                    let finalReason = explicitReason ?? reason
                    await store.markSucceeded(queueID: entry.receipt.queueID)
                    await emitOfflineQueueEvent(
                        .dropped(
                            queueID: entry.receipt.queueID,
                            requestKey: entry.receipt.requestKey,
                            reason: "conflict_policy_drop:\(finalReason)"
                        ),
                        telemetry: telemetryOfflineQueueContext(
                            type: .replayDroppedConflict,
                            queueID: entry.receipt.queueID,
                            requestKey: entry.receipt.requestKey,
                            attempt: nextAttempt,
                            enqueuedAt: entry.receipt.enqueuedAt,
                            reason: finalReason,
                            willRetry: false,
                            resultType: "dropped_conflict",
                            priority: entry.replayMetadata.priority
                        )
                    )
                    await offlineReplayCoordinator.markOutcome(.droppedConflict)
                    return
                case .manualReview(let explicitReason):
                    let finalReason = explicitReason ?? reason
                    await store.markManualReview(
                        queueID: entry.receipt.queueID,
                        reason: finalReason,
                        now: Date()
                    )
                    await emitOfflineQueueEvent(
                        .manualReviewRequired(
                            queueID: entry.receipt.queueID,
                            requestKey: entry.receipt.requestKey,
                            attempt: nextAttempt,
                            reason: finalReason
                        ),
                        telemetry: telemetryOfflineQueueContext(
                            type: .manualReviewRequired,
                            queueID: entry.receipt.queueID,
                            requestKey: entry.receipt.requestKey,
                            attempt: nextAttempt,
                            enqueuedAt: entry.receipt.enqueuedAt,
                            reason: finalReason,
                            willRetry: false,
                            resultType: "manual_review_required",
                            priority: entry.replayMetadata.priority
                        )
                    )
                    await offlineReplayCoordinator.markOutcome(.manualReview)
                    return
                case .retry(let afterSeconds):
                    if nextAttempt >= entry.replayMetadata.maxReplayAttempts {
                        await store.markDeadLetter(queueID: entry.receipt.queueID, reason: reason, now: Date())
                        await emitOfflineQueueEvent(
                            .deadLettered(
                                queueID: entry.receipt.queueID,
                                requestKey: entry.receipt.requestKey,
                                reason: reason
                            ),
                            telemetry: telemetryOfflineQueueContext(
                                type: .deadLettered,
                                queueID: entry.receipt.queueID,
                                requestKey: entry.receipt.requestKey,
                                attempt: nextAttempt,
                                enqueuedAt: entry.receipt.enqueuedAt,
                                reason: reason,
                                willRetry: false,
                                resultType: "terminal_failed",
                                priority: entry.replayMetadata.priority
                            )
                        )
                        await offlineReplayCoordinator.markOutcome(.failed)
                        return
                    }
                    let delaySeconds = max(0, afterSeconds ?? min(pow(2, Double(nextAttempt)), 60))
                    let nextRetryAt = Date().addingTimeInterval(delaySeconds)
                    await store.markRetryWaiting(
                        queueID: entry.receipt.queueID,
                        attempt: nextAttempt,
                        reason: reason,
                        nextRetryAt: nextRetryAt,
                        now: Date()
                    )
                    await emitOfflineQueueEvent(
                        .replayFailed(
                            queueID: entry.receipt.queueID,
                            requestKey: entry.receipt.requestKey,
                            attempt: nextAttempt,
                            reason: reason,
                            willRetry: true
                        ),
                        telemetry: telemetryOfflineQueueContext(
                            type: .replayFailed,
                            queueID: entry.receipt.queueID,
                            requestKey: entry.receipt.requestKey,
                            attempt: nextAttempt,
                            enqueuedAt: entry.receipt.enqueuedAt,
                            reason: reason,
                            willRetry: true,
                            resultType: "failed",
                            priority: entry.replayMetadata.priority
                        )
                    )
                    return
                }
            }

            let delaySeconds = min(pow(2, Double(nextAttempt)), 60)
            let nextRetryAt = Date().addingTimeInterval(delaySeconds)
            await store.markRetryWaiting(
                queueID: entry.receipt.queueID,
                attempt: nextAttempt,
                reason: reason,
                nextRetryAt: nextRetryAt,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .replayFailed(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    reason: reason,
                    willRetry: true
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replayFailed,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: reason,
                    willRetry: true,
                    resultType: "failed",
                    priority: entry.replayMetadata.priority
                )
            )
        } catch {
            let fallback = NetworkError.transport(underlying: error)
            let delaySeconds = min(pow(2, Double(nextAttempt)), 60)
            let nextRetryAt = Date().addingTimeInterval(delaySeconds)
            let reason = Self.failureReason(error: fallback)
            await store.markRetryWaiting(
                queueID: entry.receipt.queueID,
                attempt: nextAttempt,
                reason: reason,
                nextRetryAt: nextRetryAt,
                now: Date()
            )
            await emitOfflineQueueEvent(
                .replayFailed(
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    reason: reason,
                    willRetry: true
                ),
                telemetry: telemetryOfflineQueueContext(
                    type: .replayFailed,
                    queueID: entry.receipt.queueID,
                    requestKey: entry.receipt.requestKey,
                    attempt: nextAttempt,
                    enqueuedAt: entry.receipt.enqueuedAt,
                    reason: reason,
                    willRetry: true,
                    resultType: "failed",
                    priority: entry.replayMetadata.priority
                )
            )
        }
    }

    func shouldDeadLetterReplay(error: NetworkError, attempt: Int, maxReplayAttempts: Int) -> Bool {
        if attempt >= max(1, maxReplayAttempts) {
            return true
        }
        guard case .httpStatus(let code, _, _) = error else {
            return false
        }
        if code == 408 || code == 409 || code == 429 {
            return false
        }
        return (400...499).contains(code)
    }

    func emitOfflineQueueEvent(_ event: OfflineQueueEvent, telemetry: TelemetryOfflineQueueContext? = nil) async {
        await offlineQueueEventHub.emit(event)
        if let telemetry {
            telemetryHooks?.onOfflineQueueEvent?(telemetry)
        }
    }

    func telemetryOfflineQueueContext(
        type: TelemetryOfflineQueueEventType,
        queueID: String,
        requestKey: String,
        attempt: Int? = nil,
        enqueuedAt: Date? = nil,
        reason: String? = nil,
        willRetry: Bool? = nil,
        resultType: String? = nil,
        priority: OfflineQueuePriority? = nil,
        skippedRecords: Int? = nil
    ) -> TelemetryOfflineQueueContext {
        let ageMilliseconds: Double?
        if let enqueuedAt {
            ageMilliseconds = max(0, Date().timeIntervalSince(enqueuedAt)) * 1_000
        } else {
            ageMilliseconds = nil
        }
        return TelemetryOfflineQueueContext(
            type: type,
            queueID: queueID,
            requestKey: requestKey,
            attempt: attempt,
            ageMilliseconds: ageMilliseconds,
            reason: reason,
            willRetry: willRetry,
            resultType: resultType,
            priority: priority,
            skippedRecords: skippedRecords
        )
    }

    static func isQueueEligibleWriteMethod(_ method: URLMethod) -> Bool {
        switch method {
        case .post, .put, .patch:
            return true
        default:
            return false
        }
    }

    static func isOfflineError(_ error: NetworkError) -> Bool {
        guard case .transport(let underlying as URLError) = error else {
            return false
        }
        switch underlying.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

}
