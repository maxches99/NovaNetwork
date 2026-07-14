import NovaNetworkCore
import Foundation

public enum RuntimePolicyScope: Sendable, Equatable {
    case global
    case host(String)
    case endpoint(host: String, pathPrefix: String)
}

public enum RuntimePolicySource: String, Sendable {
    case global
    case host
    case endpoint
    case requestOverride = "runtime_override"
    case runtimeUpdate = "runtime_update"
}

public struct CoalescingPolicy: Sendable, Equatable {
    public let dedupeTTLSeconds: TimeInterval?

    public init(dedupeTTLSeconds: TimeInterval? = nil) {
        self.dedupeTTLSeconds = dedupeTTLSeconds.map { max(0, $0) }
    }
}

public struct NetworkClientRuntimePolicy: Sendable, Equatable {
    public let retryPolicy: RetryPolicy?
    public let deadlineBudgetSeconds: TimeInterval?
    public let circuitBreakerPolicy: CircuitBreakerPolicy?
    public let coalescingPolicy: CoalescingPolicy?

    public init(
        retryPolicy: RetryPolicy? = nil,
        deadlineBudgetSeconds: TimeInterval? = nil,
        circuitBreakerPolicy: CircuitBreakerPolicy? = nil,
        coalescingPolicy: CoalescingPolicy? = nil
    ) {
        self.retryPolicy = retryPolicy
        self.deadlineBudgetSeconds = deadlineBudgetSeconds.map { max(0, $0) }
        self.circuitBreakerPolicy = circuitBreakerPolicy
        self.coalescingPolicy = coalescingPolicy
    }

    var isEmpty: Bool {
        retryPolicy == nil &&
        deadlineBudgetSeconds == nil &&
        circuitBreakerPolicy == nil &&
        coalescingPolicy == nil
    }
}

struct ResolvedRuntimePolicy: Sendable {
    let policy: NetworkClientRuntimePolicy
    let source: RuntimePolicySource
}

actor RuntimePolicyStore {
    private struct EndpointKey: Hashable {
        let host: String
        let pathPrefix: String
    }

    private var globalPolicy = NetworkClientRuntimePolicy()
    private var hostPolicies: [String: NetworkClientRuntimePolicy] = [:]
    private var endpointPolicies: [EndpointKey: NetworkClientRuntimePolicy] = [:]

    func update(
        policy: NetworkClientRuntimePolicy,
        scope: RuntimePolicyScope
    ) -> [String] {
        let changedFields: [String]
        switch scope {
        case .global:
            let previous = globalPolicy
            globalPolicy = policy
            changedFields = changedFieldNames(from: previous, to: policy)
        case .host(let host):
            let key = host.lowercased()
            let previous = hostPolicies[key] ?? .init()
            if policy.isEmpty {
                hostPolicies.removeValue(forKey: key)
            } else {
                hostPolicies[key] = policy
            }
            changedFields = changedFieldNames(from: previous, to: policy)
        case .endpoint(let host, let pathPrefix):
            let key = EndpointKey(
                host: host.lowercased(),
                pathPrefix: normalizedPathPrefix(pathPrefix)
            )
            let previous = endpointPolicies[key] ?? .init()
            if policy.isEmpty {
                endpointPolicies.removeValue(forKey: key)
            } else {
                endpointPolicies[key] = policy
            }
            changedFields = changedFieldNames(from: previous, to: policy)
        }
        return changedFields
    }

    func resolve(url: URL) -> ResolvedRuntimePolicy {
        var resolved = globalPolicy
        var source: RuntimePolicySource = globalPolicy.isEmpty ? .global : .global

        if let host = url.host?.lowercased(),
           let hostPolicy = hostPolicies[host] {
            resolved = merge(resolved, with: hostPolicy)
            source = .host
        }

        if let host = url.host?.lowercased(),
           let endpointPolicy = bestEndpointPolicy(host: host, path: normalizedPathPrefix(url.path)) {
            resolved = merge(resolved, with: endpointPolicy)
            source = .endpoint
        }

        return ResolvedRuntimePolicy(policy: resolved, source: source)
    }

    private func bestEndpointPolicy(host: String, path: String) -> NetworkClientRuntimePolicy? {
        let candidates = endpointPolicies
            .filter { $0.key.host == host && path.hasPrefix($0.key.pathPrefix) }
            .sorted { lhs, rhs in
                lhs.key.pathPrefix.count > rhs.key.pathPrefix.count
            }
        return candidates.first?.value
    }

    private func merge(
        _ base: NetworkClientRuntimePolicy,
        with override: NetworkClientRuntimePolicy
    ) -> NetworkClientRuntimePolicy {
        NetworkClientRuntimePolicy(
            retryPolicy: override.retryPolicy ?? base.retryPolicy,
            deadlineBudgetSeconds: override.deadlineBudgetSeconds ?? base.deadlineBudgetSeconds,
            circuitBreakerPolicy: override.circuitBreakerPolicy ?? base.circuitBreakerPolicy,
            coalescingPolicy: override.coalescingPolicy ?? base.coalescingPolicy
        )
    }

    private func normalizedPathPrefix(_ pathPrefix: String) -> String {
        let trimmed = pathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    private func changedFieldNames(
        from old: NetworkClientRuntimePolicy,
        to new: NetworkClientRuntimePolicy
    ) -> [String] {
        var fields: [String] = []
        if old.retryPolicy != new.retryPolicy {
            fields.append("retry_policy")
        }
        if old.deadlineBudgetSeconds != new.deadlineBudgetSeconds {
            fields.append("deadline_budget_seconds")
        }
        if old.circuitBreakerPolicy != new.circuitBreakerPolicy {
            fields.append("circuit_breaker_policy")
        }
        if old.coalescingPolicy != new.coalescingPolicy {
            fields.append("coalescing_policy")
        }
        return fields
    }
}
