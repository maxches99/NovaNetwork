#if EndpointMacros
import Foundation
import Testing
import NovaNetworkMacros

// Requirements: FR-8 (generated conformance), FR-9 (path binding), FR-10 (markers), FR-11 (query
// default), FR-12 (response argument), FR-13 (absolute URL), FR-14 (ignored members), NFR-6.
// Tests: T-8.1, T-9.1, T-10.1, T-11.1, T-12.1, T-13.1, T-14.1.
//
// These exercise the macro the way a consumer does — by compiling annotated types and inspecting
// the requests they build — so a expansion that type-checks but requests the wrong URL still fails.

private protocol TestAPI: EndpointDefinition {}

extension TestAPI {
    var baseURL: URL { URL(string: "https://api.example.com/v1")! }
}

private struct TestUser: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

private struct NewUser: Codable, Equatable, Sendable {
    let name: String
}

@Endpoint(.get, "/users/{id}/posts", response: [TestUser].self)
private struct GetUserPosts: TestAPI {
    let id: Int
    var limit: Int?
    @Query("sort_by") var sortBy: String?
    @Header("X-Trace") var trace: String?
}

@Endpoint(.post, "/users", response: TestUser.self)
private struct CreateUser: TestAPI {
    @Body var payload: NewUser
    @Header("Idempotency-Key") var idempotencyKey: String
}

@Endpoint(.delete, "/users/{id}", response: NoContent.self)
private struct DeleteUser: TestAPI {
    let id: Int
}

@Endpoint(.get, "https://status.example.com/health", response: TestUser.self)
private struct HealthCheck {}

@Endpoint(.get, "/users/{user_id}", response: TestUser.self)
private struct GetUserByWireName: TestAPI {
    @Path("user_id") let id: Int
}

@Endpoint(.get, "/posts", response: [TestUser].self)
private struct SearchPosts: TestAPI {
    @Query("tag", style: .commaSeparated) var tags: [String]
    var timeout: TimeInterval { 12 }
    var additionalHeaders: [String: String] { ["Accept": "application/json"] }
    static let debugName = "search"
    var describedTags: String { tags.joined(separator: "+") }
}

@Suite
struct EndpointMacroBehaviorTests {
    @Test
    func pathPlaceholderIsFilledByTheMatchingPropertyName() throws {
        let request = try GetUserPosts(id: 42).makeRequest()

        #expect(request.method == .get)
        #expect(request.url.absoluteString == "https://api.example.com/v1/users/42/posts")
    }

    @Test
    func unmarkedPropertiesBecomeQueryItemsAndNilOnesAreOmitted() throws {
        let request = try GetUserPosts(id: 1, limit: 10, sortBy: "date").makeRequest()

        #expect(request.queryItems == [
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "sort_by", value: "date"),
        ])
    }

    @Test
    func markedPropertiesBecomeHeadersUnderTheirWireName() throws {
        let withTrace = try GetUserPosts(id: 1, trace: "abc").makeRequest()
        let without = try GetUserPosts(id: 1).makeRequest()

        #expect(withTrace.headers["X-Trace"] == "abc")
        #expect(without.headers["X-Trace"] == nil)
    }

    @Test
    func bodyPropertyIsJSONEncodedWithAContentType() throws {
        let request = try CreateUser(payload: NewUser(name: "Ada"), idempotencyKey: "key-1").makeRequest()

        #expect(request.method == .post)
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Idempotency-Key"] == "key-1")
        #expect(try JSONDecoder().decode(NewUser.self, from: #require(request.body)) == NewUser(name: "Ada"))
    }

    @Test
    func absoluteURLSuppliesTheBaseURLWithoutAnyOtherSource() throws {
        let request = try HealthCheck().makeRequest()

        #expect(HealthCheck().baseURL.absoluteString == "https://status.example.com")
        #expect(request.url.absoluteString == "https://status.example.com/health")
    }

    @Test
    func pathMarkerBindsAPropertyToADifferentPlaceholderName() throws {
        #expect(try GetUserByWireName(id: 7).makeRequest().url.absoluteString == "https://api.example.com/v1/users/7")
    }

    @Test
    func queryStyleMarkerControlsArraySerialization() throws {
        let request = try SearchPosts(tags: ["swift", "http"]).makeRequest()

        #expect(request.queryItems == [URLQueryItem(name: "tag", value: "swift,http")])
    }

    @Test
    func customizationPointsAndTypeLevelMembersAreNotTreatedAsParameters() throws {
        let request = try SearchPosts(tags: []).makeRequest()

        #expect(request.timeout == 12)
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.queryItems.isEmpty)
        #expect(request.url.absoluteString == "https://api.example.com/v1/posts")
        #expect(SearchPosts.debugName == "search")
    }

    @Test
    func responseArgumentSuppliesTheAssociatedTypeForDecoding() throws {
        let users = try GetUserPosts(id: 1).decode(Data(#"[{"id":1,"name":"Ada"}]"#.utf8), using: JSONDecoder())

        #expect(users == [TestUser(id: 1, name: "Ada")])
    }

    @Test
    func noContentResponsesDecodeAnEmptyBody() throws {
        let request = try DeleteUser(id: 3).makeRequest()

        #expect(request.method == .delete)
        #expect(try DeleteUser(id: 3).decode(Data(), using: JSONDecoder()) == NoContent())
    }
}
#endif
