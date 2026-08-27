import Foundation

/// What the network looks like right now, beyond "connected" or "not".
///
/// `OfflineConnectivityMonitor` answers one bit: can we reach anything. That bit is not enough to
/// decide whether to send a 40 MB upload — a phone on a metered hotspot with Low Data Mode on is
/// connected, and sending it anyway is the wrong answer.
public struct NetworkPath: Sendable, Equatable {
    /// Whether the path can carry traffic.
    public enum Status: String, Sendable, Equatable {
        /// Traffic can be sent now.
        case satisfied
        /// Nothing can be sent.
        case unsatisfied
        /// A connection would have to be established first, such as by bringing up a VPN.
        case requiresConnection
    }

    /// The kind of link carrying the traffic.
    public enum Interface: String, Sendable, Equatable, CaseIterable {
        case wifi
        case cellular
        case wiredEthernet
        case loopback
        case other
    }

    /// Whether traffic can be sent.
    public let status: Status
    /// Which links are available. Empty when nothing is.
    public let interfaces: Set<Interface>
    /// Whether the path costs money by the byte: cellular, or a personal hotspot.
    public let isExpensive: Bool
    /// Whether the user has asked for less data on this path, such as Low Data Mode.
    public let isConstrained: Bool

    /// Creates a path description.
    public init(
        status: Status,
        interfaces: Set<Interface> = [],
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.status = status
        self.interfaces = interfaces
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// A path that can carry anything, which is also the assumption when nothing is monitoring.
    public static let unrestricted = NetworkPath(status: .satisfied, interfaces: [.wifi])

    /// Whether traffic can be sent at all.
    public var isUsable: Bool { status == .satisfied }
}

/// What to do with a request given the path it would go out on.
public struct NetworkPathPolicy: Sendable, Equatable {
    /// The answer for one request.
    public enum Decision: String, Sendable, Equatable {
        /// Send it now.
        case send
        /// Do not send it now; hand it to the offline queue to replay when the path improves.
        case deferUntilPathImproves
        /// Do not send it, and do not keep it.
        case fail
    }

    /// What to do when the path costs money by the byte.
    public let onExpensive: Decision
    /// What to do when the user has asked for less data on this path.
    public let onConstrained: Decision
    /// What to do when nothing can be sent at all.
    public let onUnsatisfied: Decision

    /// Creates a policy.
    public init(
        onExpensive: Decision = .send,
        onConstrained: Decision = .send,
        onUnsatisfied: Decision = .deferUntilPathImproves
    ) {
        self.onExpensive = onExpensive
        self.onConstrained = onConstrained
        self.onUnsatisfied = onUnsatisfied
    }

    /// Sends everything, whatever the path. The behaviour of a client with no policy at all.
    public static let alwaysSend = NetworkPathPolicy(
        onExpensive: .send,
        onConstrained: .send,
        onUnsatisfied: .send
    )

    /// Holds large or optional work back on a metered or restricted path, and queues it instead.
    ///
    /// Requests marked essential still go: a policy that also blocked the login request would be a
    /// policy nobody could adopt.
    public static let respectMeteredPaths = NetworkPathPolicy(
        onExpensive: .deferUntilPathImproves,
        onConstrained: .deferUntilPathImproves,
        onUnsatisfied: .deferUntilPathImproves
    )

    /// The answer for one request.
    ///
    /// - Parameters:
    ///   - path: What the network looks like.
    ///   - isEssential: Whether the request must go regardless — a sign-in, a token refresh, a
    ///     payment confirmation. Essential requests are only stopped by a path that cannot carry
    ///     anything, and even then the policy decides whether that is a failure or a deferral.
    /// - Returns: What to do.
    public func decision(for path: NetworkPath, isEssential: Bool = false) -> Decision {
        guard path.isUsable else { return onUnsatisfied }
        guard !isEssential else { return .send }

        // Constrained is the user's explicit request for less data, so it outranks expensive, which
        // is only an inference about cost.
        if path.isConstrained, onConstrained != .send { return onConstrained }
        if path.isExpensive, onExpensive != .send { return onExpensive }
        return .send
    }
}

/// Reports what the network looks like, and when that changes.
///
/// The system implementation is `SystemNetworkPathMonitor`; supply your own to test a policy against
/// a path that never existed on the machine running the test.
public protocol NetworkPathMonitor: Sendable {
    /// The path now.
    func currentPath() async -> NetworkPath
    /// Every change, starting with the current value.
    func pathStream() -> AsyncStream<NetworkPath>
}
