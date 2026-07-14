import NovaNetworkCore
import Foundation

extension NetworkClient {
    static func executeWithRetry(
        key: String,
        request: APIRequest,
        authScope: String?,
        transport: any NetworkTransport,
        retryPolicy: RetryPolicy,
        retryClock: any RetryClock,
        retryRandomGenerator: any RetryRandomGenerator,
        middlewares: [NetworkMiddleware],
        telemetryHooks: NetworkTelemetryHooks?,
        observer: (@Sendable (NetworkClientEvent) -> Void)?,
        deadline: RequestDeadline?,
        coalescingMode: TelemetryCoalescingMode,
        policyScope: String
    ) async -> Result<NetworkResponse, NetworkError> {
        var attempt = 1
        var retriesUsed = 0

        while true {
            if deadlineHasExpired(deadline) {
                observer?(
                    .requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: "timeout_budget_exhausted",
                        remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                    )
                )
                return .failure(.timeoutBudgetExceeded)
            }
            if Task.isCancelled {
                observer?(
                    .requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: "cancelled",
                        remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                    )
                )
                telemetryHooks?.onRequestCancelled?(
                    TelemetryCancellationContext(
                        key: key,
                        attempt: attempt,
                        reason: "taskCancelled",
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                return .failure(.cancelled)
            }
            observer?(.requestAttempt(key: key, attempt: attempt))

            let startedAt = DispatchTime.now().uptimeNanoseconds
            let telemetryRequest = TelemetryRequestContext(
                key: key,
                attempt: attempt,
                coalescingMode: coalescingMode,
                request: request
            )
            telemetryHooks?.onRequestStart?(telemetryRequest)

            do {
                let preparedRequest = try await applyBeforeSendMiddlewares(
                    middlewares: middlewares,
                    request: request,
                    authScope: authScope
                )
                let response = try await transport.execute(preparedRequest)
                let postProcessed = try await applyAfterResponseMiddlewares(
                    middlewares: middlewares,
                    request: preparedRequest,
                    authScope: authScope,
                    response: response
                )

                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: postProcessed,
                        error: nil,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )
                observer?(.requestSucceeded(key: key, attempts: attempt))
                return .success(postProcessed)
            } catch is CancellationError {
                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: nil,
                        error: .cancelled,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )
                observer?(
                    .requestFailed(
                        key: key,
                        attempts: attempt,
                        reason: "cancelled",
                        remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                    )
                )
                telemetryHooks?.onRequestCancelled?(
                    TelemetryCancellationContext(
                        key: key,
                        attempt: attempt,
                        reason: "cancellationError",
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                return .failure(.cancelled)
            } catch let error as NetworkError {
                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: nil,
                        error: error,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )

                let reason = failureReason(error: error)
                let shouldRetry = retryPolicy.shouldRetry(error: error, request: request)
                if !shouldRetry {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(error)
                }
                if !retryPolicy.canRetry(attempt: attempt, retriesUsed: retriesUsed, error: error) {
                    observer?(.retryExhausted(key: key, attempts: attempt, reason: reason))
                    telemetryHooks?.onRetryExhausted?(
                        TelemetryRetryExhaustedContext(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(error)
                }

                let retryDecision = retryPolicy.delayDecision(
                    forAttempt: attempt,
                    error: error,
                    random: retryRandomGenerator
                )
                if !canScheduleRetry(withDelayNanoseconds: retryDecision.delayNanoseconds, deadline: deadline) {
                    observer?(
                        .retrySkipped(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient"
                        )
                    )
                    telemetryHooks?.onRetrySkipped?(
                        TelemetryRetrySkippedContext(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "timeout_budget_exhausted",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(.timeoutBudgetExceeded)
                }
                observer?(
                    .retryScheduled(
                        key: key,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason
                    )
                )
                telemetryHooks?.onRetryScheduled?(
                    TelemetryRetryContext(
                        key: key,
                        attempt: attempt,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason,
                        scheduleSource: retryDecision.source.rawValue,
                        retryProfile: retryDecision.category.rawValue,
                        policyScope: policyScope,
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                do {
                    try await retryClock.sleep(nanoseconds: retryDecision.delayNanoseconds)
                } catch {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "retrySleepCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }
                if Task.isCancelled {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "taskCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }

                retriesUsed += 1
                attempt += 1
                continue
            } catch {
                let wrapped = NetworkError.transport(underlying: error)
                telemetryHooks?.onRequestEnd?(
                    TelemetryResponseContext(
                        request: telemetryRequest,
                        response: nil,
                        error: wrapped,
                        durationMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                    )
                )

                let reason = failureReason(error: wrapped)
                let shouldRetry = retryPolicy.shouldRetry(error: wrapped, request: request)
                if !shouldRetry {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(wrapped)
                }
                if !retryPolicy.canRetry(attempt: attempt, retriesUsed: retriesUsed, error: wrapped) {
                    observer?(.retryExhausted(key: key, attempts: attempt, reason: reason))
                    telemetryHooks?.onRetryExhausted?(
                        TelemetryRetryExhaustedContext(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: reason,
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(wrapped)
                }

                let retryDecision = retryPolicy.delayDecision(
                    forAttempt: attempt,
                    error: wrapped,
                    random: retryRandomGenerator
                )
                if !canScheduleRetry(withDelayNanoseconds: retryDecision.delayNanoseconds, deadline: deadline) {
                    observer?(
                        .retrySkipped(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient"
                        )
                    )
                    telemetryHooks?.onRetrySkipped?(
                        TelemetryRetrySkippedContext(
                            key: key,
                            attempt: attempt,
                            reason: "budget_insufficient",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "timeout_budget_exhausted",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    return .failure(.timeoutBudgetExceeded)
                }
                observer?(
                    .retryScheduled(
                        key: key,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason
                    )
                )
                telemetryHooks?.onRetryScheduled?(
                    TelemetryRetryContext(
                        key: key,
                        attempt: attempt,
                        nextAttempt: attempt + 1,
                        delayMilliseconds: Double(retryDecision.delayNanoseconds) / 1_000_000,
                        reason: reason,
                        scheduleSource: retryDecision.source.rawValue,
                        retryProfile: retryDecision.category.rawValue,
                        policyScope: policyScope,
                        coalescingMode: coalescingMode,
                        request: request
                    )
                )
                do {
                    try await retryClock.sleep(nanoseconds: retryDecision.delayNanoseconds)
                } catch {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "retrySleepCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }
                if Task.isCancelled {
                    observer?(
                        .requestFailed(
                            key: key,
                            attempts: attempt,
                            reason: "cancelled",
                            remainingBudgetMilliseconds: remainingBudgetMilliseconds(deadline)
                        )
                    )
                    telemetryHooks?.onRequestCancelled?(
                        TelemetryCancellationContext(
                            key: key,
                            attempt: attempt,
                            reason: "taskCancelled",
                            coalescingMode: coalescingMode,
                            request: request
                        )
                    )
                    return .failure(.cancelled)
                }

                retriesUsed += 1
                attempt += 1
                continue
            }
        }
    }

    static func deadlineHasExpired(_ deadline: RequestDeadline?) -> Bool {
        guard let deadline else { return false }
        return DispatchTime.now().uptimeNanoseconds >= deadline.deadlineNanoseconds
    }

    static func remainingBudgetMilliseconds(_ deadline: RequestDeadline?) -> Double? {
        guard let deadline else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline.deadlineNanoseconds {
            return 0
        }
        return Double(deadline.deadlineNanoseconds - now) / 1_000_000
    }

    static func canScheduleRetry(
        withDelayNanoseconds delayNanoseconds: UInt64,
        deadline: RequestDeadline?
    ) -> Bool {
        guard let deadline else { return true }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline.deadlineNanoseconds else { return false }
        let remaining = deadline.deadlineNanoseconds - now
        return delayNanoseconds < remaining
    }

    static func failureReason(error: NetworkError) -> String {
        switch error {
        case .invalidResponse:
            return "invalid_response"
        case .httpStatus(let code, _, _):
            return "http_status_\(code)"
        case .decoding:
            return "decoding"
        case .transport(let underlying as URLError):
            return "transport_\(underlying.code.rawValue)"
        case .transport:
            return "transport"
        case .cancelled:
            return "cancelled"
        case .timeoutBudgetExceeded:
            return "timeout_budget_exhausted"
        case .circuitBreakerOpen:
            return "circuit_open"
        case .coalescerLimitExceeded:
            return "coalescer_limit_exceeded"
        case .clientRateLimited:
            return "client_rate_limited"
        case .queueCapacityExceeded:
            return "offline_queue_capacity_exceeded"
        case .offlineQueueUnavailable:
            return "offline_queue_unavailable"
        case .authenticationRefreshFailed:
            return "authentication_refresh_failed"
        }
    }

    static func telemetryCoalescerContext(
        from event: RequestCoalescer<NetworkResponse, NetworkError>.Event
    ) -> TelemetryCoalescerContext? {
        switch event {
        case .started(let key):
            return TelemetryCoalescerContext(type: .started, key: key)
        case .coalesced(let key, let waiterCount):
            return TelemetryCoalescerContext(type: .coalesced, key: key, waiterCount: waiterCount)
        case .bypassed(let key, let reason):
            return TelemetryCoalescerContext(type: .bypassed, key: key, reason: reason.rawValue)
        case .waiterCancelled(let key, let remainingWaiters):
            return TelemetryCoalescerContext(type: .waiterCancelled, key: key, waiterCount: remainingWaiters)
        case .timedOut(let key, let durationMilliseconds, let waiterCount):
            return TelemetryCoalescerContext(
                type: .timedOut,
                key: key,
                waiterCount: waiterCount,
                durationMilliseconds: durationMilliseconds,
                wasCancelled: true
            )
        case .finished(let key, let durationMilliseconds, let waiterCount, let wasCancelled):
            return TelemetryCoalescerContext(
                type: .finished,
                key: key,
                waiterCount: waiterCount,
                durationMilliseconds: durationMilliseconds,
                wasCancelled: wasCancelled
            )
        }
    }
    static func applyBeforeSendMiddlewares(
        middlewares: [NetworkMiddleware],
        request: APIRequest,
        authScope: String?
    ) async throws -> APIRequest {
        var current = request
        for middleware in middlewares {
            if let beforeSend = middleware.beforeSend {
                current = try await beforeSend(current, authScope)
            }
        }
        return current
    }

    static func applyAfterResponseMiddlewares(
        middlewares: [NetworkMiddleware],
        request: APIRequest,
        authScope: String?,
        response: NetworkResponse
    ) async throws -> NetworkResponse {
        var current = response
        for middleware in middlewares {
            if let afterResponse = middleware.afterResponse {
                current = try await afterResponse(request, authScope, current)
            }
        }
        return current
    }
}
