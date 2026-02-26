import Foundation
import Testing
@testable import NovaNetworkClient

@Suite
struct APIRequestCoverageTests {
    @Test
    func apiRequestJSONInitRespectsExistingContentType() throws {
        struct Body: Codable, Sendable { let value: String }

        let request = try APIRequest(
            method: .post,
            url: URL(string: "https://example.com/json")!,
            headers: ["Content-Type": "application/custom+json"],
            jsonBody: Body(value: "ok")
        )

        #expect(request.headers["Content-Type"] == "application/custom+json")
        #expect(request.body != nil)
    }

    @Test
    func apiRequestBuildsURLRequestAndMergesHeaders() {
        let base = APIRequest(
            method: .get,
            url: URL(string: "https://example.com/path")!,
            queryItems: [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")],
            headers: ["Accept": "application/json"]
        )
        let merged = base.withMergedHeaders(["Authorization": "Bearer token"])
        let unchanged = base.withMergedHeaders([:])

        let urlRequest = merged.urlRequest()
        let items = URLComponents(url: urlRequest.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(items.count == 2)
        #expect(merged.headers["Authorization"] == "Bearer token")
        #expect(unchanged.headers["Authorization"] == nil)
    }

    @Test
    func apiRequestBuilderAppliesAllMutations() {
        let request = APIRequest
            .builder(method: .put, url: URL(string: "https://example.com/builder")!)
            .queryItem(name: "page", value: "2")
            .queryItems([URLQueryItem(name: "sort", value: "desc")])
            .header("Accept", "application/json")
            .headers(["Authorization": "token"])
            .body(Data("payload".utf8))
            .timeout(12)
            .build()

        #expect(request.queryItems == [URLQueryItem(name: "sort", value: "desc")])
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Authorization"] == "token")
        #expect(request.timeout == 12)
        #expect(request.body == Data("payload".utf8))
    }
}
