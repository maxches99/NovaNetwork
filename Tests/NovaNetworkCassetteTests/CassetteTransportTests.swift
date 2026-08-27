import Foundation
import Testing
import NovaNetworkCore
@testable import NovaNetworkCassette

// Requirements: FR-3 (replay never contacts upstream), FR-4 (record appends), FR-5 (record-missing),
// FR-6 (match rules), FR-7 (ordered episodes), FR-8 (exhaustion policy), FR-12 (unmatched error).
// Tests: T-3.1, T-3.2, T-3.3, T-4.1, T-4.2, T-5.1, T-6.1, T-6.2, T-6.3, T-6.4.

/// An upstream that answers from a script and counts what it was asked for.
actor ScriptedUpstream: NetworkTransport {
    private var responses: [NetworkResponse]
    private(set) var requests: [APIRequest] = []
    private let failure: (any Error)?

    init(responses: [NetworkResponse] = [], failure: (any Error)? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        requests.append(request)
        if let failure { throw failure }
        guard !responses.isEmpty else {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data())
        }
        return responses.removeFirst()
    }

    func callCount() -> Int { requests.count }
    func recordedRequests() -> [APIRequest] { requests }
}

private struct UpstreamUnavailable: Error {}

private func request(_ path: String, method: URLMethod = .get, query: [URLQueryItem] = [], body: Data? = nil, headers: [String: String] = [:]) -> APIRequest {
    APIRequest(
        method: method,
        url: URL(string: "https://api.example.com\(path)")!,
        queryItems: query,
        headers: headers,
        body: body
    )
}

private func json(_ text: String, status: Int = 200) -> NetworkResponse {
    NetworkResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
}

private func recorded(_ url: String, method: String = "GET", status: Int = 200, body: String = "{}") -> RecordedInteraction {
    RecordedInteraction(
        request: RecordedRequest(method: method, url: url),
        response: RecordedResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: RecordedBody(data: Data(body.utf8))
        )
    )
}

// MARK: - T-3.x replay

@Suite
struct CassetteReplayTests {
    @Test
    func replayServesTheRecordingWithoutContactingTheUpstream() async throws {
        let upstream = ScriptedUpstream(failure: UpstreamUnavailable())
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [recorded("https://api.example.com/users/1", body: #"{"id":1}"#)]),
            upstream: upstream
        )

        let response = try await transport.execute(request("/users/1"))

        #expect(response.statusCode == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"id":1}"#)
        #expect(response.headers["Content-Type"] == "application/json")
        #expect(await upstream.callCount() == 0)
    }

    @Test
    func anUnmatchedRequestNamesItselfAndTheCassetteContents() async {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [recorded("https://api.example.com/users/1")])
        )

        do {
            _ = try await transport.execute(request("/users/2"))
            Issue.record("Expected an unmatched-recording error")
        } catch let error as CassetteError {
            guard case let .noRecordingMatched(method, url, unconsumed, total) = error else {
                Issue.record("Expected .noRecordingMatched, got \(error)")
                return
            }
            #expect(method == "GET")
            #expect(url == "https://api.example.com/users/2")
            #expect(total == 1)
            #expect(unconsumed == 1)
            #expect(error.errorDescription?.contains("GET https://api.example.com/users/2") == true)
        } catch {
            Issue.record("Expected a CassetteError, got \(error)")
        }
    }

    @Test
    func anEmptyCassetteFailsOnTheFirstRequest() async {
        let transport = CassetteTransport(mode: .replay, cassette: Cassette())

        await #expect(throws: CassetteError.self) {
            _ = try await transport.execute(request("/anything"))
        }
    }

    @Test
    func aRecordedErrorStatusReplaysAsAResponseRatherThanAThrow() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [
                recorded("https://api.example.com/missing", status: 404, body: #"{"error":"not found"}"#),
            ])
        )

        let response = try await transport.execute(request("/missing"))

        #expect(response.statusCode == 404)
        #expect(String(decoding: response.body, as: UTF8.self).contains("not found"))
    }

    @Test
    func aRecordingWithoutABodyReplaysAsAnEmptyBody() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [
                RecordedInteraction(
                    request: RecordedRequest(method: "DELETE", url: "https://api.example.com/users/1"),
                    response: RecordedResponse(status: 204)
                ),
            ])
        )

        let response = try await transport.execute(request("/users/1", method: .delete))

        #expect(response.statusCode == 204)
        #expect(response.body.isEmpty)
    }
}

// MARK: - T-4.x, T-5.1 recording

