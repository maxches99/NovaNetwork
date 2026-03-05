import Foundation

extension NetworkClient {
    func ageSeconds(since startNanoseconds: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startNanoseconds ? (now - startNanoseconds) : 0
        return TimeInterval(elapsed) / 1_000_000_000
    }

    func ageMilliseconds(since startNanoseconds: UInt64) -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= startNanoseconds ? (now - startNanoseconds) : 0
        return Double(elapsed) / 1_000_000
    }

    func shouldStoreInCache(_ headers: [String: String]) -> Bool {
        let directives = cacheDirectives(from: headers)
        return !directives.contains("no-store")
    }

    func varyHeaders(from responseHeaders: [String: String], requestHeaders: [String: String]) -> [String: String] {
        guard let rawVary = headerValue("Vary", in: responseHeaders) else { return [:] }
        let names = rawVary
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "*" }
        guard !names.isEmpty else { return [:] }

        var captured: [String: String] = [:]
        for name in names {
            let value = requestHeaders.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
            captured[name.lowercased()] = value
        }
        return captured
    }

    func varyMatches(cached: CachedResponse, request: APIRequest) -> Bool {
        guard !cached.varyRequestHeaders.isEmpty else { return true }
        for (name, expectedValue) in cached.varyRequestHeaders {
            let actual = request.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
            if actual != expectedValue {
                return false
            }
        }
        return true
    }

    func effectiveMaxAge(clientMaxAge: TimeInterval, cached: CachedResponse) -> TimeInterval {
        var value = max(0, clientMaxAge)
        if let serverMax = cacheControlMaxAge(headers: cached.headers) {
            value = min(value, serverMax)
        }
        return value
    }

    func effectiveStaleAges(
        clientMaxAge: TimeInterval,
        clientStaleAge: TimeInterval,
        cached: CachedResponse
    ) -> (maxAge: TimeInterval, staleAge: TimeInterval) {
        let maxAge = effectiveMaxAge(clientMaxAge: clientMaxAge, cached: cached)
        var staleAge = max(maxAge, clientStaleAge)
        if let swr = cacheControlStaleWhileRevalidate(headers: cached.headers) {
            staleAge = min(staleAge, maxAge + swr)
        }
        return (maxAge, staleAge)
    }

    func isFreshByExpiresHeader(cached: CachedResponse) -> Bool {
        guard let expires = cacheControlExpires(headers: cached.headers) else { return false }
        return Date() <= expires
    }

    func cacheControlMaxAge(headers: [String: String]) -> TimeInterval? {
        for directive in cacheDirectives(from: headers) {
            if directive.hasPrefix("max-age=") {
                let raw = directive.replacingOccurrences(of: "max-age=", with: "")
                if let value = TimeInterval(raw) {
                    return max(0, value)
                }
            }
        }
        return nil
    }

    func cacheControlStaleWhileRevalidate(headers: [String: String]) -> TimeInterval? {
        for directive in cacheDirectives(from: headers) {
            if directive.hasPrefix("stale-while-revalidate=") {
                let raw = directive.replacingOccurrences(of: "stale-while-revalidate=", with: "")
                if let value = TimeInterval(raw) {
                    return max(0, value)
                }
            }
        }
        return nil
    }

    func cacheControlExpires(headers: [String: String]) -> Date? {
        guard let expires = headerValue("Expires", in: headers) else { return nil }
        return DateFormatter.rfc1123.date(from: expires)
    }

    func cacheDirectives(from headers: [String: String]) -> Set<String> {
        guard let cacheControl = headerValue("Cache-Control", in: headers) else { return [] }
        return Set(
            cacheControl
                .lowercased()
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        )
    }

    func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private extension DateFormatter {
    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}
