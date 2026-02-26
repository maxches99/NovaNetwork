import Foundation

public struct IdempotencyPolicy: Sendable {
    public enum KeyStrategy: Sendable {
        case uuid
        case fingerprintDigest
    }

    public let headerName: String
    public let guardedMethods: Set<URLMethod>
    public let keyStrategy: KeyStrategy

    public init(
        headerName: String = "Idempotency-Key",
        guardedMethods: Set<URLMethod> = [.post, .put, .patch],
        keyStrategy: KeyStrategy = .uuid
    ) {
        self.headerName = headerName
        self.guardedMethods = guardedMethods
        self.keyStrategy = keyStrategy
    }

    public static let `default` = IdempotencyPolicy()
}

public extension APIRequest {
    func withIdempotencyKey(_ key: String, headerName: String = "Idempotency-Key") -> APIRequest {
        withMergedHeaders([headerName: key])
    }
}
