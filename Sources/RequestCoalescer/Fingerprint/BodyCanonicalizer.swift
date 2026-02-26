import Foundation

enum BodyCanonicalizer {
    static func canonicalBody(_ body: Data?) -> Data {
        guard let body, !body.isEmpty else { return Data() }

        if
            let object = try? JSONSerialization.jsonObject(with: body),
            JSONSerialization.isValidJSONObject(object),
            let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        {
            return normalized
        }

        // For non-JSON payloads, preserve the original bytes.
        return body
    }
}
