import Foundation

public enum CircuitBreakerScope: Sendable {
    case key
    case host
}

public enum CircuitBreakerProbePolicy: Sendable, Equatable {
    case singleProbe
    case parallelProbes(maxConcurrent: Int)

    var maxConcurrentProbes: Int {
        switch self {
        case .singleProbe:
            return 1
        case .parallelProbes(let maxConcurrent):
            return max(1, maxConcurrent)
        }
    }

    var telemetryName: String {
        switch self {
        case .singleProbe:
            return "single_probe"
        case .parallelProbes(let maxConcurrent):
            return "parallel_probes_\(max(1, maxConcurrent))"
        }
    }
}

public enum CircuitBreakerState: String, Sendable {
    case closed
    case open
    case halfOpen = "half_open"
}

public struct CircuitBreakerTransition: Sendable {
    public let identifier: String
    public let fromState: CircuitBreakerState
    public let toState: CircuitBreakerState
    public let failureCount: Int
    public let openDurationMilliseconds: Double

    public init(
        identifier: String,
        fromState: CircuitBreakerState,
        toState: CircuitBreakerState,
        failureCount: Int,
        openDurationMilliseconds: Double
    ) {
        self.identifier = identifier
        self.fromState = fromState
        self.toState = toState
        self.failureCount = failureCount
        self.openDurationMilliseconds = openDurationMilliseconds
    }
}

public struct CircuitBreakerPolicy: Sendable, Equatable {
    public let scope: CircuitBreakerScope
    public let failureThreshold: Int
    public let cooldownSeconds: TimeInterval
    public let halfOpenJitterSeconds: TimeInterval
    public let probePolicy: CircuitBreakerProbePolicy

    public init(
        scope: CircuitBreakerScope = .host,
        failureThreshold: Int = 3,
        cooldownSeconds: TimeInterval = 10,
        halfOpenJitterSeconds: TimeInterval = 0,
        probePolicy: CircuitBreakerProbePolicy = .singleProbe
    ) {
        self.scope = scope
        self.failureThreshold = max(1, failureThreshold)
        self.cooldownSeconds = max(0, cooldownSeconds)
        self.halfOpenJitterSeconds = max(0, halfOpenJitterSeconds)
        self.probePolicy = probePolicy
    }
}

