import Foundation
import Testing
@testable import NovaNetworkClient

extension NetworkingCoverageTests {

    @Test
    func telemetryHooksEmitCoalescerRetryAndCancellationContracts() async {
        let recorder = TelemetryRecorder()

        let coalescingTransport = StubNetworkTransport(delayNanos: 150_000_000, response: .success(Data("ok".utf8)))
        let coalescingClient = NetworkClient(
            transport: coalescingTransport,
            telemetryHooks: .init(
                onCoalescerEvent: { context in Task { await recorder.appendCoalescer(context) } }
            )
        )
        let coalescingRequest = APIRequest(method: .get, url: URL(string: "https://example.com/telemetry-coalesced")!)
        async let first: Data = coalescingClient.load(request: coalescingRequest, authScope: nil)
        async let second: Data = coalescingClient.load(request: coalescingRequest, authScope: nil)
        _ = try? await (first, second)

        let retryTransport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let retryClient = NetworkClient(
            transport: retryTransport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            retryClock: ThrowingClock(),
            telemetryHooks: .init(
                onRetryScheduled: { context in Task { await recorder.appendRetry(context) } },
                onRequestCancelled: { context in Task { await recorder.appendCancellation(context) } }
            )
        )
        let retryRequest = APIRequest(method: .get, url: URL(string: "https://example.com/telemetry-retry-cancel")!)
        _ = try? await retryClient.load(request: retryRequest, authScope: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let coalescerTypes = await recorder.coalescerTypes()
        let coalescedJoinCount = coalescerTypes.filter { $0 == .coalesced }.count
        #expect(coalescerTypes.contains(.started))
        #expect(coalescerTypes.contains(.coalesced))
        #expect(coalescerTypes.contains(.finished))
        #expect(coalescedJoinCount == 1)
        #expect(await recorder.retryCount() == 1)
        #expect(await recorder.cancellationReasons().contains("retrySleepCancelled"))
    }

    @Test
    func telemetryHooksEmitOfflineQueueLifecycleContexts() async throws {
        let recorder = TelemetryRecorder()
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineTelemetry-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8)))
        let client = NetworkClient(
            transport: transport,
            offlineWriteStore: store,
            telemetryHooks: .init(
                onOfflineQueueEvent: { context in Task { await recorder.appendOfflineQueue(context) } }
            )
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/offline-telemetry")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        _ = await client.flushOfflineQueue()
        try? await Task.sleep(nanoseconds: 20_000_000)

        let events = await recorder.offlineQueueSnapshot()
        #expect(events.contains(where: { $0.type == .enqueued }))
        #expect(events.contains(where: { $0.type == .replayStarted }))
        #expect(events.contains(where: { $0.type == .replaySucceeded }))
        #expect(events.allSatisfy { !$0.queueID.isEmpty && !$0.requestKey.isEmpty })
        #expect(events.allSatisfy { ($0.ageMilliseconds ?? 0) >= 0 })

        guard let replayStarted = events.first(where: { $0.type == .replayStarted }) else {
            Issue.record("Expected replayStarted telemetry event")
            return
        }
        #expect(replayStarted.attempt == 1)
    }

    @Test
    func telemetryHooksDoNotEmitOfflineQueueSuccessOnTerminalFailure() async throws {
        let recorder = TelemetryRecorder()
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineTelemetryFail-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let transport = StubNetworkTransport(
            delayNanos: 0,
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 422, body: Data()))
        )
        let client = NetworkClient(
            transport: transport,
            offlineWriteStore: store,
            telemetryHooks: .init(
                onOfflineQueueEvent: { context in Task { await recorder.appendOfflineQueue(context) } }
            )
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/offline-telemetry-fail")!)

        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )
        _ = await client.flushOfflineQueue()
        try? await Task.sleep(nanoseconds: 20_000_000)

        let events = await recorder.offlineQueueSnapshot()
        #expect(!events.contains(where: { $0.type == .replaySucceeded }))
        let hasRetryFailure422 = events.contains { event in
            event.type == .replayFailed &&
                event.reason == "http_status_422" &&
                event.willRetry == true &&
                event.resultType == "failed"
        }
        #expect(hasRetryFailure422)
    }

    @Test
    func telemetryTypesAndHookInitializerCoverExtendedContexts() {
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/telemetry-types")!)
        let requestContext = TelemetryRequestContext(
            key: "k",
            attempt: 1,
            coalescingMode: .custom,
            request: request
        )
        let responseContext = TelemetryResponseContext(
            request: requestContext,
            response: nil,
            error: .cancelled,
            durationMilliseconds: 1
        )
        let retryExhausted = TelemetryRetryExhaustedContext(
            key: "k",
            attempts: 3,
            reason: "http_status_503",
            coalescingMode: .disabled,
            request: request
        )
        let transition = TelemetryCircuitBreakerTransitionContext(
            identifier: "host",
            fromState: "open",
            toState: "half_open",
            failureCount: 3,
            openDurationMilliseconds: 100
        )
        let retrySkipped = TelemetryRetrySkippedContext(
            key: "k",
            attempt: 1,
            reason: "budget_insufficient",
            coalescingMode: .default,
            request: request
        )
        let policyUpdated = TelemetryPolicyUpdateContext(
            scope: "host",
            changedFields: ["retry_policy"]
        )
        let offlineQueue = TelemetryOfflineQueueContext(
            type: .enqueued,
            queueID: "q1",
            requestKey: "k1",
            attempt: 0,
            ageMilliseconds: 12,
            reason: nil,
            willRetry: nil
        )

        if case .cancelled? = responseContext.error {
            #expect(Bool(true))
        } else {
            Issue.record("Expected cancelled error")
        }
        #expect(retryExhausted.coalescingMode == .disabled)
        #expect(transition.toState == "half_open")
        #expect(retrySkipped.reason == "budget_insufficient")
        #expect(policyUpdated.scope == "host")
        #expect(offlineQueue.type == .enqueued)

        let hooks = NetworkTelemetryHooks(
            onRequestStart: { _ in },
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
        #expect(hooks.onRetryExhausted != nil)
        #expect(hooks.onCircuitBreakerTransition != nil)
        #expect(hooks.onRetrySkipped != nil)
        #expect(hooks.onOfflineQueueEvent != nil)
        #expect(hooks.onPolicyUpdated != nil)
    }

    @Test
    func runtimePolicyUpdateCanBlockAndRestoreRequests() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/runtime-global")!)

        await client.updateRuntimePolicy(.init(deadlineBudgetSeconds: 0), scope: .global)
        do {
            _ = try await client.load(request: request, authScope: nil)
            Issue.record("Expected deadline budget failure from runtime policy")
        } catch let error as NetworkError {
            #expect(error.failureReason == .timeoutBudgetExhausted)
        } catch {
            Issue.record("Unexpected error")
        }

        await client.updateRuntimePolicy(.init(), scope: .global)
        let data = try await client.load(request: request, authScope: nil)
        #expect(data == Data("ok".utf8))
    }

    @Test
    func runtimePolicyEndpointOverridesHostAndGlobal() async throws {
        let transport = StubNetworkTransport(response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)

        await client.updateRuntimePolicy(.init(deadlineBudgetSeconds: 0), scope: .global)
        await client.updateRuntimePolicy(.init(deadlineBudgetSeconds: 1), scope: .host("example.com"))
        await client.updateRuntimePolicy(
            .init(deadlineBudgetSeconds: 0),
            scope: .endpoint(host: "example.com", pathPrefix: "/blocked")
        )

        let allowed = APIRequest(method: .get, url: URL(string: "https://example.com/allowed")!)
        let blocked = APIRequest(method: .get, url: URL(string: "https://example.com/blocked/path")!)
        let allowedData = try await client.load(request: allowed, authScope: nil)
        #expect(allowedData == Data("ok".utf8))

        do {
            _ = try await client.load(request: blocked, authScope: nil)
            Issue.record("Expected endpoint-scoped budget failure")
        } catch let error as NetworkError {
            #expect(error.failureReason == .timeoutBudgetExhausted)
        } catch {
            Issue.record("Unexpected error")
        }
    }

    @Test
    func telemetryRetryScheduledIncludesScopeSourceAndProfile() async throws {
        let recorder = TelemetryRecorder()
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 1, jitterRange: nil),
            telemetryHooks: .init(
                onRetryScheduled: { context in Task { await recorder.appendRetry(context) } },
                onPolicyUpdated: { context in Task { await recorder.appendPolicyUpdated(context) } }
            )
        )
        await client.updateRuntimePolicy(
            .init(
                retryPolicy: .init(
                    maxAttempts: 2,
                    jitterRange: nil,
                    adaptiveProfiles: [
                        .timeout: .init(maxAttempts: 2, baseDelayNanoseconds: 100_000_000, jitterRange: nil)
                    ]
                )
            ),
            scope: .host("example.com")
        )

        let request = APIRequest(method: .get, url: URL(string: "https://example.com/telemetry-runtime-retry")!)
        _ = try await client.load(request: request, authScope: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let retryEvents = await recorder.retrySnapshot()
        #expect(retryEvents.count == 1)
        guard let retry = retryEvents.first else {
            Issue.record("Expected one retry event")
            return
        }
        #expect(retry.scheduleSource == RetryScheduleSource.policy.rawValue)
        #expect(retry.retryProfile == RetryFailureCategory.timeout.rawValue)
        #expect(retry.policyScope == RuntimePolicySource.host.rawValue)

        let updateEvents = await recorder.policyUpdatedSnapshot()
        #expect(updateEvents.count == 1)
        #expect(updateEvents.first?.scope == RuntimePolicySource.host.rawValue)
    }

    @Test
    func cachePolicyBranchesCoverVaryAndServerCacheDirectives() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let expires = formatter.string(from: Date().addingTimeInterval(120))
        let transport = ScriptedNetworkTransport(
            responses: [
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: [
                            "Cache-Control": "max-age=0, stale-while-revalidate=30",
                            "Vary": "Accept-Language",
                            "Expires": expires
                        ],
                        body: Data("v1".utf8)
                    )
                ),
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: [
                            "Cache-Control": "max-age=0, stale-while-revalidate=30",
                            "Vary": "Accept-Language"
                        ],
                        body: Data("v2".utf8)
                    )
                ),
                .success(
                    NetworkResponse(
                        statusCode: 200,
                        headers: [
                            "Cache-Control": "max-age=0, stale-while-revalidate=30",
                            "Vary": "Accept-Language"
                        ],
                        body: Data("v2".utf8)
                    )
                )
            ]
        )
        let client = NetworkClient(
            transport: transport,
            fingerprintPolicy: .init(headerInclusion: .none)
        )
        let url = URL(string: "https://example.com/cache-vary-branches")!
        let en = APIRequest(method: .get, url: url, headers: ["Accept-Language": "en"])
        let fr = APIRequest(method: .get, url: url, headers: ["Accept-Language": "fr"])

        let first = try await client.load(request: en, authScope: nil as String?, cachePolicy: CachePolicy.cacheFirst(maxAge: 60))
        let second = try await client.load(request: en, authScope: nil as String?, cachePolicy: CachePolicy.cacheFirst(maxAge: 0))
        let third = try await client.load(request: fr, authScope: nil as String?, cachePolicy: CachePolicy.cacheFirst(maxAge: 60))
        let fourth = try await client.load(
            request: fr,
            authScope: nil as String?,
            cachePolicy: CachePolicy.cacheFirst(maxAge: 60)
        )

        #expect(first == Data("v1".utf8))
        #expect(second == Data("v1".utf8))
        #expect(third == Data("v2".utf8))
        #expect(fourth == Data("v2".utf8))
        let callCount = await transport.calls()
        #expect(callCount >= 2)
        #expect(callCount <= 3)
    }

    @Test
    func telemetryQueueMetricsExposeNumericDepthAndWaitMilliseconds() async throws {
        let recorder = TelemetryRecorder()
        let transport = StubNetworkTransport(delayNanos: 120_000_000, response: .success(Data("ok".utf8)))
        let client = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 1),
            telemetryHooks: .init(
                onQueueMetrics: { context in Task { await recorder.appendQueue(context) } }
            )
        )

        let first = APIRequest(method: .get, url: URL(string: "https://example.com/queue-a")!)
        let second = APIRequest(method: .get, url: URL(string: "https://example.com/queue-b")!)

        async let one = client.load(
            request: first,
            authScope: nil,
            options: .init(priority: .low, capacityScheduling: .queueByPriority)
        )
        try? await Task.sleep(nanoseconds: 15_000_000)
        async let two = client.load(
            request: second,
            authScope: nil,
            options: .init(priority: .high, capacityScheduling: .queueByPriority)
        )

        _ = try await (one, two)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let queueEvents = await recorder.queueSnapshot()
        #expect(!queueEvents.isEmpty)
        guard let firstQueueEvent = queueEvents.first else {
            Issue.record("Expected queue metrics event")
            return
        }
        #expect(firstQueueEvent.queueDepth >= 1)
        #expect(firstQueueEvent.waitMilliseconds >= 0)
    }

    @Test
    func networkObserverRetryLifecycleEventCountsAreConsistent() async throws {
        let recorder = EventRecorder()
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 2, jitterRange: nil),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry-lifecycle")!)

        _ = try await client.load(request: request, authScope: nil)
        try? await Task.sleep(nanoseconds: 20_000_000)

        let events = await recorder.snapshot()
        let attemptCount = events.reduce(0) { count, event in
            if case .requestAttempt = event { return count + 1 }
            return count
        }
        let retryCount = events.reduce(0) { count, event in
            if case .retryScheduled = event { return count + 1 }
            return count
        }
        let successCount = events.reduce(0) { count, event in
            if case .requestSucceeded = event { return count + 1 }
            return count
        }
        let failureCount = events.reduce(0) { count, event in
            if case .requestFailed = event { return count + 1 }
            return count
        }

        #expect(attemptCount == 2)
        #expect(retryCount == 1)
        #expect(successCount == 1)
        #expect(failureCount == 0)
    }

    @Test
    func networkObserverDoesNotEmitSuccessOnTerminalFailure() async {
        let recorder = EventRecorder()
        let transport = StubNetworkTransport(
            response: Result<NetworkResponse, NetworkError>.failure(.httpStatus(code: 503, body: Data()))
        )
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 1),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/terminal-failure")!)

        do {
            _ = try await client.load(request: request, authScope: nil)
            Issue.record("Expected failure")
        } catch {
            // expected
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let events = await recorder.snapshot()
        let successCount = events.reduce(0) { count, event in
            if case .requestSucceeded = event { return count + 1 }
            return count
        }
        let failureCount = events.reduce(0) { count, event in
            if case .requestFailed = event { return count + 1 }
            return count
        }

        #expect(successCount == 0)
        #expect(failureCount == 1)
    }

    @Test
    func retrySkipsWhenBudgetIsInsufficientForScheduledDelay() async {
        let recorder = EventRecorder()
        let transport = SequenceThrowingTransport(remainingFailures: 1, error: URLError(.timedOut))
        let client = NetworkClient(
            transport: transport,
            retryPolicy: .init(maxAttempts: 3, baseDelayNanoseconds: 1_000_000_000, jitterRange: nil),
            networkObserver: { event in Task { await recorder.append(event) } }
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/retry-budget-insufficient")!)

        do {
            _ = try await client.load(
                request: request,
                authScope: nil,
                options: .init(deadlineBudgetSeconds: 0.05)
            )
            Issue.record("Expected timeout budget exhaustion")
        } catch let error as NetworkError {
            if case .timeoutBudgetExceeded = error {
                // Expected path.
            } else {
                Issue.record("Expected timeout budget exhaustion")
            }
        } catch {
            Issue.record("Expected NetworkError.timeoutBudgetExceeded")
        }

        let events = await recorder.snapshot()
        let hasRetrySkippedBudget = events.contains { event in
            if case .retrySkipped(_, _, let reason) = event {
                return reason == "budget_insufficient"
            }
            return false
        }
        #expect(hasRetrySkippedBudget)
    }

    @Test
    func offlineQueueEventsStreamReceivesEnqueuedEvent() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineStream-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let client = NetworkClient(
            transport: StubNetworkTransport(delayNanos: 0, response: .success(Data("ok".utf8))),
            offlineWriteStore: store
        )
        let stream = client.offlineQueueEvents()

        let consumer = Task { () -> OfflineQueueEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let request = APIRequest(method: .post, url: URL(string: "https://example.com/offline-stream")!)
        _ = try await client.enqueueWrite(
            request: request,
            authScope: nil,
            options: .init(offlineQueuePolicy: .init(mode: .alwaysEnqueue))
        )

        guard case .enqueued? = await consumer.value else {
            Issue.record("Expected enqueued offline queue event")
            return
        }
    }}
