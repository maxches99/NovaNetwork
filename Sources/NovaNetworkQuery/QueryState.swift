import Foundation

/// What a screen needs to know about one query, in one value.
///
/// Errors are part of the state rather than only thrown, because a failure that is only thrown
/// forces every screen to invent its own handling. Having it here lets a view render the problem
/// beside whatever value it already had.
public enum QueryState<Value: Sendable>: Sendable {
    /// Nothing has been asked for yet.
    case idle
    /// A fetch is running. Carries the previous value when there is one, so a refresh does not blank
    /// the screen.
    case loading(previous: Value?)
    /// A value is available. `isStale` means a refresh is warranted or already running.
    case success(Value, isStale: Bool)
    /// The fetch failed. Carries the last good value when there is one.
    case failure(any Error, previous: Value?)

    /// The value to render, whether it is fresh, stale, or left over from before a failure.
    public var value: Value? {
        switch self {
        case .idle: nil
        case let .loading(previous): previous
        case let .success(value, _): value
        case let .failure(_, previous): previous
        }
    }

    /// The error, when the most recent attempt failed.
    public var error: (any Error)? {
        guard case let .failure(error, _) = self else { return nil }
        return error
    }

    /// Whether a fetch is in flight.
    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// Whether the value on hand is known to be out of date.
    public var isStale: Bool {
        if case let .success(_, isStale) = self { return isStale }
        return false
    }

    /// Whether there is anything to render.
    public var hasValue: Bool {
        value != nil
    }
}
