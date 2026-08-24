import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkClientTestSupport

// Requirements: FR-TEST-1 (request matching DSL).

@Suite
struct RequestMatcherTests {
    private func request(
        method: URLMethod = .get,
        url: String = "https://api.example.com/users/42",
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> APIRequest {
        APIRequest(method: method, url: URL(string: url)!, headers: headers, body: body)
    }

    @Test
    func anyMatchesEverything() {
        #expect(RequestMatcher.any.matches(request()))
        #expect(RequestMatcher.any.matches(request(method: .post)))
    }

    @Test
    func methodMatchesOnlyTheGivenMethod() {
        let matcher = RequestMatcher.method(.post)
        #expect(!matcher.matches(request(method: .get)))
        #expect(matcher.matches(request(method: .post)))
    }

    @Test
    func pathMatchesExactly() {
        let matcher = RequestMatcher.path("/users/42")
        #expect(matcher.matches(request(url: "https://api.example.com/users/42")))
        #expect(!matcher.matches(request(url: "https://api.example.com/users/42/posts")))
    }

    @Test
    func pathPrefixMatchesAnySuffix() {
        let matcher = RequestMatcher.pathPrefix("/users/")
        #expect(matcher.matches(request(url: "https://api.example.com/users/42")))
        #expect(matcher.matches(request(url: "https://api.example.com/users/42/posts")))
        #expect(!matcher.matches(request(url: "https://api.example.com/posts/1")))
    }

    @Test
    func hostMatchesExactly() {
        let matcher = RequestMatcher.host("api.example.com")
        #expect(matcher.matches(request(url: "https://api.example.com/users/42")))
        #expect(!matcher.matches(request(url: "https://other.example.com/users/42")))
    }

    @Test
    func headerMatchesCaseInsensitiveNameAndExactValue() {
        let matcher = RequestMatcher.header("authorization", "Bearer token")
        #expect(matcher.matches(request(headers: ["Authorization": "Bearer token"])))
        #expect(!matcher.matches(request(headers: ["Authorization": "Bearer other"])))
        #expect(!matcher.matches(request(headers: [:])))
    }

    @Test
    func bodyContainsSearchesDecodedUTF8Text() {
        let matcher = RequestMatcher.bodyContains("\"name\":\"Max\"")
        #expect(matcher.matches(request(body: Data(#"{"name":"Max"}"#.utf8))))
        #expect(!matcher.matches(request(body: Data(#"{"name":"Alex"}"#.utf8))))
        #expect(!matcher.matches(request(body: nil)))
    }

    @Test
    func urlMatchesTheFullyResolvedURLIncludingQueryItems() {
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users")!,
            queryItems: [URLQueryItem(name: "id", value: "42")]
        )
        let matcher = RequestMatcher.url(URL(string: "https://api.example.com/users?id=42")!)
        #expect(matcher.matches(request))
    }

    @Test
    func andRequiresBothMatchersToMatch() {
        let matcher = RequestMatcher.method(.post) && RequestMatcher.pathPrefix("/users")
        #expect(matcher.matches(request(method: .post, url: "https://api.example.com/users/42")))
        #expect(!matcher.matches(request(method: .get, url: "https://api.example.com/users/42")))
        #expect(!matcher.matches(request(method: .post, url: "https://api.example.com/posts/1")))
    }

    @Test
    func orRequiresEitherMatcherToMatch() {
        let matcher = RequestMatcher.method(.post) || RequestMatcher.method(.put)
        #expect(matcher.matches(request(method: .post)))
        #expect(matcher.matches(request(method: .put)))
        #expect(!matcher.matches(request(method: .get)))
    }
}
