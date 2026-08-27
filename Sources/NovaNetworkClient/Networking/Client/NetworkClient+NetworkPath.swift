import Foundation
import NovaNetworkCore

/// Why a request was not sent: the path it would have gone out on was ruled out by policy.
///
/// Carried as the `underlying` of `NetworkError.transport`, which keeps the client's error contract
/// unchanged and, deliberately, keeps it out of the set of errors the offline queue treats as
/// "try again when we are back online". A `.fail` decision means do not keep it.
public struct NetworkPathRestrictionError: Error, Equatable, CustomStringConvertible {
    /// What the path looked like.
    public let path: NetworkPath
    /// What the policy said about it.
    public let decision: NetworkPathPolicy.Decision

    /// Creates a restriction error.
    public init(path: NetworkPath, decision: NetworkPathPolicy.Decision) {
        self.path = path
        self.decision = decision
    }

    public var description: String {
        var reasons: [String] = []
        if !path.isUsable { reasons.append("the network path is \(path.status.rawValue)") }
        if path.isConstrained { reasons.append("the path is constrained") }
        if path.isExpensive { reasons.append("the path is expensive") }
        let why = reasons.isEmpty ? "the network path was ruled out" : reasons.joined(separator: " and ")
        return "The request was not sent because \(why)."
    }
}

extension NetworkClient {
    /// The path the client is currently seeing, or `nil` when nothing is monitoring it.
    public func currentNetworkPath() async -> NetworkPath? {
        await configuredNetworkPathMonitor?.currentPath()
    }

    /// Throws if the policy says this request should not go out on the current path.
    ///
    /// Deferral and failure are both reported as `NetworkError.transport`, but with different
    /// underlying errors, and that difference is what routes them: a deferral carries a `URLError`
    /// the offline queue already recognises, so `enqueueWrite` stores it and replays it later
    /// without any parallel machinery. A failure carries ``NetworkPathRestrictionError``, which the
    /// queue does not recognise, so it propagates.
    func enforceNetworkPathPolicy(isEssential: Bool) async throws {
        guard let policy = configuredNetworkPathPolicy, let monitor = configuredNetworkPathMonitor else {
            return
        }

        let path = await monitor.currentPath()
        switch policy.decision(for: path, isEssential: isEssential) {
        case .send:
            return

        case .deferUntilPathImproves:
            // `notConnectedToInternet` when there is no path at all, `dataNotAllowed` when there is
            // one and policy declined to use it. Both are honest descriptions, and both are already
            // in the set the offline queue replays.
            let code: URLError.Code = path.isUsable ? .dataNotAllowed : .notConnectedToInternet
            throw NetworkError.transport(underlying: URLError(code))

        case .fail:
            throw NetworkError.transport(
                underlying: NetworkPathRestrictionError(path: path, decision: .fail)
            )
        }
    }
}
