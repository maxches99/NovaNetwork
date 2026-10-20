import Foundation

/// Why a HAR file could not be read at all.
public enum HARConversionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The bytes are not a JSON object.
    case notJSON
    /// The JSON has no `log.entries` array.
    case notHAR
    /// The `log.version` is a major version other than 1.
    case unsupportedVersion(String)

    /// What went wrong, for a log or an error message.
    public var description: String {
        switch self {
        case .notJSON: "The file is not JSON."
        case .notHAR: "The file is JSON, but not a HAR log: it has no log.entries."
        case let .unsupportedVersion(version): "HAR version \(version) is not supported; this reader handles 1.x."
        }
    }
}

/// A HAR entry that did not become an interaction, and why.
public struct SkippedHAREntry: Sendable, Equatable {
    /// Why an entry was left out.
    public enum Reason: String, Sendable, Equatable {
        /// The entry has no request, URL, or response status.
        case malformed
        /// The request never completed: HAR records status `0` for an aborted or blocked request.
        case aborted
        /// The response had a body, but the HAR kept only its size.
        case bodyNotCaptured = "body_not_captured"
        /// The body was cut off at a capture limit.
        case bodyTruncated = "body_truncated"
        /// The `include` filter left it out.
        case filteredOut = "filtered_out"
    }

    /// The entry's position in `log.entries`.
    public let index: Int
    /// The entry's URL, when it had one.
    public let url: String?
    /// Why it was left out.
    public let reason: Reason

    /// Creates a skipped-entry record.
    public init(index: Int, url: String?, reason: Reason) {
        self.index = index
        self.url = url
        self.reason = reason
    }
}

/// A cassette made from a HAR, and the entries that could not be part of it.
public struct HARConversion: Sendable, Equatable {
    /// The interactions that can be replayed faithfully, in file order.
    public let cassette: Cassette
    /// The entries left out, with the reason for each.
    public let skipped: [SkippedHAREntry]
}

public extension Cassette {
    /// Makes a cassette from a HAR 1.x file, so traffic captured on someone else's device replays in
    /// a test.
    ///
    /// ```swift
    /// let conversion = try Cassette.fromHAR(
    ///     Data(contentsOf: harURL),
    ///     include: { _, url in url.host == "api.example.com" }
    /// )
    /// try conversion.cassette.write(to: cassetteURL)
    /// for entry in conversion.skipped { print(entry.index, entry.url ?? "", entry.reason) }
    /// ```
    ///
    /// Any producer works: `HARExporter`, Safari, Chrome, Charles, Proxyman. Redaction runs before
    /// anything reaches the cassette — browsers export cookies and authorization headers verbatim.
    /// An entry that would not replay faithfully (aborted, or with a body the HAR did not keep) is
    /// skipped and listed rather than recorded wrong. `Content-Encoding` and `Content-Length` are
    /// dropped, because HAR stores the decoded body they no longer describe, and so are HTTP/2
    /// pseudo-headers.
    ///
    /// - Parameters:
    ///   - har: The HAR file's bytes.
    ///   - redaction: What to strip. Defaults to the cassette's default policy.
    ///   - include: Which requests to keep, by method and URL. Defaults to all of them.
    /// - Throws: ``HARConversionError`` when the bytes are not a HAR 1.x log.
    static func fromHAR(
        _ har: Data,
        redaction: CassetteRedaction = .default,
        include: (@Sendable (_ method: String, _ url: URL) -> Bool)? = nil
    ) throws -> HARConversion {
        guard let root = try? JSONSerialization.jsonObject(with: har) as? [String: Any] else {
            throw HARConversionError.notJSON
        }
        guard let log = root["log"] as? [String: Any], let entries = log["entries"] as? [[String: Any]] else {
            throw HARConversionError.notHAR
        }
        if let version = log["version"] as? String, !version.hasPrefix("1.") {
            throw HARConversionError.unsupportedVersion(version)
        }

        var interactions: [RecordedInteraction] = []
        var skipped: [SkippedHAREntry] = []
        for (index, entry) in entries.enumerated() {
            switch HAREntry.interaction(from: entry, redaction: redaction, include: include) {
            case let .success(interaction):
                interactions.append(interaction)
            case let .failure(skip):
                skipped.append(SkippedHAREntry(index: index, url: skip.url, reason: skip.reason))
            }
        }
        return HARConversion(cassette: Cassette(interactions: interactions), skipped: skipped)
    }
}

