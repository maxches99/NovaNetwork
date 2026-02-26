import Foundation

enum HeaderCanonicalizer {
    static func canonicalHeaders(
        _ headers: [String: String],
        inclusion: FingerprintPolicy.HeaderInclusion
    ) -> String {
        let normalized: [(name: String, value: String)]

        switch inclusion {
        case .none:
            return ""
        case .all:
            normalized = headers.map { ($0.key.lowercased(), $0.value) }
        case .allowlist(let names):
            let allowed = Set(names.map { $0.lowercased() })
            normalized = headers.compactMap { key, value in
                let lowered = key.lowercased()
                guard allowed.contains(lowered) else { return nil }
                return (lowered, value)
            }
        }

        return normalized
            .sorted {
                if $0.name == $1.name {
                    return $0.value < $1.value
                }
                return $0.name < $1.name
            }
            .map { "\($0.name):\($0.value)" }
            .joined(separator: "\n")
    }
}
