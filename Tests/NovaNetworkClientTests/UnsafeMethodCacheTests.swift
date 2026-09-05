import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaNetworkCore
import Testing
@testable import NovaNetworkClient

// Requirements: FR-CACHE-SAFE-1...4, EC-CACHE-SAFE-1...2.

private actor RecordingTransport: NetworkTransport {
    private var responses: [NetworkResponse]
    private var requests: [APIRequest] = []

    init(_ bodies: [String], cacheControl: String = "max-age=600") {
        responses = bodies.map {
            NetworkResponse(statusCode: 200, headers: ["Cache-Control": cacheControl], body: Data($0.utf8))
        }
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw NetworkError.transport(underlying: URLError(.badServerResponse))
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [APIRequest] { requests }
}

@Suite(.serialized)
struct UnsafeMethodCacheTests {
    private func request(_ method: URLMethod) -> APIRequest {
        APIRequest(method: method, url: URL(string: "https://example.com/resource")!)
    }

    @Test(arguments: [URLMethod.post, .put, .patch, .delete])
    func unsafeMethodsBypassTheCacheEvenWhenTheServerMarksTheResponseCacheable(method: URLMethod) async throws {
        let transport = RecordingTransport(["first", "second"])
        let client = NetworkClient(transport: transport)

        let first = try await client.load(
            request: request(method),
            authScope: nil,
            cachePolicy: .cacheFirst(maxAge: 600)
        )
        let second = try await client.load(
            request: request(method),
            authScope: nil,
            cachePolicy: .cacheFirst(maxAge: 600)
        )

        #expect(first == Data("first".utf8))
        #expect(second == Data("second".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func staleWhileRevalidateAlsoLeavesUnsafeMethodsAlone() async throws {
        let transport = RecordingTransport(["first", "second"])
        let client = NetworkClient(transport: transport)

        _ = try await client.load(
            request: request(.post),
            authScope: nil,
            cachePolicy: .staleWhileRevalidate(maxAge: 600, staleAge: 600)
        )
        let second = try await client.load(
            request: request(.post),
            authScope: nil,
            cachePolicy: .staleWhileRevalidate(maxAge: 600, staleAge: 600)
        )

        #expect(second == Data("second".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func safeMethodsStillUseTheCache() async throws {
        let transport = RecordingTransport(["first", "second"])
        let client = NetworkClient(transport: transport)

        let first = try await client.load(request: request(.get), authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))
        let second = try await client.load(request: request(.get), authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))

        #expect(first == Data("first".utf8))
        #expect(second == Data("first".utf8))
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test
    func includingUnsafeMethodsOptsPostBackIn() async throws {
        let transport = RecordingTransport(["first", "second"])
        let client = NetworkClient(transport: transport)

        let first = try await client.load(
            request: request(.post),
            authScope: nil,
            cachePolicy: .includingUnsafeMethods(.cacheFirst(maxAge: 600))
        )
        let second = try await client.load(
            request: request(.post),
            authScope: nil,
            cachePolicy: .includingUnsafeMethods(.cacheFirst(maxAge: 600))
        )

        #expect(first == Data("first".utf8))
        #expect(second == Data("first".utf8))
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test
    func aClientConfiguredToCacheUnsafeMethodsDoesSoWithoutAPerCallPolicy() async throws {
        let transport = RecordingTransport(["first", "second"])
        var configuration = NetworkClientConfiguration()
        configuration.transport = transport
        configuration.defaultCachePolicy = .includingUnsafeMethods(.cacheFirst(maxAge: 600))
        let client = NetworkClient(configuration: configuration)

        _ = try await client.load(request: request(.post), authScope: nil as String?)
        let second = try await client.load(request: request(.post), authScope: nil as String?)

        #expect(second == Data("first".utf8))
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test
    func noStoreStillWinsOverTheOptIn() async throws {
        let transport = RecordingTransport(["first", "second"])
        let client = NetworkClient(transport: transport)
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/resource")!,
            headers: ["Cache-Control": "no-store"]
        )

        _ = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .includingUnsafeMethods(.cacheFirst(maxAge: 600))
        )
        let second = try await client.load(
            request: request,
            authScope: nil,
            cachePolicy: .includingUnsafeMethods(.cacheFirst(maxAge: 600))
        )

        #expect(second == Data("second".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func preloadDoesNotStoreAnUnsafeMethod() async throws {
        let transport = RecordingTransport(["preloaded", "fresh"])
        let client = NetworkClient(transport: transport)

        try await client.preload(request: request(.post), authScope: nil)
        let loaded = try await client.load(
            request: request(.post),
            authScope: nil,
            cachePolicy: .includingUnsafeMethods(.cacheFirst(maxAge: 600))
        )

        #expect(loaded == Data("fresh".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func policyReportsItsStrategyAndOptIn() {
        let plain = CachePolicy.cacheFirst(maxAge: 30)
        let opened = CachePolicy.includingUnsafeMethods(plain)

        #expect(plain.includesUnsafeMethods == false)
        #expect(opened.includesUnsafeMethods)
        if case .cacheFirst(let maxAge) = opened.strategy {
            #expect(maxAge == 30)
        } else {
            Issue.record("The opt-in wrapper should expose the strategy it wraps.")
        }
    }

    @Test
    func normalizingFlattensNestedOptInsAndClampsWindows() {
        let nested = CachePolicy.includingUnsafeMethods(
            .includingUnsafeMethods(.staleWhileRevalidate(maxAge: -5, staleAge: -10))
        )
        let normalized = nested.normalized

        #expect(normalized.includesUnsafeMethods)
        #expect(normalized.strategy.includesUnsafeMethods == false)
        if case .staleWhileRevalidate(let maxAge, let staleAge) = normalized.strategy {
            #expect(maxAge == 0)
            #expect(staleAge == 0)
        } else {
            Issue.record("Normalizing should preserve the wrapped strategy.")
        }
    }

    @Test
    func normalizingKeepsEveryStrategyItIsGiven() {
        #expect(CachePolicy.networkOnly.normalized.freshnessDescription == "networkOnly")
        #expect(CachePolicy.cacheFirst(maxAge: -1).normalized.freshnessDescription == "cacheFirst(0.0)")
        #expect(
            CachePolicy.staleWhileRevalidate(maxAge: 10, staleAge: 5).normalized.freshnessDescription
                == "staleWhileRevalidate(10.0, 10.0)"
        )
    }
}

private extension CachePolicy {
    /// A stable rendering of the freshness strategy, so a test can assert on it without repeating
    /// the same `if case` ladder for every strategy.
    var freshnessDescription: String {
        switch freshness {
        case .networkOnly:
            return "networkOnly"
        case .cacheFirst(let maxAge):
            return "cacheFirst(\(maxAge))"
        case .staleWhileRevalidate(let maxAge, let staleAge):
            return "staleWhileRevalidate(\(maxAge), \(staleAge))"
        }
    }
}
