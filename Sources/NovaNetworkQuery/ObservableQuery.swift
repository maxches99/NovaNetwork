#if canImport(Observation)
import Foundation
import Observation

/// A SwiftUI-facing model for one query.
///
/// The package supports iOS 13, and `@Observable` needs iOS 17, so this is the one part of the query
/// layer behind an availability gate. Everything it does is available everywhere through
/// ``QueryClient/states(for:as:)`` — the observation is a convenience, not the mechanism.
///
/// ```swift
/// struct ProfileView: View {
///     @State private var query: ObservableQuery<User>
///
///     var body: some View {
///         Group {
///             switch query.state {
///             case .idle, .loading(nil): ProgressView()
///             case let .loading(.some(user)), let .success(user, _): ProfileBody(user: user)
///             case let .failure(error, previous): ErrorView(error: error, stale: previous)
///             }
///         }
///         .task { await query.start() }
///     }
/// }
/// ```
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@Observable
@MainActor
public final class ObservableQuery<Value: Sendable> {
    /// The current state, updated as the query changes.
    public private(set) var state: QueryState<Value> = .idle

    @ObservationIgnored private let key: QueryKey
    @ObservationIgnored private let client: QueryClient
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Creates a model for one key.
    public init(key: QueryKey, client: QueryClient) {
        self.key = key
        self.client = client
    }

    /// Subscribes to the query and keeps ``state`` current until the task is cancelled.
    ///
    /// Safe to call from `.task {}`: SwiftUI cancels it when the view goes away, which unsubscribes.
    public func start() async {
        task?.cancel()

        let stream = await client.states(for: key, as: Value.self)
        for await next in stream {
            state = next
            if Task.isCancelled { break }
        }
    }

    /// Stops observing.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// The value being rendered, whether fresh, stale, or left over from before a failure.
    public var value: Value? {
        state.value
    }

    /// Whether a fetch is in flight.
    public var isLoading: Bool {
        state.isLoading
    }

    /// The most recent error, when the last attempt failed.
    public var error: (any Error)? {
        state.error
    }
}
#endif
