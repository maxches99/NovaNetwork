import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkGraphQL

// Requirements: FR-GQL-1…8, EC-GQL-1…4, AR-GQL-1…2 (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §E).
// Tests: T-22.1…T-22.8.

private let endpoint = URL(string: "https://api.example.com/graphql")!

private struct CountryQuery: GraphQLOperation {
    static let document = "query Country($code: ID!) { country(code: $code) { name capital } }"
    static let operationName: String? = "Country"

    struct Variables: Encodable, Sendable { let code: String }
    struct Data: Decodable, Sendable, Equatable {
        struct Country: Decodable, Sendable, Equatable {
            let name: String
            let capital: String?
        }
        let country: Country?
    }

    let variables: Variables
}

private struct ContinentsQuery: GraphQLOperation {
    static let document = "{ continents { code } }"

    struct Data: Decodable, Sendable, Equatable {
        struct Continent: Decodable, Sendable, Equatable { let code: String }
        let continents: [Continent]
    }
}

private struct LikeMutation: GraphQLOperation {
    static let document = "mutation Like($id: ID!) { like(id: $id) { count } }"
    static let operationName: String? = "Like"
    static let kind = GraphQLOperationKind.mutation

    struct Variables: Encodable, Sendable { let id: String }
    struct Data: Decodable, Sendable, Equatable {
        struct Like: Decodable, Sendable, Equatable { let count: Int }
        let like: Like
    }

    let variables: Variables
}

