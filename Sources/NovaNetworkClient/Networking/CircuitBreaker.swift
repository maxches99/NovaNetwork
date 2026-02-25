import Foundation

public enum CircuitBreakerScope: Sendable {
    case key
    case host
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

public struct CircuitBreakerPolicy: Sendable {
    public let scope: CircuitBreakerScope
    public let failureThreshold: Int
    public let cooldownSeconds: TimeInterval

    public init(
        scope: CircuitBreakerScope = .host,
        failureThreshold: Int = 3,
        cooldownSeconds: TimeInterval = 10
    ) {
        self.scope = scope
        self.failureThreshold = max(1, failureThreshold)
        self.cooldownSeconds = max(0, cooldownSeconds)
    }
}

actor CircuitBreakerStore {
    private struct Entry {
        var state: CircuitBreakerState
        var failureCount: Int
        var openUntilNanoseconds: UInt64?
        var halfOpenProbeInFlight: Bool
    }

    struct GateDecision {
        let canExecute: Bool
        let transition: CircuitBreakerTransition?
    }

    private var entries: [String: Entry] = [:]

    func canExecute(identifier: String, policy: CircuitBreakerPolicy) -> GateDecision {
        let now = DispatchTime.now().uptimeNanoseconds
        var entry = entries[identifier] ?? Entry(
            state: .closed,
            failureCount: 0,
            openUntilNanoseconds: nil,
            halfOpenProbeInFlight: false
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
            entry.halfOpenProbeInFlight = true
            entries[identifier] = entry
            return GateDecision(canExecute: true, transition: transition)
        }

        switch entry.state {
        case .closed:
            entries[identifier] = entry
            return GateDecision(canExecute: true, transition: nil)
        case .open:
            entries[identifier] = entry
            return GateDecision(canExecute: false, transition: nil)
        case .halfOpen:
            if entry.halfOpenProbeInFlight {
                entries[identifier] = entry
                return GateDecision(canExecute: false, transition: nil)
            }
            entry.halfOpenProbeInFlight = true
            entries[identifier] = entry
            return GateDecision(canExecute: true, transition: nil)
        }
    }

    func recordSuccess(identifier: String, policy: CircuitBreakerPolicy) -> CircuitBreakerTransition? {
        guard var entry = entries[identifier] else {
            entries[identifier] = Entry(state: .closed, failureCount: 0, openUntilNanoseconds: nil, halfOpenProbeInFlight: false)
            return nil
        }

        let previousState = entry.state
        entry.state = .closed
        entry.failureCount = 0
        entry.openUntilNanoseconds = nil
        entry.halfOpenProbeInFlight = false
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
            halfOpenProbeInFlight: false
        )
        let now = DispatchTime.now().uptimeNanoseconds
        let cooldownNanoseconds = UInt64(policy.cooldownSeconds * 1_000_000_000)
        let openDurationMilliseconds = policy.cooldownSeconds * 1_000

        switch current.state {
        case .halfOpen:
            current.state = .open
            current.failureCount = max(1, current.failureCount)
            current.openUntilNanoseconds = now + cooldownNanoseconds
            current.halfOpenProbeInFlight = false
            entries[identifier] = current
            return CircuitBreakerTransition(
                identifier: identifier,
                fromState: .halfOpen,
                toState: .open,
                failureCount: current.failureCount,
                openDurationMilliseconds: openDurationMilliseconds
            )
        case .open:
            current.openUntilNanoseconds = now + cooldownNanoseconds
            entries[identifier] = current
            return nil
        case .closed:
            let nextFailureCount = current.failureCount + 1
            current.failureCount = nextFailureCount
            current.halfOpenProbeInFlight = false
            if nextFailureCount >= policy.failureThreshold {
                current.state = .open
                current.openUntilNanoseconds = now + cooldownNanoseconds
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
}
