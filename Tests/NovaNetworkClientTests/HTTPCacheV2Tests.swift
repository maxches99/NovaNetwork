import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-CACHE-1...5, DR-4, EC-8...10, AR-4.

private actor CacheV2Transport: NetworkTransport {
    private var responses: [Result<NetworkResponse, NetworkError>]
    private var requests: [APIRequest] = []

    init(_ responses: [Result<NetworkResponse, NetworkError>]) {
        self.responses = responses
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw NetworkError.transport(underlying: URLError(.badServerResponse))
        }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [APIRequest] { requests }
}

private actor CacheEventProbe {
    private var events: [NetworkClientEvent] = []
    func append(_ event: NetworkClientEvent) { events.append(event) }
    func snapshot() -> [NetworkClientEvent] { events }
}

@Suite(.serialized)
struct HTTPCacheV2Tests {
    private func request(cacheControl: String? = nil) -> APIRequest {
        APIRequest(
            method: .get,
            url: URL(string: "https://example.com/cache-v2")!,
            headers: cacheControl.map { ["Cache-Control": $0] } ?? [:]
        )
    }

    @Test
    func lastModifiedValidatorIsSentDuringRevalidation() async throws {
        let body = Data("cached".utf8)
        let transport = CacheV2Transport([
            .success(
                .init(
                    statusCode: 200,
                    headers: ["Cache-Control": "max-age=0", "Last-Modified": "Wed, 21 Oct 2015 07:28:00 GMT"],
                    body: body
                )
            ),
            .success(.init(statusCode: 304, headers: [:], body: Data()))
        ])
        let client = NetworkClient(transport: transport)
        let request = request(cacheControl: "no-cache")

        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))
        let second = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        #expect(second == body)
        let recorded = await transport.recordedRequests()
        #expect(recorded.count == 2)
        #expect(recorded[1].headers["If-Modified-Since"] == "Wed, 21 Oct 2015 07:28:00 GMT")
    }

    @Test
    func requestNoStoreBypassesLookupAndStorage() async throws {
        let transport = CacheV2Transport([
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=600"], body: Data("one".utf8))),
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=600"], body: Data("two".utf8)))
        ])
        let client = NetworkClient(transport: transport)
        let request = request(cacheControl: "no-store")

        let first = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))
        let second = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))

        #expect(first == Data("one".utf8))
        #expect(second == Data("two".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func ageHeaderParticipatesInFreshnessCalculation() async throws {
        let transport = CacheV2Transport([
            .success(
                .init(
                    statusCode: 200,
                    headers: ["Cache-Control": "max-age=60", "Age": "120"],
                    body: Data("old".utf8)
                )
            ),
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=60"], body: Data("new".utf8)))
        ])
        let client = NetworkClient(transport: transport)

        _ = try await client.load(request: request(), authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))
        let second = try await client.load(request: request(), authScope: nil, cachePolicy: .cacheFirst(maxAge: 60))

        #expect(second == Data("new".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func requestNoCacheForcesRevalidationOfFreshEntry() async throws {
        let transport = CacheV2Transport([
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=600"], body: Data("one".utf8))),
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=600"], body: Data("two".utf8)))
        ])
        let client = NetworkClient(transport: transport)
        let request = request(cacheControl: "no-cache")

        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))
        let second = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))

        #expect(second == Data("two".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func malformedDateHeaderIsIgnoredSafely() async throws {
        let transport = CacheV2Transport([
            .success(
                .init(
                    statusCode: 200,
                    headers: ["Cache-Control": "max-age=600", "Date": "not-an-http-date"],
                    body: Data("cached".utf8)
                )
            )
        ])
        let client = NetworkClient(transport: transport)

        _ = try await client.load(request: request(), authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))
        let second = try await client.load(request: request(), authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))

        #expect(second == Data("cached".utf8))
        #expect(await transport.recordedRequests().count == 1)
    }

    @Test
    func wildcardVaryResponseIsNeverStored() async throws {
        let transport = CacheV2Transport([
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=600", "Vary": "*"], body: Data("one".utf8))),
            .success(.init(statusCode: 200, headers: ["Cache-Control": "max-age=600"], body: Data("two".utf8)))
        ])
        let client = NetworkClient(transport: transport)

        _ = try await client.load(request: request(), authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))
        let second = try await client.load(request: request(), authScope: nil, cachePolicy: .cacheFirst(maxAge: 600))

        #expect(second == Data("two".utf8))
        #expect(await transport.recordedRequests().count == 2)
    }

    @Test
    func staleIfErrorServesEligibleResponseAndEmitsOutcome() async throws {
        let cachedBody = Data("stale-safe".utf8)
        let transport = CacheV2Transport([
            .success(
                .init(
                    statusCode: 200,
                    headers: ["Cache-Control": "max-age=0, stale-if-error=60"],
                    body: cachedBody
                )
            ),
            .failure(.httpStatus(code: 503, body: Data()))
        ])
        let eventProbe = CacheEventProbe()
        let client = NetworkClient(
            transport: transport,
            networkObserver: { event in Task { await eventProbe.append(event) } }
        )
        let request = request(cacheControl: "no-cache")

        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 0))
        let fallback = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 0))

        #expect(fallback == cachedBody)
        for _ in 0..<100 {
            if await eventProbe.snapshot().contains(where: { event in
                if case .cacheStaleIfError = event { return true }
                return false
            }) { break }
            await Task.yield()
        }
        #expect(await eventProbe.snapshot().contains { event in
            if case .cacheStaleIfError = event { return true }
            return false
        })
    }

    @Test
    func staleIfErrorDoesNotMaskUnauthorizedResponse() async throws {
        let transport = CacheV2Transport([
            .success(
                .init(
                    statusCode: 200,
                    headers: ["Cache-Control": "max-age=0, stale-if-error=60"],
                    body: Data("cached".utf8)
                )
            ),
            .failure(.httpStatus(code: 401, body: Data()))
        ])
        let client = NetworkClient(transport: transport)
        let request = request(cacheControl: "no-cache")
        _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 0))

        do {
            _ = try await client.load(request: request, authScope: nil, cachePolicy: .cacheFirst(maxAge: 0))
            Issue.record("Expected unauthorized response")
        } catch let error as NetworkError {
            #expect(error.statusCode == 401)
        }
    }

    @Test
    func diskCacheReadsMetadataWrittenBeforeLastModifiedField() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DiskResponseCache(directoryURL: root)
        let entry = CachedResponse(
            body: Data("legacy".utf8),
            statusCode: 200,
            headers: [:],
            etag: "legacy-tag",
            storedAtNanoseconds: 1
        )
        await cache.set(entry, forKey: "legacy")
        let metadataURL = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "json" }
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        object["lastModified"] = nil
        try JSONSerialization.data(withJSONObject: object).write(to: metadataURL, options: .atomic)

        let restored = await cache.entry(forKey: "legacy")

        #expect(restored?.body == Data("legacy".utf8))
        #expect(restored?.lastModified == nil)
    }
}