/// A server that answers each request with whatever the test's handler says.
private actor ScriptedServer: NetworkTransport {
    typealias Handler = @Sendable (APIRequest, Int) async throws -> NetworkResponse

    private(set) var requests: [APIRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        requests.append(request)
        return try await handler(request, requests.count)
    }

    nonisolated func bodies() async -> [[String: Any]] {
        await requests.compactMap { request in
            request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }
}

private func ok(_ json: String) -> NetworkResponse {
    NetworkResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
}

private final class GraphQLEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GraphQLEvent] = []

    func record(_ event: GraphQLEvent) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var all: [GraphQLEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private func graphQL(
    _ server: ScriptedServer,
    persistedQueries: GraphQLPersistedQueries = .disabled,
    usesGETForQueries: Bool = false,
    events: GraphQLEvents = GraphQLEvents()
) -> GraphQLClient {
    GraphQLClient(
        endpoint: endpoint,
        client: NetworkClient(configuration: NetworkClientConfiguration(transport: server)),
        persistedQueries: persistedQueries,
        usesGETForQueries: usesGETForQueries,
        headers: ["X-App": "tests"],
        onEvent: { events.record($0) }
    )
}

private let norway = #"{"data":{"country":{"name":"Norway","capital":"Oslo"}}}"#

@Suite
struct GraphQLRequestTests {
    @Test // T-22.1
    func anOperationIsPostedAsSortedJSONWithItsDocumentNameAndVariables() async throws {
        let server = ScriptedServer { _, _ in ok(norway) }
        let client = graphQL(server)

        let data = try await client.data(for: CountryQuery(variables: .init(code: "NO")))

        #expect(data == .init(country: .init(name: "Norway", capital: "Oslo")))
        let request = try #require(await server.requests.first)
        #expect(request.method == .post)
        #expect(request.url == endpoint)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "application/graphql-response+json, application/json")
        #expect(request.headers["X-App"] == "tests")
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self) ==
            #"{"operationName":"Country","query":"query Country($code: ID!) { country(code: $code) { name capital } }","variables":{"code":"NO"}}"#)

        // No variables, no name: neither key is sent.
        let continents = ScriptedServer { _, _ in ok(#"{"data":{"continents":[{"code":"EU"}]}}"#) }
        _ = try await graphQL(continents).data(for: ContinentsQuery())
        #expect(await continents.bodies().first?.keys.sorted() == ["query"])
    }

    @Test // T-22.2
    func errorsComeBackBesideTheDataAndDataForThrowsThemWithWhatSurvived() async throws {
        let partial = #"""
        {"data":{"country":{"name":"Norway","capital":null}},
         "errors":[{"message":"capital unavailable","path":["country","capital"],"locations":[{"line":1,"column":42}],
                    "extensions":{"code":"UPSTREAM","retry":true,"after":[1,2]}}],
         "extensions":{"cost":3}}
        """#
        let events = GraphQLEvents()
        let client = graphQL(ScriptedServer { _, _ in ok(partial) }, events: events)

        let response = try await client.response(for: CountryQuery(variables: .init(code: "NO")))
        #expect(response.data == .init(country: .init(name: "Norway", capital: nil)))
        #expect(response.extensions == ["cost": .number(3)])
        let error = try #require(response.errors.first)
        #expect(error.path == [.field("country"), .field("capital")])
        #expect(error.locations == [.init(line: 1, column: 42)])
        #expect(error.code == "UPSTREAM")
        #expect(error.extensions?["retry"] == .bool(true))
        #expect(error.extensions?["after"] == .array([.number(1), .number(2)]))
        #expect(error.description == "country.capital: capital unavailable")
        #expect(events.all == [.partialResponse(operationName: "Country", errorCount: 1, hasData: true)])

        await #expect {
            _ = try await client.data(for: CountryQuery(variables: .init(code: "NO")))
        } throws: { thrown in
            guard let failure = thrown as? GraphQLResponseError<CountryQuery.Data> else { return false }
            return failure.partialData?.country?.name == "Norway" && failure.errorDescription == "country.capital: capital unavailable"
        }

        // `data: null` with errors: nothing to show.
        let empty = graphQL(ScriptedServer { _, _ in ok(#"{"data":null,"errors":[{"message":"nope","path":["country",0]}]}"#) })
        let nothing = try await empty.response(for: CountryQuery(variables: .init(code: "XX")))
        #expect(nothing.data == nil)
        #expect(nothing.errors.first?.path == [.field("country"), .index(0)])
        #expect(nothing.errors.first?.description == "country.0: nope")

        // A clean response reports nothing.
        let cleanEvents = GraphQLEvents()
        _ = try await graphQL(ScriptedServer { _, _ in ok(norway) }, events: cleanEvents).response(for: CountryQuery(variables: .init(code: "NO")))
        #expect(cleanEvents.all.isEmpty)
        #expect(GraphQLError(message: "plain").description == "plain")
    }
}

@Suite
struct GraphQLPersistedQueryTests {
    @Test // T-22.3
    func aHashIsSentFirstAndTheDocumentOnlyWhenTheServerAsks() async throws {
        let server = ScriptedServer { request, count in
            let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            if count == 1 {
                #expect(body?["query"] == nil)
                return ok(#"{"errors":[{"message":"PersistedQueryNotFound","extensions":{"code":"PERSISTED_QUERY_NOT_FOUND"}}]}"#)
            }
            return ok(norway)
        }
        let events = GraphQLEvents()
        let client = graphQL(server, persistedQueries: .automatic, events: events)

        _ = try await client.data(for: CountryQuery(variables: .init(code: "NO")))

        let bodies = await server.bodies()
        #expect(bodies.count == 2)
        let hash = SHA256Util.hex(CountryQuery.document)
        let first = bodies[0]["extensions"] as? [String: Any]
        let persisted = first?["persistedQuery"] as? [String: Any]
        #expect(persisted?["sha256Hash"] as? String == hash)
        #expect(persisted?["version"] as? Int == 1)
        #expect(bodies[1]["query"] as? String == CountryQuery.document)
        #expect(((bodies[1]["extensions"] as? [String: Any])?["persistedQuery"] as? [String: Any])?["sha256Hash"] as? String == hash)
        #expect(events.all == [.persistedQueryRegistered(operationName: "Country")])
        #expect(await client.sendsPersistedQueries)

        // Recognised by the message alone, too.
        let byMessage = ScriptedServer { _, count in
            count == 1 ? ok(#"{"errors":[{"message":"PersistedQueryNotFound"}]}"#) : ok(norway)
        }
        _ = try await graphQL(byMessage, persistedQueries: .automatic).data(for: CountryQuery(variables: .init(code: "NO")))
        #expect(await byMessage.requests.count == 2)
    }

    @Test // T-22.4
    func aServerWithoutSupportTurnsPersistedQueriesOffForGood() async throws {
        let server = ScriptedServer { request, _ in
            let body = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
            return body?["query"] == nil
                ? ok(#"{"errors":[{"message":"PersistedQueryNotSupported"}]}"#)
                : ok(norway)
        }
        let events = GraphQLEvents()
        let client = graphQL(server, persistedQueries: .automatic, events: events)

        _ = try await client.data(for: CountryQuery(variables: .init(code: "NO")))
        _ = try await client.data(for: CountryQuery(variables: .init(code: "SE")))

        let bodies = await server.bodies()
        #expect(bodies.count == 3)
        #expect(bodies[1]["extensions"] == nil)
        #expect(bodies[2]["query"] as? String == CountryQuery.document)
        #expect(events.all == [.persistedQueriesUnsupported])
        #expect(await !client.sendsPersistedQueries)

        // Recognised by the code alone, too.
        let byCode = ScriptedServer { request, _ in
            request.body.map { String(decoding: $0, as: UTF8.self).contains("\"query\"") } == true
                ? ok(norway)
                : ok(#"{"errors":[{"message":"x","extensions":{"code":"PERSISTED_QUERY_NOT_SUPPORTED"}}]}"#)
        }
        let codeClient = graphQL(byCode, persistedQueries: .automatic)
        _ = try await codeClient.data(for: CountryQuery(variables: .init(code: "NO")))
        #expect(await !codeClient.sendsPersistedQueries)
    }
}

/// Holds every request until the test has seen them all arrive.
private actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiting.append($0) } }
    func count() -> Int { waiting.count }
    func open() {
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

@Suite
struct GraphQLTransportTests {
    @Test // T-22.5
    func identicalQueriesShareARequestButIdenticalMutationsNeverDo() async throws {
        let gate = Gate()
        let server = ScriptedServer { request, _ in
            await gate.wait()
            return request.body.map { String(decoding: $0, as: UTF8.self).contains("mutation") } == true
                ? ok(#"{"data":{"like":{"count":1}}}"#)
                : ok(norway)
        }
        let client = graphQL(server)

        async let a = client.data(for: CountryQuery(variables: .init(code: "NO")))
        async let b = client.data(for: CountryQuery(variables: .init(code: "NO")))
        try await waitFor { await gate.count() == 1 }
        try await Task.sleep(for: .milliseconds(20))
        await gate.open()
        _ = try await (a, b)
        #expect(await server.requests.count == 1)

        async let c = client.data(for: LikeMutation(variables: .init(id: "1")))
        async let d = client.data(for: LikeMutation(variables: .init(id: "1")))
        try await waitFor { await gate.count() == 2 }
        await gate.open()
        _ = try await (c, d)
        #expect(await server.requests.count == 3)
    }

    @Test // T-22.6
    func queriesCanGoAsGETWhileMutationsStayPOST() async throws {
        let server = ScriptedServer { request, _ in
            request.method == .get ? ok(norway) : ok(#"{"data":{"like":{"count":2}}}"#)
        }
        let client = graphQL(server, persistedQueries: .automatic, usesGETForQueries: true)

        _ = try await client.data(for: CountryQuery(variables: .init(code: "NO")))
        _ = try await client.data(for: LikeMutation(variables: .init(id: "1")))

        let requests = await server.requests
        #expect(requests.map(\.method) == [.get, .post])
        let items = Dictionary(uniqueKeysWithValues: requests[0].queryItems.map { ($0.name, $0.value ?? "") })
        #expect(items["operationName"] == "Country")
        #expect(items["variables"] == #"{"code":"NO"}"#)
        #expect(items["extensions"] == #"{"persistedQuery":{"sha256Hash":"\#(SHA256Util.hex(CountryQuery.document))","version":1}}"#)
        #expect(items["query"] == nil)
        #expect(requests[0].body == nil)

        // Without persisted queries the document itself goes in the URL.
        let plain = ScriptedServer { _, _ in ok(norway) }
        _ = try await graphQL(plain, usesGETForQueries: true).data(for: CountryQuery(variables: .init(code: "NO")))
        #expect(await plain.requests.first?.queryItems.first { $0.name == "query" }?.value == CountryQuery.document)
    }

    @Test // T-22.7
    func aGraphQLBodyInAnErrorStatusIsReadAndAnythingElseStaysAnHTTPError() async throws {
        let rejected = ScriptedServer { _, _ in
            throw NetworkError.httpStatus(
                code: 400,
                headers: [:],
                body: Data(#"{"errors":[{"message":"Variable $code is required"}]}"#.utf8)
            )
        }
        let response = try await graphQL(rejected).response(for: CountryQuery(variables: .init(code: "")))
        #expect(response.errors.map(\.message) == ["Variable $code is required"])

        let broken = ScriptedServer { _, _ in
            throw NetworkError.httpStatus(code: 502, headers: [:], body: Data("<html>bad gateway</html>".utf8))
        }
        await #expect {
            _ = try await graphQL(broken).response(for: CountryQuery(variables: .init(code: "NO")))
        } throws: { error in
            guard case NetworkError.httpStatus(let code, _, _) = error else { return false }
            return code == 502
        }

        let notGraphQL = ScriptedServer { _, _ in ok("[1,2,3]") }
        await #expect {
            _ = try await graphQL(notGraphQL).response(for: CountryQuery(variables: .init(code: "NO")))
        } throws: { error in
            guard case NetworkError.decoding = error else { return false }
            return true
        }
    }
}

@Suite
struct GraphQLJSONTests {
    @Test
    func anyJSONRoundTrips() throws {
        let text = #"{"a":[1,"two",true,null,{"b":2.5}]}"#
        let value = try JSONDecoder().decode(GraphQLJSON.self, from: Data(text.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let again = try JSONDecoder().decode(GraphQLJSON.self, from: encoder.encode(value))
        #expect(again == value)
        #expect(value.stringValue == nil)
        #expect(GraphQLJSON.string("x").stringValue == "x")
    }
}

private func waitFor(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out")
}
