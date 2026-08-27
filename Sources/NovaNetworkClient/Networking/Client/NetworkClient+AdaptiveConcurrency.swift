import Foundation
import NovaNetworkCore

extension NetworkClient {
    /// What the adaptive concurrency limiter is doing, or `nil` when the client has none.
    ///
    /// A limit that moves on its own is worth being able to look at — from a debug panel, a test, or
    /// a support build. `NetworkTelemetryHooks.onConcurrencyLimitChanged` reports the movements;
    /// this reports the state between them.
    public func concurrencySnapshot() async -> AdaptiveConcurrencyLimiter.Snapshot? {
        await adaptiveConcurrencyLimiter?.snapshot()
    }

    /// Runs the work holding a slot, and hands back what the work said about the server's capacity.
    ///
    /// With no limiter configured this is exactly the work, with no suspension added.
    func holdingConcurrencyPermit(
        _ work: @Sendable () async -> Result<NetworkResponse, NetworkError>
    ) async -> Result<NetworkResponse, NetworkError> {
        guard let limiter = adaptiveConcurrencyLimiter else { return await work() }

        let permit: AdaptiveConcurrencyLimiter.Permit
        do {
            permit = try await limiter.acquire()
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as NetworkError {
            // The queue timeout elapsed. The request never reached the transport.
            return .failure(error)
        } catch {
            return .failure(.transport(underlying: error))
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = await work()
        let elapsedMilliseconds = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000

        await limiter.release(permit, signal: Self.concurrencySignal(for: result, latencyMilliseconds: elapsedMilliseconds))
        return result
    }

    /// Reads one outcome as evidence about capacity.
    ///
    /// Only failures that mean "too much at once" count as congestion. A 404 is a fact about a URL,
    /// and treating it as pressure would shrink the limit every time a client asked for something
    /// that is not there.
    static func concurrencySignal(
        for result: Result<NetworkResponse, NetworkError>,
        latencyMilliseconds: Double
    ) -> ConcurrencySignal {
        switch result {
        case .success:
            return .succeeded(latencyMilliseconds: latencyMilliseconds)

        case let .failure(error):
            switch error {
            case let .httpStatus(code, _, _):
                // 429 is the server saying so outright; 503 is it saying so by falling over.
                return code == 429 || code == 503 ? .congested : .inconclusive
            case .clientRateLimited:
                return .congested
            case .timeoutBudgetExceeded:
                return .congested
            case let .transport(underlying):
                return isCongestionURLError(underlying) ? .congested : .inconclusive
            case .cancelled:
                // The caller went away. That says nothing about the server.
                return .inconclusive
            default:
                return .inconclusive
            }
        }
    }

    private static func isCongestionURLError(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost:
            return true
        default:
            return false
        }
    }
}
