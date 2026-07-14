import NovaNetworkCore
import Foundation

public struct RequestFingerprint: Hashable, Sendable {
    public let method: String
    public let url: String
    public let headersDigest: String
    public let bodyDigest: String
    public let authScopeDigest: String?

    public var rawValue: String {
        [method.uppercased(), url, headersDigest, bodyDigest, authScopeDigest ?? ""]
            .joined(separator: "|")
    }

    // Fixed-length key is useful for dictionary keys, logs, and metrics.
    public var key: String { SHA256Util.hex(rawValue) }

    public static func make(
        method: String,
        url: URL,
        queryItems: [URLQueryItem]?,
        headers: [String: String] = [:],
        body: Data?,
        authScope: String?,
        policy: FingerprintPolicy = .default
    ) -> RequestFingerprint {
        let canonicalURL = URLCanonicalizer.canonicalURLString(
            url: url,
            queryItems: policy.includeQueryItems ? queryItems : nil
        )
        let canonicalBody = policy.includeBody ? BodyCanonicalizer.canonicalBody(body) : Data()
        let canonicalHeaders = HeaderCanonicalizer.canonicalHeaders(headers, inclusion: policy.headerInclusion)
        let headersDigest = SHA256Util.hex(canonicalHeaders)
        let bodyDigest = SHA256Util.hex(canonicalBody)
        let authDigest = authScope.map(SHA256Util.hex)

        return RequestFingerprint(
            method: method,
            url: canonicalURL,
            headersDigest: headersDigest,
            bodyDigest: bodyDigest,
            authScopeDigest: authDigest
        )
    }
}
