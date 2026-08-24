import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkClientTestSupport

// Requirements: FR-TEST-2 (routing transport).

@Suite
struct RoutingTransportTests {
    @Test
    func dispatchesToTheFirstMatchingRoute() async throws {
        let router = RoutingTransport()
        await router.register(.path("/users/1"), statusCode: 200, body: Data("first".utf8))
        await router.register(.pathPrefix("/users/"), statusCode: 200, body: Data("fallback".utf8))

        let response = try await router.execute(
            APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)
        )
        #expect(response.body == Data("first".utf8))

        let fallback = try await router.execute(
            APIRequest(method: .get, url: URL(string: "https://api.example.com/users/2")!)
        )
        #expect(fallback.body == Data("fallback".utf8))
    }

    @Test
    func closureBasedRouteSeesTheMatchedRequest() async throws {
        let router = RoutingTransport()
        await router.register(.method(.post)) { request in
            NetworkResponse(statusCode: 201, headers: [:], body: request.body ?? Data())
        }

        let response = try await router.execute(
            APIRequest(method: .post, url: URL(string: "https://api.example.com/items")!, body: Data("payload".utf8))
        )
        #expect(response.statusCode == 201)
        #expect(response.body == Data("payload".utf8))
    }

    @Test
    func aRouteLimitedByTimesFallsThroughOnceExhausted() async throws {
        let router = RoutingTransport()
        await router.register(.any, times: 1, statusCode: 200, body: Data("once".utf8))
        await router.register(.any, statusCode: 200, body: Data("always".utf8))

        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/x")!)
        let first = try await router.execute(request)
        let second = try await router.execute(request)

        #expect(first.body == Data("once".utf8))
        #expect(second.body == Data("always".utf8))
    }

    @Test
    func unmatchedRequestsThrowADescriptiveError() async throws {
        let router = RoutingTransport()
        await router.register(.path("/users"), statusCode: 200)

        let request = APIRequest(method: .post, url: URL(string: "https://api.example.com/orders")!)
        do {
            _ = try await router.execute(request)
            Issue.record("expected an unmatched-route error")
        } catch let error as RoutingTransportError {
            #expect(error.description.contains("POST"))
            #expect(error.description.contains("orders"))
        }

        let unmatched = await router.unmatchedRequests()
        #expect(unmatched.count == 1)
        #expect(unmatched.first?.url.path == "/orders")
    }

    @Test
    func totalCallCountCountsOnlyMatchedRequests() async throws {
        let router = RoutingTransport()
        await router.register(.path("/users"), statusCode: 200)

        _ = try? await router.execute(APIRequest(method: .get, url: URL(string: "https://api.example.com/users")!))
        _ = try? await router.execute(APIRequest(method: .get, url: URL(string: "https://api.example.com/other")!))

        let total = await router.totalCallCount()
        #expect(total == 1)
    }
}