@Suite
struct CassetteRecordingTests {
    @Test
    func recordingAppendsEachExchangeInOrder() async throws {
        let upstream = ScriptedUpstream(responses: [json(#"{"page":1}"#), json(#"{"page":2}"#)])
        let transport = CassetteTransport(mode: .record, upstream: upstream)

        _ = try await transport.execute(request("/posts", query: [URLQueryItem(name: "page", value: "1")]))
        _ = try await transport.execute(request("/posts", query: [URLQueryItem(name: "page", value: "2")]))

        let cassette = await transport.cassette
        #expect(cassette.interactions.count == 2)
        #expect(cassette.interactions[0].request.url.contains("page=1"))
        #expect(cassette.interactions[1].request.url.contains("page=2"))
        #expect(cassette.interactions[0].response.body?.text == #"{"page":1}"#)
        #expect(await transport.hasUnsavedChanges)
    }

    @Test
    func recordingCapturesTheMethodHeadersAndBodyThatWereSent() async throws {
        let upstream = ScriptedUpstream(responses: [json(#"{"ok":true}"#, status: 201)])
        let transport = CassetteTransport(mode: .record, upstream: upstream, redaction: .none)

        _ = try await transport.execute(
            request("/posts", method: .post, body: Data(#"{"title":"hi"}"#.utf8), headers: ["X-Trace": "abc"])
        )

        let interaction = try #require(await transport.cassette.interactions.first)
        #expect(interaction.request.method == "POST")
        #expect(interaction.request.headers["X-Trace"] == "abc")
        #expect(interaction.request.body?.text == #"{"title":"hi"}"#)
        #expect(interaction.response.status == 201)
    }

    @Test
    func aFailingUpstreamPropagatesAndLeavesTheCassetteUntouched() async {
        let upstream = ScriptedUpstream(failure: UpstreamUnavailable())
        let transport = CassetteTransport(mode: .record, upstream: upstream)

        await #expect(throws: UpstreamUnavailable.self) {
            _ = try await transport.execute(request("/users/1"))
        }

        #expect(await transport.cassette.interactions.isEmpty)
        #expect(await transport.hasUnsavedChanges == false)
    }

    @Test
    func recordingWithoutAnUpstreamIsRejectedWithTheModeNamed() async {
        let transport = CassetteTransport(mode: .record)

        await #expect(throws: CassetteError.recordingRequiresUpstream(mode: "record")) {
            _ = try await transport.execute(request("/users/1"))
        }
    }

    @Test
    func recordMissingReplaysWhatItHasAndRecordsTheRest() async throws {
        let upstream = ScriptedUpstream(responses: [json(#"{"id":2}"#)])
        let transport = CassetteTransport(
            mode: .recordMissing,
            cassette: Cassette(interactions: [recorded("https://api.example.com/users/1", body: #"{"id":1}"#)]),
            upstream: upstream
        )

        let replayed = try await transport.execute(request("/users/1"))
        let recordedFresh = try await transport.execute(request("/users/2"))

        #expect(String(decoding: replayed.body, as: UTF8.self) == #"{"id":1}"#)
        #expect(String(decoding: recordedFresh.body, as: UTF8.self) == #"{"id":2}"#)
        #expect(await upstream.callCount() == 1, "only the unrecorded request reaches the network")
        #expect(await transport.cassette.interactions.count == 2)
    }

    @Test
    func aSecondRunAgainstTheGrownCassetteIsFullyOffline() async throws {
        let recordingUpstream = ScriptedUpstream(responses: [json(#"{"id":1}"#), json(#"{"id":2}"#)])
        let first = CassetteTransport(mode: .recordMissing, upstream: recordingUpstream)
        _ = try await first.execute(request("/users/1"))
        _ = try await first.execute(request("/users/2"))
        let grown = await first.cassette

        let offlineUpstream = ScriptedUpstream(failure: UpstreamUnavailable())
        let second = CassetteTransport(mode: .recordMissing, cassette: grown, upstream: offlineUpstream)

        _ = try await second.execute(request("/users/1"))
        _ = try await second.execute(request("/users/2"))

        #expect(await offlineUpstream.callCount() == 0)
    }
}

// MARK: - T-6.x matching

@Suite
struct CassetteMatchingTests {
    @Test
    func theDefaultRuleMatchesMethodAndFullURL() async throws {
        let cassette = Cassette(interactions: [recorded("https://api.example.com/users/1")])
        let transport = CassetteTransport(mode: .replay, cassette: cassette)

        await #expect(throws: Never.self) { try await transport.execute(request("/users/1")) }

        let wrongMethod = CassetteTransport(mode: .replay, cassette: cassette)
        await #expect(throws: CassetteError.self) {
            _ = try await wrongMethod.execute(request("/users/1", method: .post))
        }
    }

    @Test
    func queryItemOrderDoesNotAffectMatching() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [recorded("https://api.example.com/search?b=2&a=1")])
        )

        let response = try await transport.execute(
            request("/search", query: [URLQueryItem(name: "a", value: "1"), URLQueryItem(name: "b", value: "2")])
        )

        #expect(response.statusCode == 200)
    }

    @Test
    func pathMatchingIgnoresQueryItemsEntirely() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [recorded("https://api.example.com/search?q=cats")]),
            matchRule: .methodAndPath
        )

        await #expect(throws: Never.self) {
            try await transport.execute(request("/search", query: [URLQueryItem(name: "q", value: "dogs")]))
        }
    }

    @Test
    func bodyMatchingSeparatesRequestsThatShareAURL() async throws {
        let cassette = Cassette(interactions: [
            RecordedInteraction(
                request: RecordedRequest(method: "POST", url: "https://api.example.com/search", body: RecordedBody(data: Data(#"{"q":"cats"}"#.utf8))),
                response: RecordedResponse(status: 200, body: RecordedBody(data: Data("cats".utf8)))
            ),
            RecordedInteraction(
                request: RecordedRequest(method: "POST", url: "https://api.example.com/search", body: RecordedBody(data: Data(#"{"q":"dogs"}"#.utf8))),
                response: RecordedResponse(status: 200, body: RecordedBody(data: Data("dogs".utf8)))
            ),
        ])
        let transport = CassetteTransport(mode: .replay, cassette: cassette, matchRule: .includingBody)

        let dogs = try await transport.execute(request("/search", method: .post, body: Data(#"{"q":"dogs"}"#.utf8)))

        #expect(String(decoding: dogs.body, as: UTF8.self) == "dogs")
    }

    @Test
    func headerMatchingIsOptOutAndCaseInsensitive() async throws {
        let cassette = Cassette(interactions: [
            RecordedInteraction(
                request: RecordedRequest(
                    method: "GET",
                    url: "https://api.example.com/feed",
                    headers: ["Accept-Language": "en"]
                ),
                response: RecordedResponse(status: 200, body: RecordedBody(data: Data("english".utf8)))
            ),
        ])

        // Not part of the default rule: a differing header still matches.
        let lenient = CassetteTransport(mode: .replay, cassette: cassette)
        await #expect(throws: Never.self) {
            try await lenient.execute(request("/feed", headers: ["Accept-Language": "de"]))
        }

        let strict = CassetteTransport(
            mode: .replay,
            cassette: cassette,
            matchRule: CassetteMatchRule.default.matchingHeaders("accept-language")
        )
        await #expect(throws: Never.self) {
            try await strict.execute(request("/feed", headers: ["ACCEPT-LANGUAGE": "en"]))
        }

        let mismatched = CassetteTransport(
            mode: .replay,
            cassette: cassette,
            matchRule: CassetteMatchRule.default.matchingHeaders("Accept-Language")
        )
        await #expect(throws: CassetteError.self) {
            _ = try await mismatched.execute(request("/feed", headers: ["Accept-Language": "de"]))
        }
    }

    @Test
    func repeatedRequestsReplayInRecordedOrderOnceEach() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [
                recorded("https://api.example.com/job", body: #"{"state":"queued"}"#),
                recorded("https://api.example.com/job", body: #"{"state":"running"}"#),
                recorded("https://api.example.com/job", body: #"{"state":"done"}"#),
            ])
        )

        var states: [String] = []
        for _ in 0..<3 {
            let response = try await transport.execute(request("/job"))
            states.append(String(decoding: response.body, as: UTF8.self))
        }

        #expect(states == [#"{"state":"queued"}"#, #"{"state":"running"}"#, #"{"state":"done"}"#])
    }

    @Test
    func exhaustedRecordingsFailByDefaultAndNameTheCount() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [recorded("https://api.example.com/job")])
        )
        _ = try await transport.execute(request("/job"))

        do {
            _ = try await transport.execute(request("/job"))
            Issue.record("Expected an exhausted-recordings error")
        } catch let error as CassetteError {
            guard case let .recordingsExhausted(_, _, matches) = error else {
                Issue.record("Expected .recordingsExhausted, got \(error)")
                return
            }
            #expect(matches == 1)
            #expect(error.errorDescription?.contains("repeatLast") == true)
        } catch {
            Issue.record("Expected a CassetteError, got \(error)")
        }
    }

    @Test
    func repeatLastKeepsServingTheFinalRecordingForPollingLoops() async throws {
        let transport = CassetteTransport(
            mode: .replay,
            cassette: Cassette(interactions: [
                recorded("https://api.example.com/job", body: #"{"state":"running"}"#),
                recorded("https://api.example.com/job", body: #"{"state":"done"}"#),
            ]),
            repeatPolicy: .repeatLast
        )

        var states: [String] = []
        for _ in 0..<4 {
            states.append(String(decoding: try await transport.execute(request("/job")).body, as: UTF8.self))
        }

        #expect(states == [
            #"{"state":"running"}"#,
            #"{"state":"done"}"#,
            #"{"state":"done"}"#,
            #"{"state":"done"}"#,
        ])
    }

    @Test
    func lookupInALargeCassetteStaysFast() async throws {
        let interactions = (0..<100).map { recorded("https://api.example.com/items/\($0)") }
        let transport = CassetteTransport(mode: .replay, cassette: Cassette(interactions: interactions))

        let start = ContinuousClock.now
        for index in 0..<100 {
            _ = try await transport.execute(request("/items/\(index)"))
        }
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .milliseconds(100), "100 lookups took \(elapsed)")
    }
}
