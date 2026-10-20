import Foundation
import Testing
import NovaNetworkCore
@testable import NovaNetworkCassette

// Requirements: FR-HARCAS-1…6, EC-HARCAS-1…2 (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §H).
// Tests: T-25.1…T-25.5. T-25.6 (the round trip through HARExporter) is in NovaNetworkDiagnosticsTests.

/// A HAR log around the given entries, as JSON bytes.
private func har(_ entries: [[String: Any]], version: String = "1.2") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["log": ["version": version, "creator": ["name": "t", "version": "1"], "entries": entries]])
}

private func entry(
    method: String = "GET",
    url: String = "https://api.example.com/items?page=1",
    requestHeaders: [[String: String]] = [],
    postData: String? = nil,
    status: Int = 200,
    responseHeaders: [[String: String]] = [["name": "Content-Type", "value": "application/json"]],
    content: [String: Any] = ["size": 13, "mimeType": "application/json", "text": #"{"items":[1]}"#],
    comment: String? = nil
) -> [String: Any] {
    var request: [String: Any] = ["method": method, "url": url, "headers": requestHeaders]
    if let postData { request["postData"] = ["mimeType": "application/json", "text": postData] }
    var result: [String: Any] = [
        "request": request,
        "response": ["status": status, "headers": responseHeaders, "content": content],
    ]
    if let comment { result["comment"] = comment }
    return result
}

@Suite
struct CassetteFromHARTests {
    @Test // T-25.1
    func eachEntryBecomesAnInteractionInFileOrder() throws {
        let conversion = try Cassette.fromHAR(har([
            entry(),
            entry(
                method: "post",
                url: "https://api.example.com/items",
                requestHeaders: [["name": "Accept", "value": "a/b"], ["name": "accept", "value": "c/d"]],
                postData: #"{"name":"lamp"}"#,
                status: 201,
                content: ["size": 4, "mimeType": "application/octet-stream", "text": Data([0, 1, 2, 3]).base64EncodedString(), "encoding": "base64"]
            ),
        ]))

        #expect(conversion.skipped.isEmpty)
        let interactions = conversion.cassette.interactions
        #expect(interactions.count == 2)
        #expect(interactions[0].request == RecordedRequest(method: "GET", url: "https://api.example.com/items?page=1"))
        #expect(interactions[0].response == RecordedResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: RecordedBody(data: Data(#"{"items":[1]}"#.utf8))
        ))
        #expect(interactions[1].request.method == "POST")
        #expect(interactions[1].request.headers == ["Accept": "a/b, c/d"])
        #expect(interactions[1].request.body?.text == #"{"name":"lamp"}"#)
        #expect(interactions[1].response.status == 201)
        #expect(interactions[1].response.body?.data == Data([0, 1, 2, 3]))
    }

    @Test // T-25.2
    func secretsInTheHARNeverReachTheCassette() throws {
        let redaction = CassetteRedaction.default
            .redacting(queryItems: "token")
            .redactingBodies { _ in Data("<body redacted>".utf8) }
        let conversion = try Cassette.fromHAR(
            har([entry(
                url: "https://api.example.com/me?token=s3cret&page=1",
                requestHeaders: [["name": "authorization", "value": "Bearer s3cret"], ["name": "Cookie", "value": "sid=s3cret"]],
                postData: #"{"password":"s3cret"}"#,
                responseHeaders: [["name": "Set-Cookie", "value": "sid=s3cret"]]
            )]),
            redaction: redaction
        )

        let serialized = String(decoding: try conversion.cassette.serialized(), as: UTF8.self)
        #expect(!serialized.contains("s3cret"))
        let interaction = try #require(conversion.cassette.interactions.first)
        #expect(interaction.request.headers == ["authorization": "<redacted>", "Cookie": "<redacted>"])
        #expect(interaction.response.headers == ["Set-Cookie": "<redacted>"])
        #expect(interaction.request.url.contains("token=%3Credacted%3E") || interaction.request.url.contains("token=<redacted>"))
        #expect(interaction.response.body?.text == "<body redacted>")
    }

    @Test // T-25.3
    func entriesThatWouldNotReplayFaithfullyAreSkippedWithTheirReason() throws {
        let conversion = try Cassette.fromHAR(
            har([
                ["request": ["method": "GET"]],
                entry(url: "https://cdn.example.com/logo.png"),
                entry(url: "https://api.example.com/aborted", status: 0),
                entry(url: "https://api.example.com/sizeonly", content: ["size": 512, "mimeType": "application/json"]),
                entry(url: "https://api.example.com/cut", comment: "attempts: 1; response body truncated by the capture limit"),
                entry(url: "https://api.example.com/badbase64", content: ["size": 3, "text": "***", "encoding": "base64"]),
                entry(url: "https://api.example.com/empty", status: 204, content: ["size": 0, "mimeType": ""]),
                entry(url: "https://api.example.com/emptytext", status: 200, content: ["size": 0, "text": ""]),
            ]),
            include: { _, url in url.host == "api.example.com" }
        )

        #expect(conversion.skipped == [
            SkippedHAREntry(index: 0, url: nil, reason: .malformed),
            SkippedHAREntry(index: 1, url: "https://cdn.example.com/logo.png", reason: .filteredOut),
            SkippedHAREntry(index: 2, url: "https://api.example.com/aborted", reason: .aborted),
            SkippedHAREntry(index: 3, url: "https://api.example.com/sizeonly", reason: .bodyNotCaptured),
            SkippedHAREntry(index: 4, url: "https://api.example.com/cut", reason: .bodyTruncated),
            SkippedHAREntry(index: 5, url: "https://api.example.com/badbase64", reason: .bodyNotCaptured),
        ])
        #expect(conversion.cassette.interactions.map(\.request.url) == ["https://api.example.com/empty", "https://api.example.com/emptytext"])
        #expect(conversion.cassette.interactions.allSatisfy { $0.response.body == nil })
    }

    @Test // T-25.4
    func headersThatDescribeTheWireRatherThanTheBodyAreDropped() throws {
        let conversion = try Cassette.fromHAR(har([entry(
            requestHeaders: [[":authority": "x", "name": ":authority", "value": "api.example.com"], ["name": "Accept", "value": "*/*"]],
            responseHeaders: [
                ["name": "content-encoding", "value": "br"],
                ["name": "Content-Length", "value": "4"],
                ["name": "Content-Type", "value": "application/json"],
                ["name": "broken"],
            ]
        )]))

        let interaction = try #require(conversion.cassette.interactions.first)
        #expect(interaction.request.headers == ["Accept": "*/*"])
        #expect(interaction.response.headers == ["Content-Type": "application/json"])
    }

    @Test // T-25.5
    func aFileThatIsNotAHAR1LogIsRefused() throws {
        #expect(throws: HARConversionError.notJSON) { try Cassette.fromHAR(Data("nope".utf8)) }
        #expect(throws: HARConversionError.notHAR) { try Cassette.fromHAR(Data(#"{"log":{}}"#.utf8)) }
        #expect(throws: HARConversionError.unsupportedVersion("2.0")) { try Cassette.fromHAR(har([], version: "2.0")) }
        #expect(try Cassette.fromHAR(har([])).cassette.interactions.isEmpty)
        for error in [HARConversionError.notJSON, .notHAR, .unsupportedVersion("2.0")] {
            #expect(!error.description.isEmpty)
        }
    }
}