/// Reads one HAR entry. A namespace, so the parsing helpers stay out of `Cassette`.
private enum HAREntry {
    struct Skip: Error {
        let url: String?
        let reason: SkippedHAREntry.Reason
    }

    /// Headers that describe the original bytes on the wire rather than the body HAR kept.
    private static let staleHeaders: Set<String> = ["content-encoding", "content-length"]

    static func interaction(
        from entry: [String: Any],
        redaction: CassetteRedaction,
        include: (@Sendable (String, URL) -> Bool)?
    ) -> Result<RecordedInteraction, Skip> {
        guard let request = entry["request"] as? [String: Any],
              let urlString = request["url"] as? String,
              let url = URL(string: urlString),
              let response = entry["response"] as? [String: Any],
              let status = integer(response["status"])
        else {
            let url = (entry["request"] as? [String: Any])?["url"] as? String
            return .failure(Skip(url: url, reason: .malformed))
        }
        let method = (request["method"] as? String ?? "GET").uppercased()

        if let include, !include(method, url) {
            return .failure(Skip(url: urlString, reason: .filteredOut))
        }
        if status <= 0 {
            return .failure(Skip(url: urlString, reason: .aborted))
        }
        if let comment = entry["comment"] as? String, comment.contains("truncated") {
            return .failure(Skip(url: urlString, reason: .bodyTruncated))
        }

        let responseBody: Data?
        switch self.responseBody(response["content"] as? [String: Any]) {
        case let .success(body): responseBody = body
        case .failure: return .failure(Skip(url: urlString, reason: .bodyNotCaptured))
        }
        let requestBody = ((request["postData"] as? [String: Any])?["text"] as? String).map { Data($0.utf8) }

        return .success(
            RecordedInteraction(
                request: RecordedRequest(
                    method: method,
                    url: redaction.redacted(url: urlString),
                    headers: redaction.redacted(headers: headers(request["headers"])),
                    body: redaction.redacted(body: requestBody).map(RecordedBody.init(data:))
                ),
                response: RecordedResponse(
                    status: status,
                    headers: redaction.redacted(headers: headers(response["headers"])),
                    body: redaction.redacted(body: responseBody).map(RecordedBody.init(data:))
                )
            )
        )
    }

    private struct NotCaptured: Error {}

    /// The response body HAR kept, `nil` for an empty one, or a failure when it kept only the size.
    private static func responseBody(_ content: [String: Any]?) -> Result<Data?, NotCaptured> {
        guard let content else { return .success(nil) }
        guard let text = content["text"] as? String else {
            let size = integer(content["size"]) ?? 0
            return size > 0 ? .failure(NotCaptured()) : .success(nil)
        }
        if (content["encoding"] as? String)?.lowercased() == "base64" {
            guard let decoded = Data(base64Encoded: text) else { return .failure(NotCaptured()) }
            return .success(decoded.isEmpty ? nil : decoded)
        }
        return .success(text.isEmpty ? nil : Data(text.utf8))
    }

    /// A JSON number as an integer, whichever type `JSONSerialization` chose for it on this platform.
    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: int
        case let double as Double: Int(exactly: double.rounded())
        case let number as NSNumber: number.intValue
        default: nil
        }
    }

    /// HAR's `[{name, value}]` list as a dictionary, joining repeated names as HTTP allows.
    private static func headers(_ value: Any?) -> [String: String] {
        guard let list = value as? [[String: Any]] else { return [:] }
        var result: [String: String] = [:]
        for header in list {
            guard let name = header["name"] as? String, let value = header["value"] as? String else { continue }
            if name.hasPrefix(":") || staleHeaders.contains(name.lowercased()) { continue }
            if let existing = result.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame }) {
                result[existing.key] = "\(existing.value), \(value)"
            } else {
                result[name] = value
            }
        }
        return result
    }
}
