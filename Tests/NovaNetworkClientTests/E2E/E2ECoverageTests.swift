import Foundation
import Testing
@testable import NovaNetworkClient

let e2eFlag = "RUN_E2E_TESTS"
let e2eWebSocketURLFlag = "E2E_WS_URL"

func e2eEnabled() -> Bool {
    ProcessInfo.processInfo.environment[e2eFlag] == "1"
}

struct E2ETodo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

struct E2EHTTPBingoAnything: Decodable, Sendable {
    let headers: [String: [String]]
}

enum E2ETestError: Error {
    case mappedStatus(Int)
}

final class E2EEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NetworkClientEvent] = []

    func append(_ event: NetworkClientEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [NetworkClientEvent] {
        lock.lock()
        let copy = events
        lock.unlock()
        return copy
    }
}

func e2eWebSocketCandidates() -> [URL] {
    var candidates: [URL] = []
    if let explicit = ProcessInfo.processInfo.environment[e2eWebSocketURLFlag],
       let url = URL(string: explicit) {
        candidates.append(url)
    }
    candidates.append(contentsOf: [
        URL(string: "wss://ws.postman-echo.com/raw")!,
        URL(string: "wss://ws.ifelse.io")!
    ])
    return candidates
}

func withAnyE2EWebSocketURL<T>(
    _ operation: @escaping @Sendable (URL) async throws -> T
) async throws -> T {
    var failures: [String] = []

    for url in e2eWebSocketCandidates() {
        do {
            return try await operation(url)
        } catch {
            failures.append("\(url.absoluteString): \(error)")
        }
    }

    throw NSError(
        domain: "E2EWebSocket",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "All public WebSocket endpoints failed: \(failures.joined(separator: " | "))"]
    )
}

func nextWebSocketMessage(
    from stream: AsyncThrowingStream<WebSocketMessage, Error>,
    timeoutNanoseconds: UInt64 = 12_000_000_000
) async throws -> WebSocketMessage? {
    try await withThrowingTaskGroup(of: WebSocketMessage?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return try await iterator.next()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: timeoutNanoseconds)
            throw WebSocketError.timeout
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            return nil
        }
        return first
    }
}

func e2eFixedKey() -> Data {
    Data(repeating: 11, count: 32)
}

func headerValue(_ headers: [String: [String]], key: String) -> String? {
    headers.first { lhs, _ in lhs.lowercased() == key.lowercased() }?.value.first
}

@Suite(.serialized)
struct E2ECoverageTests {
    @Test
    func e2eTypedLoadFromJSONPlaceholder() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
            headers: ["Accept": "application/json"]
        )

        let todo: E2ETodo = try await client.load(request: request, authScope: "public")
        #expect(todo.id == 1)
        #expect(!todo.title.isEmpty)
    }

    @Test
    func e2eConcurrentRequestsAreCoalesced() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/2")!,
            headers: ["Accept": "application/json"]
        )

        async let first: E2ETodo = client.load(request: request, authScope: "public")
        async let second: E2ETodo = client.load(request: request, authScope: "public")
        let (a, b) = try await (first, second)

        #expect(a.id == b.id)

        let metrics = await client.coalescerMetrics()
        #expect(metrics.coalescedHits >= 1)
    }

    @Test
    func e2eBatchLoadFromJSONPlaceholder() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let decoder = JSONDecoder()

        let requests = [
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!),
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/2")!),
            APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/3")!)
        ]

        let payloads = try await client.loadBatch(requests: requests, authScope: "public")
        let ids = try payloads.map { try decoder.decode(E2ETodo.self, from: $0).id }

        #expect(ids == [1, 2, 3])
    }

    @Test
    func e2eCacheFirstProducesCacheHitEvent() async throws {
        guard e2eEnabled() else { return }

        let recorder = E2EEventRecorder()
        let client = NetworkClient(
            transport: Transport(),
            defaultCachePolicy: .cacheFirst(maxAge: 120),
            networkObserver: { event in
                recorder.append(event)
            }
        )

        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbingo.org/cache/120")!
        )

        _ = try await client.load(request: request, authScope: "public")
        _ = try await client.load(request: request, authScope: "public")

        let events = recorder.snapshot()
        let hasCacheHit = events.contains {
            if case .cacheHit = $0 { return true }
            return false
        }
        #expect(hasCacheHit)
    }

    @Test
    func e2eMiddlewareInjectsHeadersViaHTTPBingo() async throws {
        guard e2eEnabled() else { return }

        let middleware = NetworkMiddleware(
            beforeSend: { request, _ in
                request.withMergedHeaders(["X-E2E-Token": "nova-e2e"])
            }
        )
        let client = NetworkClient(transport: Transport(), middlewares: [middleware])
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbingo.org/anything")!
        )

        let body: E2EHTTPBingoAnything = try await client.load(request: request, authScope: "public")
        #expect(headerValue(body.headers, key: "X-E2E-Token") == "nova-e2e")
    }

    @Test
    func e2eLoadStreamFallbackReturnsDataChunk() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
        )

        var chunks: [Data] = []
        for try await chunk in client.loadStream(request: request, authScope: "public") {
            chunks.append(chunk)
        }

        #expect(chunks.count == 1)

        let todo = try JSONDecoder().decode(E2ETodo.self, from: chunks[0])
        #expect(todo.id == 1)
    }
}
