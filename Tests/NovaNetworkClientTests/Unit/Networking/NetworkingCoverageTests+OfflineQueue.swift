import Foundation
import Testing
@testable import NovaNetworkClient

extension NetworkingCoverageTests {

    @Test
    func requestExecutionOptionsOfflineQueuePolicyDefaultsToDisabled() {
        let options = RequestExecutionOptions()
        #expect(options.offlineQueuePolicy == .disabled)
    }

    @Test
    func enqueueWriteQueuesWhenOfflineAndAppliesDefaultIdempotencyKey() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineEnqueue-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(
                .transport(underlying: URLError(.notConnectedToInternet))
            )
        )
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/offline-write")!)

        let result = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .enqueueWhenOffline))
        )

        guard case .queued(let receipt) = result else {
            Issue.record("Expected queued write result")
            return
        }

        #expect(await transport.calls() == 1)
        let snapshot = await store.snapshot(now: Date())
        #expect(snapshot.count == 1)
        #expect(snapshot[0].receipt.queueID == receipt.queueID)
        #expect(
            snapshot[0].request.headers.keys.contains(where: { $0.lowercased() == "idempotency-key" })
        )
    }

    @Test
    func enqueueWriteAlwaysEnqueueSkipsNetwork() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-AlwaysEnqueue-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/always-enqueue")!)

        let result = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        guard case .queued = result else {
            Issue.record("Expected queued write result")
            return
        }

        #expect(await transport.calls() == 0)
        #expect(await store.depth(now: Date()) == 1)
    }

    @Test
    func enqueueWriteOfflineWithoutStoreThrowsUnavailable() async {
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(
                .transport(underlying: URLError(.notConnectedToInternet))
            )
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/no-store")!)

        do {
            _ = try await client.enqueueWrite(
                request: request,
                authScope: nil,
                options: .init(offlineQueuePolicy: .init(mode: .enqueueWhenOffline))
            )
            Issue.record("Expected offline queue unavailable")
        } catch let error as NetworkError {
            guard case .offlineQueueUnavailable = error else {
                Issue.record("Expected offlineQueueUnavailable")
                return
            }
        } catch {
            Issue.record("Unexpected error type")
        }
    }

    @Test
    func flushOfflineQueueReplaysQueuedWriteAndRemovesEntry() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-FlushReplay-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/flush")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        #expect(await store.depth(now: Date()) == 1)

        let replayed = await client.flushOfflineQueue()
        #expect(replayed == 1)
        #expect(await transport.calls() == 1)
        #expect(await store.depth(now: Date()) == 0)
    }

    @Test
    func flushOfflineQueueSuppressesDuplicateReplayWhenRecentSuccessExists() async throws {
        let recorder = TelemetryRecorder()
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-ReplayDedupe-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8)))
        let client = NetworkClient(
            transport: transport,
            offlineWriteStore: store,
            telemetryHooks: .init(
                onOfflineQueueEvent: { context in Task { await recorder.appendOfflineQueue(context) } }
            )
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/dedupe")!)
        let enqueueOptions = RequestExecutionOptions(
            idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
            offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayDedupeWindowSeconds: 3600)
        )

        _ = try await client.enqueueWrite(request: request, authScope: "user-1", options: enqueueOptions)
        _ = try await client.enqueueWrite(request: request, authScope: "user-1", options: enqueueOptions)
        #expect(await store.depth(now: Date()) == 2)

        let replayed = await client.flushOfflineQueue(limit: 8)
        #expect(replayed == 2)
        #expect(await transport.calls() == 1)
        #expect(await store.depth(now: Date()) == 0)

        try? await Task.sleep(nanoseconds: 20_000_000)
        let events = await recorder.offlineQueueSnapshot()
        let hasSuppressed = events.contains {
            $0.type == .replaySuppressed && $0.resultType == "dedupe_suppressed"
        }
        #expect(hasSuppressed)
    }

    @Test
    func flushOfflineQueueManualReviewPolicyMarksManualReviewState() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-DeadLetter-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 422, body: Data()))
        )
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/dead-letter")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(
                offlineQueuePolicy: .init(
                    mode: .alwaysEnqueue,
                    replayConflictPolicy: .manualReview
                )
            )
        )
        _ = await client.flushOfflineQueue()

        let snapshot = await store.snapshot(now: Date())
        #expect(snapshot.count == 1)
        #expect(snapshot[0].state == .manualReview)
        #expect(snapshot[0].lastFailureReason == "http_status_422")
    }

    @Test
    func flushOfflineQueueDropPolicyDropsTerminalConflict() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-DropConflict-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 422, body: Data()))
        )
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/drop-conflict")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(
                offlineQueuePolicy: .init(
                    mode: .alwaysEnqueue,
                    replayConflictPolicy: .drop
                )
            )
        )
        _ = await client.flushOfflineQueue()

        #expect(await store.depth(now: Date()) == 0)
    }

    @Test
    func flushOfflineQueueSchedulesRetryForRetriableFailure() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-RetryWaiting-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(
                .transport(underlying: URLError(.notConnectedToInternet))
            )
        )
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/retry-wait")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        _ = await client.flushOfflineQueue()

        let snapshot = await store.snapshot(now: Date())
        #expect(snapshot.count == 1)
        #expect(snapshot[0].state == .retryWaiting)
        #expect(snapshot[0].attempt == 1)
        #expect(snapshot[0].nextRetryAt != nil)
    }

    @Test
    func connectivityMonitorTriggersAutomaticOfflineQueueFlush() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-AutoFlush-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let monitor = TestConnectivityMonitor()
        let transport = StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8)))
        let client = NetworkClient(
            transport: transport,
            offlineWriteStore: store,
            offlineConnectivityMonitor: monitor
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/auto-flush")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        #expect(await store.depth(now: Date()) == 1)

        monitor.emit(true)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await store.depth(now: Date()) == 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(await store.depth(now: Date()) == 0)
        #expect(await transport.calls() == 1)
    }

    @Test
    func offlineQueueManagementAPIsSupportDepthSnapshotDropAndDropAll() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-QueueMgmt-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let client = NetworkClient(
            transport: StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8))),
            offlineWriteStore: store
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/manage")!)

        let first = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        let second = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        #expect(await client.offlineQueueDepth() == 2)
        let snapshot = await client.offlineQueueSnapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot[0].receipt.position < snapshot[1].receipt.position)

        guard case .queued(let firstReceipt) = first else {
            Issue.record("Expected first queued receipt")
            return
        }
        guard case .queued(let secondReceipt) = second else {
            Issue.record("Expected second queued receipt")
            return
        }
        #expect(await client.dropQueuedWrite(queueID: firstReceipt.queueID))
        #expect(await client.offlineQueueDepth() == 1)
        #expect(!(await client.dropQueuedWrite(queueID: firstReceipt.queueID)))

        let removed = await client.dropAllQueuedWrites()
        #expect(removed == 1)
        #expect(await client.offlineQueueDepth() == 0)
        #expect(
            (await client.offlineQueueSnapshot()).contains { $0.receipt.queueID == secondReceipt.queueID } == false
        )
    }

    @Test
    func offlineQueueManagementAPIsRemainConsistentAcrossClientRestart() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-QueueRestart-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/restart")!)
        let writerClient = NetworkClient(
            transport: StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8))),
            offlineWriteStore: store
        )
        _ = try await writerClient.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        let restoredClient = NetworkClient(
            transport: StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8))),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: baseURL)
        )
        #expect(await restoredClient.offlineQueueDepth() == 1)
        #expect((await restoredClient.offlineQueueSnapshot()).count == 1)
    }

    @Test
    func queuedWriteModelsExposeReceiptContract() {
        let queued = QueuedWriteResult.queued(
            QueuedWriteReceipt(queueID: "q1", requestKey: "k1", position: 0)
        )

        guard case .queued(let receipt) = queued else {
            Issue.record("Expected queued write result")
            return
        }

        #expect(receipt.queueID == "q1")
        #expect(receipt.requestKey == "k1")
        #expect(receipt.position == 1)
    }

    @Test
    func flushOfflineQueueSchedulerProtectsStarvedBackgroundItems() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-SchedulerStarvation-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = RequestRecordingTransport()
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let now = Date()

        let schedulerPolicy = OfflineReplaySchedulerPolicy(
            fairReplayWeights: [.critical: 4, .normal: 2, .background: 1],
            starvationProtectionAgeSeconds: 1,
            priorityBandLimits: [
                .init(priority: .critical, maxConsecutiveReplays: 3),
                .init(priority: .normal, maxConsecutiveReplays: 2),
                .init(priority: .background, maxConsecutiveReplays: 2)
            ]
        )

        let starvedBackground = APIRequest(method: .post, url: URL(string: "https://example.com/bkg-starved")!)
        _ = try await store.enqueue(
            request: starvedBackground,
            requestKey: "bkg-starved",
            replayMetadata: .init(
                replayIdentity: "bkg-starved",
                priority: .background,
                schedulerPolicy: schedulerPolicy
            ),
            now: now.addingTimeInterval(-120)
        )

        for idx in 0..<6 {
            let request = APIRequest(method: .post, url: URL(string: "https://example.com/critical-\(idx)")!)
            _ = try await store.enqueue(
                request: request,
                requestKey: "critical-\(idx)",
                replayMetadata: .init(
                    replayIdentity: "critical-\(idx)",
                    priority: .critical,
                    schedulerPolicy: schedulerPolicy
                ),
                now: now
            )
        }

        _ = await client.flushOfflineQueue(limit: 3)
        let replayOrder = await transport.snapshot()
        #expect(replayOrder.count == 3)
        #expect(replayOrder.contains("/bkg-starved"))
    }

    @Test
    func offlineConflictResolverCanOverridePolicyAndDropConflict() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-ConflictResolver-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let recorder = TelemetryRecorder()
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 422, body: Data()))
        )
        let client = NetworkClient(
            transport: transport,
            offlineWriteStore: store,
            offlineConflictResolver: { metadata in
                if metadata.statusCode == 422 {
                    return .drop(reason: "resolver_drop_422")
                }
                return .manualReview(reason: nil)
            },
            telemetryHooks: .init(
                onOfflineQueueEvent: { context in Task { await recorder.appendOfflineQueue(context) } }
            )
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/conflict-resolver")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(
                offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayConflictPolicy: .manualReview)
            )
        )

        _ = await client.flushOfflineQueue(limit: 4)
        #expect(await store.depth(now: Date()) == 0)

        let events = await recorder.offlineQueueSnapshot()
        let hasDroppedConflict = events.contains {
            $0.type == .replayDroppedConflict && $0.reason == "resolver_drop_422"
        }
        #expect(hasDroppedConflict)
    }

    @Test
    func replayManualReviewItemSchedulesPostResolutionReplay() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-ManualReviewReplay-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = ScriptedNetworkTransport(
            responses: [
                .failure(.httpStatus(code: 422, body: Data())),
                .success(.init(statusCode: 200, headers: [:], body: Data("ok".utf8)))
            ]
        )
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/manual-review-replay")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(
                offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayConflictPolicy: .manualReview)
            )
        )
        _ = await client.flushOfflineQueue(limit: 1)

        let manualSnapshot = await store.snapshot(now: Date())
        #expect(manualSnapshot.count == 1)
        #expect(manualSnapshot[0].state == .manualReview)

        let requeued = await client.replayManualReviewItem(
            queueID: manualSnapshot[0].receipt.queueID,
            resolutionReason: "resolved_by_user"
        )
        #expect(requeued)
        let afterRequeue = await store.snapshot(now: Date())
        #expect(afterRequeue.count == 1)
        #expect(afterRequeue[0].state == .replayScheduled)

        _ = await client.flushOfflineQueue(limit: 1)
        #expect(await store.depth(now: Date()) == 0)
    }

    @Test
    func offlineQueuePipelineMetricsExposeAgeThroughputAndOutcomes() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-PipelineMetrics-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport, offlineWriteStore: store)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/pipeline-metrics")!)
        let options = RequestExecutionOptions(
            idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
            offlineQueuePolicy: .init(mode: .alwaysEnqueue, replayDedupeWindowSeconds: 3600)
        )

        _ = try await client.enqueueWrite(request: request, authScope: "u1", options: options)
        _ = try await client.enqueueWrite(request: request, authScope: "u1", options: options)
        _ = await client.flushOfflineQueue(limit: 8)

        let metrics = await client.offlineQueuePipelineMetrics()
        #expect(metrics.replayThroughput.replayedCount >= 1)
        #expect(metrics.replayThroughput.replaysPerSecond >= 0)
        #expect(metrics.ageDistribution.maxSeconds >= metrics.ageDistribution.p50Seconds)
        #expect(metrics.ageDistribution.p95Seconds >= metrics.ageDistribution.p90Seconds)
        #expect((metrics.terminalOutcomes[.succeeded] ?? 0) >= 1)
        #expect(metrics.terminalOutcomes.values.reduce(0, +) >= 1)
    }
}
