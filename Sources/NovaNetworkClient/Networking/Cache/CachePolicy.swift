import NovaNetworkCore
import Foundation

public enum CachePolicy: Sendable {
    case networkOnly
    case cacheFirst(maxAge: TimeInterval)
    case staleWhileRevalidate(maxAge: TimeInterval, staleAge: TimeInterval)

    var normalized: CachePolicy {
        switch self {
        case .networkOnly:
            return .networkOnly
        case .cacheFirst(let maxAge):
            return .cacheFirst(maxAge: max(0, maxAge))
        case .staleWhileRevalidate(let maxAge, let staleAge):
            return .staleWhileRevalidate(
                maxAge: max(0, maxAge),
                staleAge: max(max(0, staleAge), max(0, maxAge))
            )
        }
    }
}
