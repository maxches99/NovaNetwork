import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: NFR-7, T-E2E-END, T-E2E-BATCH, T-E2E-XFER, T-E2E-AUTH, T-E2E-CACHE.

private struct E2EHTTPBinUpload: Decodable, Sendable {
    let data: String
}

private struct E2EHTTPBinBearer: Decodable, Sendable {
    let authenticated: Bool
    let token: String
}

private actor E2EBatchTelemetryProbe {
    private var context: TelemetryBatchContext?

    func record(_ value: TelemetryBatchContext) {
        context = value
    }

    func snapshot() -> TelemetryBatchContext? {
        context
    }
}

private actor E2EAuthRefreshProbe {
    private var scopes: [String?] = []

    func refresh(scope: String?) -> [String: String] {
        scopes.append(scope)
        return ["Authorization": "Bearer nova-v2-e2e"]
    }

    func snapshot() -> [String?] {
        scopes
    }
}

extension E2ECoverageTests {
    @Test
    func e2eV2TypedEndpointExecutesAgainstJSONPlaceholder() async throws {
        guard e2eEnabled() else { return }

        let endpoint = AnyEndpoint<E2ETodo>(
            request: APIRequest(
                method: .get,
                url: URL(string: "https://jsonplaceholder.typicode.com/todos/4")!,
                headers: ["Accept": "application/json"]
            )
        )
        let client = NetworkClient(transport: Transport())

        let todo = try await client.execute(endpoint: endpoint, authScope: "public")

        #expect(todo.id == 4)
        #expect(!todo.title.isEmpty)
    }

    @Test
    func e2eV2CollectingBatchUsesBoundedPublicRequests() async throws {
        guard e2eEnabled() else { return }

        let telemetry = E2EBatchTelemetryProbe()
        let client = NetworkClient(
            transport: Transport(),
            telemetryHooks: NetworkTelemetryHooks(onBatchCompleted: { context in
                Task { await telemetry.record(context) }
            })
        )
        let requests = [
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!),
            APIRequest(method: .get, url: URL(string: "https://httpbin.org/status/503")!),
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/2")!)
        ]

        let results = try await client.loadBatchResults(
            requests: requests,
            authScope: "public",
            batchOptions: .init(maxConcurrentRequests: 2)
        )

        #expect(results.map(\.index) == [0, 1, 2])
        if case .success = results[0].result {} else { Issue.record("Expected first batch success") }
        if case .failure(let error) = results[1].result {
            #expect(error.statusCode == 503)
        } else {
            Issue.record("Expected middle batch failure")
        }
        if case .success = results[2].result {} else { Issue.record("Expected final batch success") }

        for _ in 0..<100 {
            if await telemetry.snapshot() != nil { break }
            await Task.yield()
        }
        let context = await telemetry.snapshot()
        #expect(context?.maxConcurrentRequests == 2)
        #expect(context?.succeeded == 2)
        #expect(context?.failed == 1)
    }

    @Test
    func e2eV2DefaultTransportStreamsIncrementallyFromHTTPBin() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/stream-bytes/100000?chunk_size=16384&seed=42")!
        )
        var chunks: [Data] = []

        for try await chunk in client.loadStream(request: request, authScope: "public") {
            chunks.append(chunk)
        }

        #expect(chunks.count >= 2)
        #expect(chunks.reduce(0) { $0 + $1.count } == 100_000)
    }

    @Test
    func e2eV2UploadCompletesAgainstHTTPBin() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://httpbin.org/post")!,
            headers: ["Content-Type": "text/plain"]
        )
        var response: NetworkResponse?

        for try await event in client.upload(
            request: request,
            body: Data("nova-v2-upload".utf8),
            authScope: "public"
        ) {
            if case .completed(let value) = event {
                response = value
            }
        }

        let completed = try #require(response)
        #expect(completed.statusCode == 200)
        let payload = try JSONDecoder().decode(E2EHTTPBinUpload.self, from: completed.body)
        #expect(payload.data == "nova-v2-upload")
    }

    @Test
    func e2eV2DownloadFinalizesHTTPBinBytes() async throws {
        guard e2eEnabled() else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nova-v2-download-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent("payload.bin")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/bytes/4096?seed=42")!
        )
        var downloaded: DownloadedFile?

        for try await event in client.download(
            request: request,
            to: destination,
            authScope: "public"
        ) {
            if case .completed(let file) = event {
                downloaded = file
            }
        }

        #expect(downloaded?.fileURL == destination)
        #expect(try Data(contentsOf: destination).count == 4_096)
    }

    @Test
    func e2eV2AuthRefreshReplaysHTTPBinBearerRequest() async throws {
        guard e2eEnabled() else { return }

        let refresh = E2EAuthRefreshProbe()
        let client = NetworkClient(
            transport: Transport(),
            httpAuthRefreshProvider: HTTPAuthRefreshProvider { scope in
                await refresh.refresh(scope: scope)
            }
        )
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/bearer")!,
            headers: ["Accept": "application/json"]
        )

        let result: E2EHTTPBinBearer = try await client.load(
            request: request,
            authScope: "e2e-bearer"
        )

        #expect(result.authenticated)
        #expect(result.token == "nova-v2-e2e")
        #expect(await refresh.snapshot() == ["e2e-bearer"])
    }

    @Test
    func e2eV2ETagRevalidationUsesCachedBody() async throws {
        guard e2eEnabled() else { return }

        let events = E2EEventRecorder()
        let client = NetworkClient(
            transport: Transport(),
            networkObserver: { events.append($0) }
        )
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/etag/nova-v2-e2e")!,
            headers: ["Cache-Control": "no-cache"]
        )

        let first = try await client.load(
            request: request,
            authScope: "public",
            cachePolicy: .cacheFirst(maxAge: 0)
        )
        let second = try await client.load(
            request: request,
            authScope: "public",
            cachePolicy: .cacheFirst(maxAge: 0)
        )

        #expect(second == first)
        #expect(events.snapshot().contains { event in
            if case .cacheRevalidated = event { return true }
            return false
        })
    }
}
