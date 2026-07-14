import NovaNetworkCore
import Foundation

/// Provides refreshed authentication headers after an unauthorized HTTP response.
public struct HTTPAuthRefreshProvider: Sendable {
    /// Async refresh operation keyed by the request's authentication scope.
    public typealias RefreshHeaders = @Sendable (_ authScope: String?) async throws -> [String: String]

    /// Closure invoked by the single-flight refresh coordinator.
    public let refreshHeaders: RefreshHeaders

    /// Creates an HTTP authentication refresh provider.
    public init(refreshHeaders: @escaping RefreshHeaders) {
        self.refreshHeaders = refreshHeaders
    }
}

/// Controls which HTTP responses trigger authentication refresh and replay.
public struct HTTPAuthRefreshPolicy: Sendable, Equatable {
    /// Maximum refresh-and-replay cycles for one underlying request.
    public let maxRefreshAttempts: Int

    /// HTTP status codes treated as authentication challenges.
    public let unauthorizedStatusCodes: Set<Int>

    /// Creates a bounded authentication refresh policy.
    public init(maxRefreshAttempts: Int = 1, unauthorizedStatusCodes: Set<Int> = [401]) {
        self.maxRefreshAttempts = max(0, maxRefreshAttempts)
        self.unauthorizedStatusCodes = unauthorizedStatusCodes
    }

    /// Default single-refresh policy for HTTP 401 responses.
    public static let `default` = HTTPAuthRefreshPolicy()
}

/// HTTP authentication refresh telemetry emitted once per actual refresh operation.
public struct TelemetryHTTPAuthRefreshContext: Sendable {
    /// Refresh lifecycle event.
    public enum Event: String, Sendable {
        /// A new refresh operation started.
        case started
        /// Refresh completed and returned replacement headers.
        case succeeded
        /// Refresh terminated with an error.
        case failed
    }

    /// Current lifecycle event.
    public let event: Event

    /// Authentication scope identifier, or `default` when no scope was supplied.
    public let authScope: String

    /// Refresh generation for the scope.
    public let generation: Int

    /// Number of requests that joined this refresh operation.
    public let waiterCount: Int

    /// Sanitized error type for failed refreshes.
    public let reason: String?

    /// Creates authentication refresh telemetry.
    public init(
        event: Event,
        authScope: String,
        generation: Int,
        waiterCount: Int,
        reason: String? = nil
    ) {
        self.event = event
        self.authScope = authScope
        self.generation = generation
        self.waiterCount = waiterCount
        self.reason = reason
    }
}

actor HTTPAuthRefreshCoordinator {
    private struct InFlight {
        let task: Task<[String: String], any Error>
        var waiterCount: Int
        let generation: Int
    }

    private var inFlightByScope: [String: InFlight] = [:]
    private var generationByScope: [String: Int] = [:]
    private let telemetry: NetworkTelemetryHooks.OnHTTPAuthRefresh?

    init(telemetry: NetworkTelemetryHooks.OnHTTPAuthRefresh?) {
        self.telemetry = telemetry
    }

    func refresh(
        authScope: String?,
        provider: HTTPAuthRefreshProvider
    ) async throws -> [String: String] {
        let scopeKey = authScope ?? "default"
        if var existing = inFlightByScope[scopeKey] {
            existing.waiterCount += 1
            inFlightByScope[scopeKey] = existing
            return try await existing.task.value
        }

        let generation = (generationByScope[scopeKey] ?? 0) + 1
        let task = Task {
            try await provider.refreshHeaders(authScope)
        }
        inFlightByScope[scopeKey] = InFlight(task: task, waiterCount: 1, generation: generation)
        telemetry?(
            .init(
                event: .started,
                authScope: scopeKey,
                generation: generation,
                waiterCount: 1
            )
        )

        do {
            let headers = try await task.value
            let waiterCount = inFlightByScope[scopeKey]?.waiterCount ?? 1
            inFlightByScope[scopeKey] = nil
            generationByScope[scopeKey] = generation
            telemetry?(
                .init(
                    event: .succeeded,
                    authScope: scopeKey,
                    generation: generation,
                    waiterCount: waiterCount
                )
            )
            return headers
        } catch {
            let waiterCount = inFlightByScope[scopeKey]?.waiterCount ?? 1
            inFlightByScope[scopeKey] = nil
            telemetry?(
                .init(
                    event: .failed,
                    authScope: scopeKey,
                    generation: generation,
                    waiterCount: waiterCount,
                    reason: String(describing: type(of: error))
                )
            )
            throw error
        }
    }
}
