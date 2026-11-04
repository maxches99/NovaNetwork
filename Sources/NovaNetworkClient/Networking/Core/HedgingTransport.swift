import Foundation
import NovaNetworkCore

/// Sends an eligible request a second time when the first is slow, and returns the first success.
///
/// It wraps the transport the HTTP pipeline uses, below the middleware, so both requests are the
/// same prepared request. It does not replace the client's `transport`: streaming, transfers, and
/// WebSockets find their capabilities by protocol conformance, which a wrapper would hide.
struct HedgingTransport: NetworkTransport {
    private enum Racer: Sendable {
        case primary
        case hedge
    }

    private enum Outcome: Sendable {
        case finished(Racer, Result<NetworkResponse, any Error>)
        case delayElapsed
        case timerCancelled
    }

    let base: any NetworkTransport
    let policy: HedgingPolicy
    let state: HedgingState
    let clock: any RetryClock
    let onEvent: (@Sendable (TelemetryHedgeContext) -> Void)?

    init(
        base: any NetworkTransport,
        policy: HedgingPolicy,
        clock: any RetryClock,
        onEvent: (@Sendable (TelemetryHedgeContext) -> Void)?
    ) {
        self.base = base
        self.policy = policy
        self.state = HedgingState(policy: policy)
        self.clock = clock
        self.onEvent = onEvent
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        guard policy.isEligible(request) else {
            return try await base.execute(request)
        }

        let host = request.url.host ?? ""
        await state.recordEligibleRequest()
        let delaySeconds = await state.delaySeconds(host: host)
        let delayMilliseconds = delaySeconds * 1_000
        let base = self.base
        let clock = self.clock

        let startedAt = DispatchTime.now().uptimeNanoseconds

        let result: Result<NetworkResponse, any Error> = await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await Self.run(.primary, request, on: base) }
            group.addTask {
                do {
                    try await clock.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    return .delayElapsed
                } catch {
                    return .timerCancelled
                }
            }

            var running: Set<Racer> = [.primary]
            var primaryError: (any Error)?
            var hedgeError: (any Error)?

            while let outcome = await group.next() {
                switch outcome {
                case .timerCancelled:
                    continue

                case .delayElapsed:
                    guard running.contains(.primary), !running.contains(.hedge) else { continue }
                    guard await state.trySpendHedge() else {
                        onEvent?(.init(type: .budgetExhausted, request: request, delayMilliseconds: delayMilliseconds))
                        continue
                    }
                    onEvent?(.init(type: .fired, request: request, delayMilliseconds: delayMilliseconds))
                    running.insert(.hedge)
                    group.addTask { await Self.run(.hedge, request, on: base) }

                case let .finished(racer, .success(response)):
                    group.cancelAll()
                    // The latency the caller saw, from the primary's start, whichever request won:
                    // recording only primary wins would leave the slow tail out of the history.
                    let seconds = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000_000
                    await state.recordLatency(seconds: seconds, host: host)
                    if racer == .hedge {
                        onEvent?(.init(type: .won, request: request, delayMilliseconds: delayMilliseconds))
                    }
                    return .success(response)

                case let .finished(racer, .failure(error)):
                    running.remove(racer)
                    if racer == .primary { primaryError = error } else { hedgeError = error }
                    // A primary that fails before the delay is not hedged: that is a failure, and
                    // failures belong to the retry policy.
                    if running.isEmpty {
                        group.cancelAll()
                        return .failure(primaryError ?? hedgeError ?? CancellationError())
                    }
                }
            }
            return .failure(primaryError ?? hedgeError ?? CancellationError())
        }
        return try result.get()
    }

    private static func run(
        _ racer: Racer,
        _ request: APIRequest,
        on transport: any NetworkTransport
    ) async -> Outcome {
        do {
            return .finished(racer, .success(try await transport.execute(request)))
        } catch {
            return .finished(racer, .failure(error))
        }
    }
}
