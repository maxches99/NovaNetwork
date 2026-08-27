import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkCassette

// Requirements: FR-9/DR-2 (redaction at record time), FR-11 (withCassette scope), AR-1 (unchanged
// client behavior), EC-6 (concurrent access), EC-8 (replaying redacted recordings).
// Tests: T-7.1, T-7.2, T-9.1, T-10.1, T-11.1.

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nova-cassette-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("cassette.json")
}

private func json(_ text: String, headers: [String: String] = [:], status: Int = 200) -> NetworkResponse {
    NetworkResponse(
        statusCode: status,
        headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
        body: Data(text.utf8)
    )
}

private struct User: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

// MARK: - T-7.x redaction

@Suite
struct CassetteRedactionTests {
    @Test
    func credentialHeadersNeverReachTheRecording() async throws {
        let upstream = ScriptedUpstream(responses: [json(#"{"id":1,"name":"Ada"}"#, headers: ["Set-Cookie": "session=super-secret"])])
        let transport = CassetteTransport(mode: .record, upstream: upstream)

        _ = try await transport.execute(
            APIRequest(
                method: .get,
                url: URL(string: "https://api.example.com/me")!,
                headers: ["Authorization": "Bearer super-secret-token", "Accept": "application/json"]
            )
        )

        let cassette = await transport.cassette
        let serialized = try String(decoding: cassette.serialized(), as: UTF8.self)

        #expect(cassette.interactions[0].request.headers["Authorization"] == "<redacted>")
        #expect(cassette.interactions[0].response.headers["Set-Cookie"] == "<redacted>")
        #expect(cassette.interactions[0].request.headers["Accept"] == "application/json")
        #expect(!serialized.contains("super-secret-token"))
        #expect(!serialized.contains("super-secret"))
    }

    @Test
    func theDefaultPolicyCoversTheHeadersThatUsuallyCarryCredentials() {
        let policy = CassetteRedaction.default

        for name in ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie", "X-API-Key", "X-Auth-Token"] {
            #expect(policy.redactsHeader(named: name), "\(name) should be redacted by default")
            #expect(policy.redactsHeader(named: name.lowercased()), "\(name) should match case-insensitively")
        }
        #expect(!policy.redactsHeader(named: "Accept"))
        #expect(CassetteRedaction.none.redactsHeader(named: "Authorization") == false)
    }

    @Test
    func queryItemsAndBodiesCanBeRedactedToo() async throws {
        let upstream = ScriptedUpstream(responses: [json(#"{"token":"live-token"}"#)])
        let redaction = CassetteRedaction.default
            .redacting(queryItems: "api_key")
            .redactingBodies { data in
                let text = String(decoding: data, as: UTF8.self)
                    .replacingOccurrences(of: "live-token", with: "<token>")
                return Data(text.utf8)
            }
        let transport = CassetteTransport(mode: .record, upstream: upstream, redaction: redaction)

        _ = try await transport.execute(
            APIRequest(
                method: .get,
                url: URL(string: "https://api.example.com/session")!,
                queryItems: [URLQueryItem(name: "api_key", value: "secret-key"), URLQueryItem(name: "verbose", value: "1")]
            )
        )

        let interaction = try #require(await transport.cassette.interactions.first)
        #expect(interaction.request.url.contains("api_key=%3Credacted%3E") || interaction.request.url.contains("api_key=<redacted>"))
        #expect(interaction.request.url.contains("verbose=1"))
        #expect(interaction.response.body?.text == #"{"token":"<token>"}"#)
    }

    @Test
    func aRedactedRecordingStillReplaysBecauseHeadersAreNotMatchedByDefault() async throws {
        let upstream = ScriptedUpstream(responses: [json(#"{"id":1,"name":"Ada"}"#)])
        let recorder = CassetteTransport(mode: .record, upstream: upstream)
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/me")!,
            headers: ["Authorization": "Bearer first-token"]
        )
        _ = try await recorder.execute(request)

        let player = CassetteTransport(mode: .replay, cassette: await recorder.cassette)
        let replayed = try await player.execute(
            APIRequest(
                method: .get,
                url: URL(string: "https://api.example.com/me")!,
                headers: ["Authorization": "Bearer a-completely-different-token"]
            )
        )

        #expect(String(decoding: replayed.body, as: UTF8.self) == #"{"id":1,"name":"Ada"}"#)
    }
}

// MARK: - T-9.1 the scoped helper

@Suite
struct WithCassetteTests {
    @Test
    func theFirstRunRecordsAndTheSecondRunIsOffline() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let liveUpstream = ScriptedUpstream(responses: [json(#"{"id":1,"name":"Ada"}"#)])
        let recorded: User = try await withCassette(at: url, upstream: liveUpstream) { transport in
            let client = NetworkClient(transport: transport)
            return try await client.load(
                request: APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!),
                authScope: nil
            )
        }

        #expect(recorded == User(id: 1, name: "Ada"))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let offlineUpstream = ScriptedUpstream(failure: CassetteError.fileNotFound(path: "unused"))
        let replayed: User = try await withCassette(at: url, upstream: offlineUpstream) { transport in
            let client = NetworkClient(transport: transport)
            return try await client.load(
                request: APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!),
                authScope: nil
            )
        }

        #expect(replayed == recorded)
        #expect(await offlineUpstream.callCount() == 0)
    }

    @Test
    func anUnchangedCassetteIsNotRewritten() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Deliberately compact, so any rewrite would reformat it and change these bytes.
        let compact = Data(
            #"{"version":1,"interactions":[{"request":{"headers":{},"method":"GET","url":"https://api.example.com/ping"},"response":{"headers":{},"status":200}}]}"#.utf8
        )
        try compact.write(to: url)

        try await withCassette(at: url, mode: .replay) { transport in
            _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://api.example.com/ping")!))
        }

        #expect(try Data(contentsOf: url) == compact)
    }

    @Test
    func aScopeThatThrowsDoesNotLeaveAHalfWrittenCassette() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        struct ScopeFailure: Error {}

        let upstream = ScriptedUpstream(responses: [json(#"{"id":1,"name":"Ada"}"#)])
        await #expect(throws: ScopeFailure.self) {
            try await withCassette(at: url, upstream: upstream) { transport in
                _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!))
                throw ScopeFailure()
            }
        }

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func aMissingCassetteStartsAnEmptyRecordingRatherThanFailing() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let upstream = ScriptedUpstream(responses: [json(#"{"id":9,"name":"Grace"}"#)])
        try await withCassette(at: url, upstream: upstream) { transport in
            _ = try await transport.execute(APIRequest(method: .get, url: URL(string: "https://api.example.com/users/9")!))
        }

        let saved = try Cassette.load(from: url)
        #expect(saved.interactions.count == 1)
    }
}

// MARK: - T-10.1, T-11.1 behavior through the client

@Suite
struct CassetteClientIntegrationTests {
    @Test
    func aReplayedRequestBehavesLikeALiveOneThroughTheClient() async throws {
        let payload = #"{"id":1,"name":"Ada"}"#
        let liveTransport = ScriptedUpstream(responses: [json(payload)])
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)

        let live: User = try await NetworkClient(transport: liveTransport).load(request: request, authScope: nil)

        let recorder = CassetteTransport(mode: .record, upstream: ScriptedUpstream(responses: [json(payload)]))
        _ = try await recorder.execute(request)
        let replayed: User = try await NetworkClient(transport: CassetteTransport(mode: .replay, cassette: await recorder.cassette))
            .load(request: request, authScope: nil)

        #expect(replayed == live)
    }

    @Test
    func coalescingStillSharesOneReplayBetweenConcurrentCallers() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [
                RecordedInteraction(
                    request: RecordedRequest(method: "GET", url: "https://api.example.com/users/1"),
                    response: RecordedResponse(status: 200, body: RecordedBody(data: Data(#"{"id":1,"name":"Ada"}"#.utf8)))
                ),
            ])
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)

        // One recording, two callers: this only works if coalescing shares the single exchange,
        // exactly as it would against a live server.
        async let first: User = client.load(request: request, authScope: nil)
        async let second: User = client.load(request: request, authScope: nil)
        let (left, right) = try await (first, second)

        #expect(left == right)
        #expect(left == User(id: 1, name: "Ada"))
    }

    @Test
    func concurrentRequestsAgainstOneCassetteEachGetTheirOwnRecording() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [
                RecordedInteraction(
                    request: RecordedRequest(method: "GET", url: "https://api.example.com/job"),
                    response: RecordedResponse(status: 200, body: RecordedBody(data: Data("first".utf8)))
                ),
                RecordedInteraction(
                    request: RecordedRequest(method: "GET", url: "https://api.example.com/job"),
                    response: RecordedResponse(status: 200, body: RecordedBody(data: Data("second".utf8)))
                ),
            ])
        )
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/job")!)

        async let left = transport.execute(request)
        async let right = transport.execute(request)
        let bodies = try await [left, right].map { String(decoding: $0.body, as: UTF8.self) }

        #expect(Set(bodies) == ["first", "second"], "each recording is consumed exactly once")
    }
}
