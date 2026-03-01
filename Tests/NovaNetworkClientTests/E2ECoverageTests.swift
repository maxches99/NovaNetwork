import Foundation
import Testing
@testable import NovaNetworkClient

private let e2eFlag = "RUN_E2E_TESTS"

private func e2eEnabled() -> Bool {
    ProcessInfo.processInfo.environment[e2eFlag] == "1"
}

private struct E2ETodo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

private struct E2EHTTPBinAnything: Decodable, Sendable {
    let headers: [String: String]
}

private enum E2ETestError: Error {
    case mappedStatus(Int)
}

private final class E2EEventRecorder: @unchecked Sendable {
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

private actor E2EAlwaysSuccessTransport: NetworkTransport {
    private(set) var calls: Int = 0

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("{\"ok\":true}".utf8))
    }

    func callCount() -> Int { calls }
}

private actor E2EAlwaysHTTP422Transport: NetworkTransport {
    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        throw NetworkError.httpStatus(code: 422, body: Data())
    }
}

private func e2eFixedKey() -> Data {
    Data(repeating: 11, count: 32)
}

private func headerValue(_ headers: [String: String], key: String) -> String? {
    headers.first { lhs, _ in lhs.lowercased() == key.lowercased() }?.value
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
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
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
    func e2eMiddlewareInjectsHeadersViaHTTPBin() async throws {
        guard e2eEnabled() else { return }

        let middleware = NetworkMiddleware(
            beforeSend: { request, _ in
                request.withMergedHeaders(["X-E2E-Token": "nova-e2e"])
            }
        )
        let client = NetworkClient(transport: Transport(), middlewares: [middleware])
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/anything")!
        )

        let body: E2EHTTPBinAnything = try await client.load(request: request, authScope: "public")
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

    @Test
    func e2eAlwaysEnqueueWritePersistsInOfflineQueue() async throws {
        guard e2eEnabled() else { return }

        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-Queue-\(UUID().uuidString)", isDirectory: true)
        let client = NetworkClient(
            transport: Transport(),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )

        let request = APIRequest(
            method: .post,
            url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
            body: Data("{\"title\":\"e2e\",\"body\":\"payload\",\"userId\":1}".utf8)
        )

        let result = try await client.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        switch result {
        case .completed:
            Issue.record("Expected queued result for .alwaysEnqueue mode.")
        case .queued:
            break
        }

        #expect(await client.offlineQueueDepth() == 1)
        #expect(await client.dropAllQueuedWrites() == 1)
        #expect(await client.offlineQueueDepth() == 0)
    }

    @Test
    func e2eClientRateLimitBlocksSecondRequest() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
        )
        let options = RequestExecutionOptions(
            rateLimitPolicy: .init(maxRequests: 1, intervalSeconds: 60)
        )

        _ = try await client.load(request: request, authScope: "public", options: options)

        do {
            _ = try await client.load(request: request, authScope: "public", options: options)
            Issue.record("Expected second request to be rate limited.")
        } catch let error as NetworkError {
            if case .clientRateLimited = error {
                // Expected path.
            } else {
                Issue.record("Expected .clientRateLimited, got \(error).")
            }
        }
    }

    @Test
    func e2eErrorMapperTransformsHTTPError() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/status/404")!
        )

        do {
            _ = try await client.load(
                request: request,
                authScope: "public",
                errorMapper: { networkError in
                    if case .httpStatus(let code, _, _) = networkError {
                        return E2ETestError.mappedStatus(code)
                    }
                    return E2ETestError.mappedStatus(-1)
                }
            )
            Issue.record("Expected mapped error.")
        } catch let error as E2ETestError {
            if case .mappedStatus(let status) = error {
                #expect(status == 404)
            }
        }
    }

    @Test
    func e2eDisabledCoalescingRunsWithoutHitMetrics() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/2")!
        )
        let options = RequestExecutionOptions(coalescingMode: .disabled)

        async let first: E2ETodo = client.load(request: request, authScope: "public", options: options)
        async let second: E2ETodo = client.load(request: request, authScope: "public", options: options)
        let (a, b) = try await (first, second)
        #expect(a.id == b.id)

        let metrics = await client.coalescerMetrics()
        #expect(metrics.coalescedHits == 0)
    }

    @Test
    func e2eOfflineQueueFlushReplaysQueuedWrite() async throws {
        guard e2eEnabled() else { return }

        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-Flush-\(UUID().uuidString)", isDirectory: true)
        let client = NetworkClient(
            transport: Transport(),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
            body: Data("{\"title\":\"flush\",\"body\":\"payload\",\"userId\":1}".utf8)
        )

        _ = try await client.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        #expect(await client.offlineQueueDepth() == 1)

        let replayed = await client.flushOfflineQueue()
        #expect(replayed >= 1)
        #expect(await client.offlineQueueDepth() == 0)
    }

    @Test
    func e2eOfflineQueueSnapshotAndDropQueuedWrite() async throws {
        guard e2eEnabled() else { return }

        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-Drop-\(UUID().uuidString)", isDirectory: true)
        let client = NetworkClient(
            transport: Transport(),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
            body: Data("{\"title\":\"drop\",\"body\":\"payload\",\"userId\":1}".utf8)
        )

        _ = try await client.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        let snapshot = await client.offlineQueueSnapshot()
        #expect(snapshot.count == 1)

        let dropped = await client.dropQueuedWrite(queueID: snapshot[0].receipt.queueID)
        #expect(dropped)
        #expect(await client.offlineQueueDepth() == 0)
    }

    @Test
    func e2eRuntimePolicyUpdateEmitsEvent() async throws {
        guard e2eEnabled() else { return }

        let recorder = E2EEventRecorder()
        let client = NetworkClient(
            transport: Transport(),
            networkObserver: { event in
                recorder.append(event)
            }
        )

        await client.updateRuntimePolicy(
            .init(deadlineBudgetSeconds: 0.5),
            scope: .host("jsonplaceholder.typicode.com")
        )

        let hasPolicyEvent = recorder.snapshot().contains {
            if case .requestPolicyUpdated = $0 { return true }
            return false
        }
        #expect(hasPolicyEvent)
    }

    @Test
    func e2eCircuitBreakerOpensAfterFailureThreshold() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(transport: Transport())
        let failingRequest = APIRequest(
            method: .get,
            url: URL(string: "https://httpbin.org/status/503")!
        )
        let options = RequestExecutionOptions(
            circuitBreakerPolicy: .init(
                scope: .host,
                failureThreshold: 1,
                cooldownSeconds: 20
            )
        )

        do {
            _ = try await client.load(request: failingRequest, authScope: "public", options: options)
            Issue.record("Expected first request to fail with HTTP status.")
        } catch {
            // Expected.
        }

        do {
            _ = try await client.load(request: failingRequest, authScope: "public", options: options)
            Issue.record("Expected circuit breaker to open on second request.")
        } catch let error as NetworkError {
            if case .circuitBreakerOpen = error {
                // Expected.
            } else {
                Issue.record("Expected .circuitBreakerOpen, got \(error).")
            }
        }
    }

    @Test
    func e2ePreloadAndInvalidatePaths() async throws {
        guard e2eEnabled() else { return }

        let client = NetworkClient(
            transport: Transport(),
            defaultCachePolicy: .cacheFirst(maxAge: 120)
        )
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
        )

        try await client.preload(request: request, authScope: "public")
        _ = try await client.load(request: request, authScope: "public")

        await client.invalidate(request: request, authScope: "public")
        await client.invalidate(fingerprintKey: "non-existing-key")
        await client.invalidateAll(where: { _ in false })
        await client.invalidateAll()
    }

    @Test
    func e2eOfflineReplayDedupeSuppressionSkipsSecondTransportExecution() async throws {
        guard e2eEnabled() else { return }

        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-Dedupe-\(UUID().uuidString)", isDirectory: true)
        let transport = E2EAlwaysSuccessTransport()
        let client = NetworkClient(
            transport: transport,
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/e2e-dedupe")!,
            body: Data("{\"name\":\"dedupe\"}".utf8)
        )
        let options = RequestExecutionOptions(
            idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
            offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayDedupeWindowSeconds: 3600)
        )

        _ = try await client.enqueueWrite(request: request, authScope: "public", options: options)
        _ = try await client.enqueueWrite(request: request, authScope: "public", options: options)
        #expect(await client.offlineQueueDepth() == 2)

        let replayed = await client.flushOfflineQueue(limit: 8)
        #expect(replayed == 2)
        #expect(await transport.callCount() == 1)
        #expect(await client.offlineQueueDepth() == 0)
    }

    @Test
    func e2eOfflineReplayConflictPoliciesManualReviewAndDrop() async throws {
        guard e2eEnabled() else { return }

        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-Conflict-\(UUID().uuidString)", isDirectory: true)
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/e2e-conflict")!,
            body: Data("{\"name\":\"conflict\"}".utf8)
        )

        let manualStore = DiskOfflineWriteStore(directoryURL: baseURL.appendingPathComponent("manual"))
        let manualClient = NetworkClient(transport: E2EAlwaysHTTP422Transport(), offlineWriteStore: manualStore)
        _ = try await manualClient.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(
                offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayConflictPolicy: .manualReview)
            )
        )
        _ = await manualClient.flushOfflineQueue(limit: 4)
        let manualSnapshot = await manualClient.offlineQueueSnapshot()
        #expect(manualSnapshot.count == 1)
        #expect(manualSnapshot[0].state == .manualReview)

        let dropStore = DiskOfflineWriteStore(directoryURL: baseURL.appendingPathComponent("drop"))
        let dropClient = NetworkClient(transport: E2EAlwaysHTTP422Transport(), offlineWriteStore: dropStore)
        _ = try await dropClient.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(
                offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayConflictPolicy: .drop)
            )
        )
        _ = await dropClient.flushOfflineQueue(limit: 4)
        #expect(await dropClient.offlineQueueDepth() == 0)
    }

    @Test
    func e2eEncryptedOfflineStoreRoundTripAndKeyUnavailableRecovery() async throws {
        guard e2eEnabled() else { return }

        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-Encrypt-\(UUID().uuidString)", isDirectory: true)
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/e2e-encrypt")!,
            body: Data("very-sensitive-body".utf8)
        )
        let cipher = AESGCMOfflineWriteStoreCipher(keyProvider: { e2eFixedKey() })
        let store = DiskOfflineWriteStore(directoryURL: queueURL, cipher: cipher)

        let client = NetworkClient(transport: E2EAlwaysSuccessTransport(), offlineWriteStore: store)
        _ = try await client.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        #expect(await client.offlineQueueDepth() == 1)

        let jsonFiles = try FileManager.default.contentsOfDirectory(at: queueURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "replay_success_index.json" }
        let payloadText = try String(data: Data(contentsOf: try #require(jsonFiles.first)), encoding: .utf8)
        #expect((payloadText ?? "").contains("very-sensitive-body") == false)

        let blockedCipher = AESGCMOfflineWriteStoreCipher(
            keyProvider: { throw OfflineWriteStoreCipherError.keyUnavailable }
        )
        let blockedStore = DiskOfflineWriteStore(directoryURL: queueURL, cipher: blockedCipher)
        let blockedClient = NetworkClient(transport: E2EAlwaysSuccessTransport(), offlineWriteStore: blockedStore)
        #expect(await blockedClient.offlineQueueDepth() == 0)

        let recoveredClient = NetworkClient(
            transport: E2EAlwaysSuccessTransport(),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL, cipher: cipher)
        )
        #expect(await recoveredClient.offlineQueueDepth() == 1)
    }

    @Test
    func e2eTelemetryOfflineQueueResultTypesIncludeNewTerminalValues() async throws {
        guard e2eEnabled() else { return }

        let request = APIRequest(method: .post, url: URL(string: "https://example.com/e2e-telemetry")!)
        let context = TelemetryOfflineQueueContext(
            type: .replaySuppressed,
            queueID: "q-id",
            requestKey: "k-id",
            attempt: 1,
            ageMilliseconds: 1,
            reason: "dedupe_success_window",
            willRetry: false,
            resultType: "dedupe_suppressed"
        )
        #expect(context.type == .replaySuppressed)
        #expect(context.resultType == "dedupe_suppressed")

        let hooks = NetworkTelemetryHooks(
            onRequestStart: { _ in _ = request.url.absoluteString },
            onRequestEnd: { _ in },
            onCoalescerEvent: { _ in },
            onRetryScheduled: { _ in },
            onRetryExhausted: { _ in },
            onRetrySkipped: { _ in },
            onRequestCancelled: { _ in },
            onQueueMetrics: { _ in },
            onOfflineQueueEvent: { _ in },
            onCircuitBreakerTransition: { _ in },
            onPolicyUpdated: { _ in }
        )
        #expect(hooks.onOfflineQueueEvent != nil)
        #expect(hooks.onPolicyUpdated != nil)
    }

    @Test
    func e2eOfflineQueueEventsStreamYieldsEnqueuedEvent() async throws {
        guard e2eEnabled() else { return }

        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClient-E2E-EventStream-\(UUID().uuidString)", isDirectory: true)
        let client = NetworkClient(
            transport: E2EAlwaysSuccessTransport(),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )
        let stream = client.offlineQueueEvents()

        let waiter = Task { () -> OfflineQueueEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/e2e-event-stream")!,
            body: Data("{\"name\":\"event\"}".utf8)
        )
        _ = try await client.enqueueWrite(
            request: request,
            authScope: "public",
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        let first = await waiter.value
        guard case .enqueued? = first else {
            Issue.record("Expected first offline queue event to be enqueued.")
            return
        }
    }
}
