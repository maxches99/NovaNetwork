import Foundation

/// Writes records as a HAR 1.2 log.
///
/// HAR because it is already understood: every browser's network inspector, Charles, and Proxyman
/// read it, so a support artifact needs no new viewer and no explanation beyond "open this".
public struct HARExporter: Sendable {
    /// Name recorded as the log's creator.
    public let creatorName: String
    /// Version recorded as the log's creator version.
    public let creatorVersion: String

    /// Creates an exporter.
    public init(creatorName: String = "NovaNetworkDiagnostics", creatorVersion: String = "2.13") {
        self.creatorName = creatorName
        self.creatorVersion = creatorVersion
    }

    /// Exports records as HAR 1.2 JSON.
    ///
    /// Records with no observed start time are dated from their end, or from the Unix epoch when
    /// neither is known — a HAR entry requires a timestamp, and inventing "now" at export time would
    /// misrepresent when the request actually ran.
    public func export(_ records: [RequestDiagnostic]) throws -> Data {
        let log = HARLog(
            log: HARLogBody(
                version: "1.2",
                creator: HARCreator(name: creatorName, version: creatorVersion),
                entries: records.map(entry(for:))
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(log)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    // MARK: - Entry construction

    private func entry(for record: RequestDiagnostic) -> HAREntry {
        let started = record.startedAt ?? record.endedAt ?? Date(timeIntervalSince1970: 0)
        let time = record.durationMilliseconds ?? 0

        return HAREntry(
            startedDateTime: Self.timestampFormatter.string(from: started),
            time: time,
            request: HARRequest(
                method: record.method,
                url: record.url,
                httpVersion: "HTTP/1.1",
                cookies: [],
                headers: Self.headers(record.requestHeaders),
                queryString: Self.queryItems(from: record.url),
                postData: Self.postData(record.requestBody, contentType: record.requestHeaders["Content-Type"]),
                headersSize: -1,
                bodySize: record.requestBody?.byteCount ?? 0
            ),
            response: HARResponse(
                status: record.status ?? 0,
                statusText: Self.statusText(for: record),
                httpVersion: "HTTP/1.1",
                cookies: [],
                headers: Self.headers(record.responseHeaders),
                content: Self.content(record.responseBody, contentType: record.responseHeaders["Content-Type"]),
                redirectURL: "",
                headersSize: -1,
                bodySize: record.responseBody?.byteCount ?? 0
            ),
            cache: HARCache(),
            timings: HARTimings(send: 0, wait: time, receive: 0),
            comment: Self.comment(for: record)
        )
    }

    /// A comment carrying what HAR has no field for: attempts, coalescing, and the cache outcome.
    private static func comment(for record: RequestDiagnostic) -> String? {
        var notes: [String] = []
        if record.wasRetried {
            let reasons = record.attempts.compactMap(\.retryReason).joined(separator: ", ")
            notes.append("attempts: \(record.attemptCount)\(reasons.isEmpty ? "" : " (\(reasons))")")
        }
        if record.wasCoalesced {
            notes.append("coalesced with an in-flight request")
        }
        if let cache = record.cacheOutcome {
            notes.append("cache: \(cache.servedFromCache ? "served" : "miss")")
        }
        if record.responseBody?.isTruncated == true {
            notes.append("response body truncated by the capture limit")
        }
        return notes.isEmpty ? nil : notes.joined(separator: "; ")
    }

    private static func statusText(for record: RequestDiagnostic) -> String {
        switch record.outcome {
        case let .completed(status): status < 400 ? "OK" : "HTTP \(status)"
        case let .failed(reason, _): reason
        case let .cancelled(reason): "Cancelled: \(reason)"
        case .inFlight: "In flight"
        }
    }

    private static func headers(_ headers: [String: String]) -> [HARNameValue] {
        headers
            .map { HARNameValue(name: $0.key, value: $0.value) }
            .sorted { $0.name < $1.name }
    }

    private static func queryItems(from url: String) -> [HARNameValue] {
        (URLComponents(string: url)?.queryItems ?? [])
            .map { HARNameValue(name: $0.name, value: $0.value ?? "") }
    }

    private static func postData(_ body: BodySummary?, contentType: String?) -> HARPostData? {
        guard let body, let captured = body.captured else { return nil }
        return HARPostData(
            mimeType: contentType ?? "application/octet-stream",
            text: String(data: captured, encoding: .utf8) ?? captured.base64EncodedString()
        )
    }

    private static func content(_ body: BodySummary?, contentType: String?) -> HARContent {
        guard let body else {
            return HARContent(size: 0, mimeType: contentType ?? "", text: nil, encoding: nil)
        }
        guard let captured = body.captured else {
            return HARContent(size: body.byteCount, mimeType: contentType ?? "", text: nil, encoding: nil)
        }
        if let text = String(data: captured, encoding: .utf8) {
            return HARContent(size: body.byteCount, mimeType: contentType ?? "", text: text, encoding: nil)
        }
        return HARContent(
            size: body.byteCount,
            mimeType: contentType ?? "application/octet-stream",
            text: captured.base64EncodedString(),
            encoding: "base64"
        )
    }

    /// RFC 3339 with milliseconds, which is what HAR's `startedDateTime` expects.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        return formatter
    }()
}

// MARK: - HAR 1.2 shapes

struct HARLog: Codable {
    let log: HARLogBody
}

struct HARLogBody: Codable {
    let version: String
    let creator: HARCreator
    let entries: [HAREntry]
}

struct HARCreator: Codable {
    let name: String
    let version: String
}

struct HAREntry: Codable {
    let startedDateTime: String
    let time: Double
    let request: HARRequest
    let response: HARResponse
    let cache: HARCache
    let timings: HARTimings
    let comment: String?
}

struct HARRequest: Codable {
    let method: String
    let url: String
    let httpVersion: String
    let cookies: [HARNameValue]
    let headers: [HARNameValue]
    let queryString: [HARNameValue]
    let postData: HARPostData?
    let headersSize: Int
    let bodySize: Int
}

struct HARResponse: Codable {
    let status: Int
    let statusText: String
    let httpVersion: String
    let cookies: [HARNameValue]
    let headers: [HARNameValue]
    let content: HARContent
    let redirectURL: String
    let headersSize: Int
    let bodySize: Int
}

struct HARNameValue: Codable {
    let name: String
    let value: String
}

struct HARPostData: Codable {
    let mimeType: String
    let text: String
}

struct HARContent: Codable {
    let size: Int
    let mimeType: String
    let text: String?
    let encoding: String?
}

struct HARCache: Codable {}

struct HARTimings: Codable {
    let send: Double
    let wait: Double
    let receive: Double
}
