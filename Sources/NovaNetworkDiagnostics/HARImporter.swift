import Foundation

/// Reads a HAR 1.2 log back into records.
///
/// The exporter turns a session into an artifact someone can attach to a bug report; this is the
/// other half, so that artifact can be opened and read rather than only forwarded. It accepts HAR
/// from any producer — a browser, Charles, Proxyman — and every field HAR does not define is simply
/// absent rather than invented.
///
/// Where a file was written by ``HARExporter``, the retry story, coalescing, and cache outcome come
/// back too: the exporter records them in each entry's `comment`, which is the only place HAR has
/// for them.
public struct HARImporter: Sendable {
    /// What went wrong reading a file.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// The bytes are not JSON, or not an object.
        case notJSON
        /// The JSON is not a HAR log: no `log.entries` array.
        case notHAR
        /// The `log.version` is a major version this reader does not understand.
        case unsupportedVersion(String)

        public var description: String {
            switch self {
            case .notJSON: "The file is not JSON."
            case .notHAR: "The file is JSON, but not a HAR log: it has no log.entries."
            case let .unsupportedVersion(version): "HAR version \(version) is not supported; this reader handles 1.x."
            }
        }
    }

    /// Creates an importer.
    public init() {}

    /// Reads records from HAR 1.2 JSON.
    ///
    /// Entries are returned in file order, which is the order they were recorded.
    ///
    /// - Throws: ``Failure`` when the bytes are not a HAR log this reader understands. A single
    ///   malformed entry is skipped rather than failing the whole file — a partial trace still
    ///   answers questions, and a support artifact is often truncated.
    public func `import`(_ data: Data) throws -> [RequestDiagnostic] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSON
        }
        guard let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] else {
            throw Failure.notHAR
        }
        if let version = log["version"] as? String, !version.hasPrefix("1.") {
            throw Failure.unsupportedVersion(version)
        }

        return entries.compactMap(Self.record(from:))
    }

    // MARK: - Entries

    private static func record(from entry: [String: Any]) -> RequestDiagnostic? {
        guard let request = entry["request"] as? [String: Any],
              let url = request["url"] as? String
        else { return nil }

        let method = request["method"] as? String ?? "GET"
        let response = entry["response"] as? [String: Any] ?? [:]
        let duration = (entry["time"] as? Double).flatMap { $0 >= 0 ? $0 : nil }
        let started = (entry["startedDateTime"] as? String).flatMap(date(from:))
        let notes = Notes(comment: entry["comment"] as? String)

        let requestHeaders = headers(from: request["headers"])
        let responseHeaders = headers(from: response["headers"])

        return RequestDiagnostic(
            key: url,
            method: method,
            url: url,
            startedAt: started,
            endedAt: started.flatMap { start in duration.map { start.addingTimeInterval($0 / 1000) } },
            durationMilliseconds: duration,
            attempts: attempts(startingAt: started, notes: notes),
            outcome: outcome(from: response),
            wasCoalesced: notes.wasCoalesced,
            cacheOutcome: notes.cacheOutcome,
            requestHeaders: requestHeaders,
            responseHeaders: responseHeaders,
            requestBody: requestBody(from: request),
            responseBody: responseBody(from: response, isTruncated: notes.responseBodyWasTruncated)
        )
    }

    /// HAR records one exchange, so attempts beyond the first have no timestamps of their own.
    ///
    /// Rather than invent them, a retried request comes back as one attempt per try, all stamped at
    /// the request's start: the count is real, the spacing is not, and a waterfall drawn from it
    /// shows the attempts without claiming to know when each one ran.
    private static func attempts(startingAt start: Date?, notes: Notes) -> [RequestDiagnostic.Attempt] {
        guard let start else { return [] }
        let count = max(notes.attemptCount ?? 1, 1)
        return (1...count).map { number in
            RequestDiagnostic.Attempt(
                number: number,
                startedAt: start,
                retryReason: number > 1 ? notes.retryReason : nil
            )
        }
    }

    private static func outcome(from response: [String: Any]) -> RequestDiagnostic.Outcome {
        let status = response["status"] as? Int ?? 0
        let statusText = response["statusText"] as? String ?? ""

        guard status <= 0 else { return .completed(status: status) }
        if statusText == "In flight" { return .inFlight }
        if statusText.hasPrefix("Cancelled: ") {
            return .cancelled(reason: String(statusText.dropFirst("Cancelled: ".count)))
        }
        // A status of zero with no explanation is how most tools record "it never completed".
        return .failed(reason: statusText.isEmpty ? "The request did not complete." : statusText, status: nil)
    }

    private static func headers(from value: Any?) -> [String: String] {
        guard let entries = value as? [[String: Any]] else { return [:] }
        return entries.reduce(into: [String: String]()) { headers, entry in
            guard let name = entry["name"] as? String, let value = entry["value"] as? String else { return }
            headers[name] = value
        }
    }

    private static func requestBody(from request: [String: Any]) -> BodySummary? {
        let declaredSize = (request["bodySize"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        guard let postData = request["postData"] as? [String: Any] else {
            return declaredSize.map { BodySummary(byteCount: $0) }
        }
        let captured = (postData["text"] as? String).map { Data($0.utf8) }
        return BodySummary(byteCount: declaredSize ?? captured?.count ?? 0, captured: captured)
    }

    private static func responseBody(from response: [String: Any], isTruncated: Bool) -> BodySummary? {
        guard let content = response["content"] as? [String: Any] else { return nil }
        let size = content["size"] as? Int ?? 0
        let captured = (content["text"] as? String).map { text -> Data in
            (content["encoding"] as? String) == "base64"
                ? Data(base64Encoded: text) ?? Data(text.utf8)
                : Data(text.utf8)
        }
        guard size > 0 || captured != nil else { return nil }
        return BodySummary(byteCount: size, captured: captured, isTruncated: isTruncated)
    }

    // MARK: - Timestamps

    /// HAR only promises an ISO 8601 timestamp, and producers differ on fractional seconds.
    private static func date(from text: String) -> Date? {
        for formatter in [fractionalFormatter, wholeSecondFormatter] {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The first format is exactly what ``HARExporter`` writes; the second is for producers that
    /// leave the milliseconds off.
    private static let fractionalFormatter = formatter(format: "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ")
    private static let wholeSecondFormatter = formatter(format: "yyyy-MM-dd'T'HH:mm:ssZZZZZ")

    private static func formatter(format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}

// MARK: - The comment field

/// What ``HARExporter`` writes into an entry's `comment`, read back out.
///
/// A foreign HAR has no such comment, and then every field here is simply unknown.
private struct Notes {
    var attemptCount: Int?
    var retryReason: String?
    var wasCoalesced = false
    var cacheOutcome: CacheOutcome?
    var responseBodyWasTruncated = false

    init(comment: String?) {
        guard let comment else { return }
        for note in comment.components(separatedBy: "; ") {
            switch note {
            case "coalesced with an in-flight request":
                wasCoalesced = true
            case "cache: served":
                cacheOutcome = .hit(isStale: false, ageMilliseconds: 0)
            case "cache: miss":
                cacheOutcome = .miss
            case "response body truncated by the capture limit":
                responseBodyWasTruncated = true
            default:
                readAttempts(from: note)
            }
        }
    }

    /// `attempts: 3 (503, 503)`
    private mutating func readAttempts(from note: String) {
        guard note.hasPrefix("attempts: ") else { return }
        let body = note.dropFirst("attempts: ".count)
        let count = body.prefix { $0.isNumber }
        attemptCount = Int(count)

        guard let open = body.firstIndex(of: "("), let close = body.lastIndex(of: ")"), open < close else { return }
        let reasons = body[body.index(after: open)..<close]
        retryReason = reasons.components(separatedBy: ", ").first
    }
}