actor CircuitBreakerStore {
    private struct Entry {
        var state: CircuitBreakerState
        var failureCount: Int
        var openUntilNanoseconds: UInt64?
        var halfOpenProbeCount: Int
    }

    struct GateDecision {
        let canExecute: Bool
        let transition: CircuitBreakerTransition?
    }

    private var entries: [String: Entry] = [:]

    private func jitterNanoseconds(identifier: String, policy: CircuitBreakerPolicy) -> UInt64 {
        guard policy.halfOpenJitterSeconds > 0 else { return 0 }
        let maxJitterNanoseconds = UInt64(policy.halfOpenJitterSeconds * 1_000_000_000)
        guard maxJitterNanoseconds > 0 else { return 0 }
        let hash = UInt64(bitPattern: Int64(identifier.hashValue))
        return hash % (maxJitterNanoseconds + 1)
    }

    func canExecute(identifier: String, policy: CircuitBreakerPolicy) -> GateDecision {
        let now = DispatchTime.now().uptimeNanoseconds
        var entry = entries[identifier] ?? Entry(
            state: .closed,
            failureCount: 0,
            openUntilNanoseconds: nil,
            halfOpenProbeCount: 0
        )

        if entry.state == .open, let openUntil = entry.openUntilNanoseconds, now >= openUntil {
            let transition = CircuitBreakerTransition(
                identifier: identifier,
                fromState: .open,
                toState: .halfOpen,
                failureCount: entry.failureCount,
                openDurationMilliseconds: policy.cooldownSeconds * 1_000
            )
            entry.state = .halfOpen
            entry.openUntilNanoseconds = nil
            entry.halfOpenProbeCount = 0
            entries[identifier] = entry
            let canExecute = reserveHalfOpenProbeIfPossible(&entry, identifier: identifier, policy: policy)
            return GateDecision(canExecute: canExecute, transition: transition)
        }

        switch entry.state {
        case .closed:
            entries[identifier] = entry
            return GateDecision(canExecute: true, transition: nil)
        case .open:
            entries[identifier] = entry
            return GateDecision(canExecute: false, transition: nil)
        case .halfOpen:
            let canExecute = reserveHalfOpenProbeIfPossible(&entry, identifier: identifier, policy: policy)
            return GateDecision(canExecute: canExecute, transition: nil)
        }
    }

    func recordSuccess(identifier: String, policy: CircuitBreakerPolicy) -> CircuitBreakerTransition? {
        guard var entry = entries[identifier] else {
            entries[identifier] = Entry(state: .closed, failureCount: 0, openUntilNanoseconds: nil, halfOpenProbeCount: 0)
            return nil
        }

        let previousState = entry.state
        entry.state = .closed
        entry.failureCount = 0
        entry.openUntilNanoseconds = nil
        entry.halfOpenProbeCount = 0
        entries[identifier] = entry

        guard previousState != .closed else { return nil }
        return CircuitBreakerTransition(
            identifier: identifier,
            fromState: previousState,
            toState: .closed,
            failureCount: 0,
            openDurationMilliseconds: policy.cooldownSeconds * 1_000
        )
    }

    func recordFailure(identifier: String, policy: CircuitBreakerPolicy) -> CircuitBreakerTransition? {
        var current = entries[identifier] ?? Entry(
            state: .closed,
            failureCount: 0,
            openUntilNanoseconds: nil,
            halfOpenProbeCount: 0
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let cooldownNanoseconds = UInt64(policy.cooldownSeconds * 1_000_000_000)
        let jitterNanoseconds = jitterNanoseconds(identifier: identifier, policy: policy)
        let openDurationMilliseconds = policy.cooldownSeconds * 1_000

        switch current.state {
        case .halfOpen:
            current.state = .open
            current.failureCount = max(1, current.failureCount)
            current.openUntilNanoseconds = now.saturatingAdd(cooldownNanoseconds).saturatingAdd(jitterNanoseconds)
            current.halfOpenProbeCount = 0
            entries[identifier] = current
            return CircuitBreakerTransition(
                identifier: identifier,
                fromState: .halfOpen,
                toState: .open,
                failureCount: current.failureCount,
                openDurationMilliseconds: openDurationMilliseconds
            )
        case .open:
            current.openUntilNanoseconds = now.saturatingAdd(cooldownNanoseconds).saturatingAdd(jitterNanoseconds)
            entries[identifier] = current
            return nil
        case .closed:
            let nextFailureCount = current.failureCount + 1
            current.failureCount = nextFailureCount
            current.halfOpenProbeCount = 0
            if nextFailureCount >= policy.failureThreshold {
                current.state = .open
                current.openUntilNanoseconds = now.saturatingAdd(cooldownNanoseconds).saturatingAdd(jitterNanoseconds)
                entries[identifier] = current
                return CircuitBreakerTransition(
                    identifier: identifier,
                    fromState: .closed,
                    toState: .open,
                    failureCount: nextFailureCount,
                    openDurationMilliseconds: openDurationMilliseconds
                )
            }
            entries[identifier] = current
            return nil
        }
    }

    private func reserveHalfOpenProbeIfPossible(
        _ entry: inout Entry,
        identifier: String,
        policy: CircuitBreakerPolicy
    ) -> Bool {
        let maxConcurrent = policy.probePolicy.maxConcurrentProbes
        guard entry.halfOpenProbeCount < maxConcurrent else {
            entries[identifier] = entry
            return false
        }
        entry.halfOpenProbeCount += 1
        entries[identifier] = entry
        return true
    }
}

private extension UInt64 {
    func saturatingAdd(_ rhs: UInt64) -> UInt64 {
        let (value, overflow) = addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}
