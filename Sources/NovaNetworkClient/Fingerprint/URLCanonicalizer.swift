import NovaNetworkCore
import Foundation

enum URLCanonicalizer {
    static func canonicalURLString(url: URL, queryItems: [URLQueryItem]?) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        }

        return components.url?.absoluteString ?? url.absoluteString
    }
}
