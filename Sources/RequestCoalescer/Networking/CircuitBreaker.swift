import Foundation

public enum CircuitBreakerScope: Sendable {
    case key
    case host
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
        var failureCount: Int
        var openUntilNanoseconds: UInt64?
    }

    private var entries: [String: Entry] = [:]

    func canExecute(identifier: String) -> Bool {
        guard let entry = entries[identifier], let openUntil = entry.openUntilNanoseconds else {
            return true
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= openUntil {
            entries[identifier] = Entry(failureCount: 0, openUntilNanoseconds: nil)
            return true
        }
        return false
    }

    func recordSuccess(identifier: String) {
        entries[identifier] = Entry(failureCount: 0, openUntilNanoseconds: nil)
    }

    func recordFailure(identifier: String, policy: CircuitBreakerPolicy) {
        let current = entries[identifier] ?? Entry(failureCount: 0, openUntilNanoseconds: nil)
        let nextFailureCount = current.failureCount + 1
        let cooldownNanoseconds = UInt64(policy.cooldownSeconds * 1_000_000_000)

        if nextFailureCount >= policy.failureThreshold {
            let until = DispatchTime.now().uptimeNanoseconds + cooldownNanoseconds
            entries[identifier] = Entry(failureCount: nextFailureCount, openUntilNanoseconds: until)
        } else {
            entries[identifier] = Entry(failureCount: nextFailureCount, openUntilNanoseconds: nil)
        }
    }
}
