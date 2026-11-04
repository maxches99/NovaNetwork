import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkDiagnostics

// Requirements: FR-CURL-1…5, EC-CURL-1…2 (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §G).
// Tests: T-24.1…T-24.5.

private func record(
    method: String = "POST",
    url: String = "https://api.example.com/items?page=2",
    headers: [String: String] = ["Content-Type": "application/json", "Authorization": "<redacted>"],
    body: BodySummary? = BodySummary(byteCount: 15, captured: Data(#"{"name":"lamp"}"#.utf8))
) -> RequestDiagnostic {
    RequestDiagnostic(key: "k", method: method, url: url, requestHeaders: headers, requestBody: body)
}

@Suite
struct CurlCommandTests {
    @Test // T-24.1
    func aRecordBecomesARunnableCommandWithEveryArgumentQuoted() {
        #expect(record().curlCommand() == """
        curl -X 'POST' 'https://api.example.com/items?page=2' \\
          -H 'Authorization: <redacted>' \\
          -H 'Content-Type: application/json' \\
          --data-raw '{"name":"lamp"}'
        """)

        // A plain GET says only what it is.
        #expect(record(method: "GET", url: "https://api.example.com/items", headers: [:], body: nil).curlCommand()
            == "curl 'https://api.example.com/items'")

        // A quote inside a value is closed, escaped, and reopened.
        let quoted = record(headers: ["X-Note": "it's"], body: BodySummary(byteCount: 9, captured: Data("O'Reilly!".utf8)))
        #expect(quoted.curlCommand() == """
        curl -X 'POST' 'https://api.example.com/items?page=2' \\
          -H 'X-Note: it'\\''s' \\
          --data-raw 'O'\\''Reilly!'
        """)
        #expect(RequestDiagnostic.shellQuoted("a'b'c") == #"'a'\''b'\''c'"#)
    }

    @Test // T-24.2
    func aBodyThatCannotBeInlinedIsDescribedInstead() {
        let binary = record(headers: [:], body: BodySummary(byteCount: 3, captured: Data([0xff, 0xfe, 0x00])))
        #expect(binary.curlCommand() == """
        # body.bin: the 3-byte binary body, which is not inlined
        curl -X 'POST' 'https://api.example.com/items?page=2' \\
          --data-binary @body.bin
        """)

        let truncated = record(headers: [:], body: BodySummary(byteCount: 10_000, captured: Data(count: 4_096), isTruncated: true))
        #expect(truncated.curlCommand().hasPrefix("# body truncated: 4096 of 10000 bytes were captured\ncurl -X 'POST'"))

        let sizeOnly = record(headers: [:], body: BodySummary(byteCount: 120))
        #expect(sizeOnly.curlCommand().hasPrefix("# body not captured: 120 bytes\n"))
    }
}

@Suite
struct ReplayRequestTests {
    @Test // T-24.3
    func theRequestIsRebuiltWithoutTheHeadersThatWereRedacted() throws {
        let request = try record().replayRequest().get()

        #expect(request.method == .post)
        #expect(request.url.absoluteString == "https://api.example.com/items?page=2")
        #expect(request.headers == ["Content-Type": "application/json"])
        #expect(request.body == Data(#"{"name":"lamp"}"#.utf8))

        // No body recorded: none sent. An empty body recorded: an empty body sent.
        #expect(try record(method: "get", body: nil).replayRequest().get().body == nil)
        #expect(try record(body: BodySummary(byteCount: 0)).replayRequest().get().body == Data())

        // A custom placeholder is honoured.
        let custom = try record(headers: ["Authorization": "***"]).replayRequest(redactionPlaceholder: "***").get()
        #expect(custom.headers.isEmpty)
    }

    @Test // T-24.4
    func aRecordThatCannotBeSentAsItWasSaysWhy() {
        func problem(_ record: RequestDiagnostic) -> ReplayUnavailable? {
            guard case let .failure(reason) = record.replayRequest() else { return nil }
            return reason
        }

        #expect(problem(record(body: BodySummary(byteCount: 40))) == .bodyNotCaptured(byteCount: 40))
        #expect(problem(record(body: BodySummary(byteCount: 40, captured: Data(count: 8), isTruncated: true)))
            == .bodyTruncated(captured: 8, of: 40))
        #expect(problem(record(url: "https://api.example.com/items?token=%3Credacted%3E")) == .urlRedacted)
        #expect(problem(record(method: "BREW")) == .invalidRecord)
        #expect(problem(record(url: "")) == .invalidRecord)

        for reason in [ReplayUnavailable.bodyNotCaptured(byteCount: 1), .bodyTruncated(captured: 1, of: 2), .urlRedacted, .invalidRecord] {
            #expect(!reason.description.isEmpty)
        }
    }
}

private actor CountingEcho: NetworkTransport {
    private(set) var received: [APIRequest] = []

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        received.append(request)
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok \(received.count)".utf8))
    }
}

@Suite
struct ReplayThroughTheClientTests {
    @Test // T-24.5
    func aReplayReachesTheServerEveryTimeAndTheMiddlewareSuppliesFreshCredentials() async throws {
        let transport = CountingEcho()
        let recorder = DiagnosticsRecorder()
        var configuration = NetworkClientConfiguration()
        configuration.transport = transport
        configuration.defaultCachePolicy = .cacheFirst(maxAge: 600)
        configuration.telemetryHooks = recorder.hooks
        configuration.middlewares = [
            NetworkMiddleware(beforeSend: { request, _ in request.withMergedHeaders(["Authorization": "Bearer fresh"]) }),
        ]
        let client = NetworkClient(configuration: configuration)

        let original = record(method: "GET", url: "https://api.example.com/items", body: nil)
        #expect(String(decoding: try await client.replay(original), as: UTF8.self) == "ok 1")
        #expect(String(decoding: try await client.replay(original), as: UTF8.self) == "ok 2")

        let sent = await transport.received
        #expect(sent.count == 2)
        #expect(sent.first?.headers["Authorization"] == "Bearer fresh")
        try await waitUntil("the replays are recorded") { await recorder.snapshot().count == 2 }

        await #expect(throws: ReplayUnavailable.bodyNotCaptured(byteCount: 40)) {
            try await client.replay(record(body: BodySummary(byteCount: 40)))
        }
    }
}
