import Foundation
import NovaNetworkClient
import NovaNetworkCore

/// Why a recorded request cannot be sent again as it was.
public enum ReplayUnavailable: Error, Sendable, Equatable, CustomStringConvertible {
    /// The request had a body, but the capture policy kept only its size.
    case bodyNotCaptured(byteCount: Int)
    /// The body was cut off at the capture limit.
    case bodyTruncated(captured: Int, of: Int)
    /// A query item was redacted, so the URL would send the placeholder instead of the value.
    case urlRedacted
    /// The record's method or URL cannot be turned into a request.
    case invalidRecord

    /// What to do about it, for the panel.
    public var description: String {
        switch self {
        case let .bodyNotCaptured(byteCount):
            "The \(byteCount)-byte body was not captured. Record with a body capture policy to replay it."
        case let .bodyTruncated(captured, total):
            "Only \(captured) of \(total) body bytes were captured."
        case .urlRedacted:
            "A query item in the URL was redacted."
        case .invalidRecord:
            "The record's method or URL is not a valid request."
        }
    }
}

public extension RequestDiagnostic {
    /// The request as a `curl` command, for pasting into a terminal or a bug report.
    ///
    /// It is built from the record, which was redacted when it was made: a redacted header appears
    /// with the placeholder, so whoever runs it knows to supply their own. A body that was captured
    /// in full and is UTF-8 is inlined; any other body is described in a comment.
    ///
    /// ```
    /// curl -X 'POST' 'https://api.example.com/items' \
    ///   -H 'Authorization: <redacted>' \
    ///   -H 'Content-Type: application/json' \
    ///   --data-raw '{"name":"lamp"}'
    /// ```
    func curlCommand() -> String {
        var lines: [String] = []
        let sendsBody = (requestBody?.byteCount ?? 0) > 0
        var first = "curl"
        if method.uppercased() != "GET" || sendsBody {
            first += " -X \(Self.shellQuoted(method.uppercased()))"
        }
        first += " \(Self.shellQuoted(url))"
        lines.append(first)

        for name in requestHeaders.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            lines.append("  -H \(Self.shellQuoted("\(name): \(requestHeaders[name] ?? "")"))")
        }

        var comment: String?
        if let body = requestBody, body.byteCount > 0 {
            if let captured = body.captured, !body.isTruncated {
                if let text = String(data: captured, encoding: .utf8) {
                    lines.append("  --data-raw \(Self.shellQuoted(text))")
                } else {
                    lines.append("  --data-binary @body.bin")
                    comment = "# body.bin: the \(body.byteCount)-byte binary body, which is not inlined"
                }
            } else if body.isTruncated {
                comment = "# body truncated: \(body.captured?.count ?? 0) of \(body.byteCount) bytes were captured"
            } else {
                comment = "# body not captured: \(body.byteCount) bytes"
            }
        }

        let command = lines.joined(separator: " \\\n")
        return comment.map { "\($0)\n\(command)" } ?? command
    }

    /// The request rebuilt from the record, for sending again.
    ///
    /// Headers whose value is the redaction placeholder are left out, so the app's middleware adds a
    /// fresh value — a recorded token would be expired by now anyway.
    ///
    /// - Parameter redactionPlaceholder: What the recorder wrote in place of redacted values.
    /// - Returns: The request, or why it cannot be rebuilt without guessing.
    func replayRequest(
        redactionPlaceholder: String = DiagnosticsRedaction.default.placeholder
    ) -> Result<APIRequest, ReplayUnavailable> {
        guard let method = URLMethod(rawValue: method.uppercased()), let url = URL(string: url) else {
            return .failure(.invalidRecord)
        }
        if self.url.contains(redactionPlaceholder)
            || self.url.contains(redactionPlaceholder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? redactionPlaceholder) {
            return .failure(.urlRedacted)
        }

        var body: Data?
        if let summary = requestBody {
            if summary.isTruncated {
                return .failure(.bodyTruncated(captured: summary.captured?.count ?? 0, of: summary.byteCount))
            }
            if let captured = summary.captured {
                body = captured
            } else if summary.byteCount > 0 {
                return .failure(.bodyNotCaptured(byteCount: summary.byteCount))
            } else {
                body = Data()
            }
        }

        let headers = requestHeaders.filter { $0.value != redactionPlaceholder }
        return .success(APIRequest(method: method, url: url, headers: headers, body: body))
    }

    /// Wraps a value in single quotes for a POSIX shell, closing and reopening around any quote it
    /// contains: `it's` becomes `'it'\''s'`.
    internal static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

public extension NetworkClient {
    /// Sends a recorded request again.
    ///
    /// It goes out uncoalesced and past the cache, so it reaches the server whatever else is in
    /// flight. Redacted headers are left out for the client's middleware to fill in. With a recorder
    /// installed, the replay is recorded as a request of its own.
    ///
    /// - Throws: ``ReplayUnavailable`` when the record cannot be rebuilt, or the request's error.
    @discardableResult
    func replay(
        _ record: RequestDiagnostic,
        authScope: String? = nil,
        redactionPlaceholder: String = DiagnosticsRedaction.default.placeholder
    ) async throws -> Data {
        let request = try record.replayRequest(redactionPlaceholder: redactionPlaceholder).get()
        return try await load(
            request: request,
            authScope: authScope,
            cachePolicy: .networkOnly,
            options: RequestExecutionOptions(coalescingMode: .disabled)
        )
    }
}
