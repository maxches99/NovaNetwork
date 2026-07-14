import NovaNetworkCore
import Foundation

public struct FingerprintPolicy: Sendable {
    public enum HeaderInclusion: Sendable {
        case none
        case all
        case allowlist(Set<String>)
    }

    public var includeQueryItems: Bool
    public var includeBody: Bool
    public var headerInclusion: HeaderInclusion

    public init(
        includeQueryItems: Bool = true,
        includeBody: Bool = true,
        headerInclusion: HeaderInclusion = .all
    ) {
        self.includeQueryItems = includeQueryItems
        self.includeBody = includeBody
        self.headerInclusion = headerInclusion
    }

    public static let `default` = FingerprintPolicy()
}
