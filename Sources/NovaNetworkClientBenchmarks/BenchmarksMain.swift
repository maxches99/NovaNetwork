#if canImport(Darwin)
import Darwin.Mach
#endif
import Foundation
import NovaNetworkClient

actor BenchmarkTransport: NetworkTransport {
    private(set) var calls = 0
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))
    }
}

actor RetryStormTransport: NetworkTransport {
    private(set) var calls = 0
    private var attemptsByID: [String: Int] = [:]
    let failuresBeforeSuccess: Int
    let delayNanoseconds: UInt64

    init(failuresBeforeSuccess: Int, delayNanoseconds: UInt64) {
        self.failuresBeforeSuccess = max(0, failuresBeforeSuccess)
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let id = request.url.queryItemValue(named: "id") ?? "unknown"
        let nextAttempt = (attemptsByID[id] ?? 0) + 1
        attemptsByID[id] = nextAttempt
        if nextAttempt <= failuresBeforeSuccess {
            throw NetworkError.transport(underlying: URLError(.timedOut))
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))
    }
}

actor FlappingTransport: NetworkTransport {
    private(set) var calls = 0
    private var nextFails = true

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        defer { nextFails.toggle() }
        if nextFails {
            throw NetworkError.httpStatus(code: 503, body: Data())
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))
    }
}

actor EventCounter {
    private(set) var breakerTransitions = 0

    func append(_ event: NetworkClientEvent) {
        if case .circuitBreakerTransition = event {
            breakerTransitions += 1
        }
    }
}

actor LatencyCollector {
    private var values: [Double] = []

    func append(_ value: Double) {
        values.append(value)
    }

    func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = Int(Double(sorted.count - 1) * p)
        return sorted[max(0, min(position, sorted.count - 1))]
    }
}

private struct BenchmarkBaseline: Decodable {
    let maxElapsedMilliseconds: Double
    let maxTransportCalls: Int
    let maxP95LatencyMilliseconds: Double
    let maxAllocatedBytesDelta: UInt64
}

private struct StressBaseline: Decodable {
    let retryStormExpectedTransportCalls: Int
    let retryStormExpectedSuccesses: Int
    let breakerFlappingMinimumTransitions: Int
    let runtimeUpdateMinimumSuccesses: Int
    let mixedPriorityMinimumSuccesses: Int
    let mixedPriorityMaximumP99LatencyMilliseconds: Double
    let cancellationBurstMinimumCancelled: Int
    let cancellationBurstMinimumSuccesses: Int
    let offlineRealtimeMinimumReplayed: Int
    let offlineRealtimeMinimumRealtimeSuccesses: Int
    let offlineRealtimeMaximumP99LatencyMilliseconds: Double
    let offlineRealtimeMaximumTransportCalls: Int
}

@main
struct BenchmarksMain {
    static func main() async {
        let args = Set(CommandLine.arguments.dropFirst())
        let shouldRunStressSuite = args.contains("--stress-suite") || args.contains("--check-stress-baseline")
        let shouldCheckBaseline = args.contains("--check-baseline")
        // Timing budgets are enforced only when asked for, because CI runners are shared.
        let strictTiming = args.contains("--strict-timing")
        let shouldCheckStressBaseline = args.contains("--check-stress-baseline")

        if shouldRunStressSuite {
            await runStressSuite(checkBaseline: shouldCheckStressBaseline, strictTiming: strictTiming)
            return
        }

        let transport = BenchmarkTransport(delayNanoseconds: 1_000_000)
        let client = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 64, maxWaitersPerKey: 10_000)
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/benchmark")!)
        let iterations = 2_000
        let latencyCollector = LatencyCollector()

        let allocatedBefore = currentMemoryFootprintBytes()
        let start = DispatchTime.now().uptimeNanoseconds
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    let opStart = DispatchTime.now().uptimeNanoseconds
                    _ = try? await client.load(request: request, authScope: "bench")
                    let opElapsedMs = Double(DispatchTime.now().uptimeNanoseconds - opStart) / 1_000_000
                    await latencyCollector.append(opElapsedMs)
                }
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds
        let allocatedAfter = currentMemoryFootprintBytes()

        let elapsedMs = Double(end - start) / 1_000_000
        let calls = await transport.calls
        let p95Latency = await latencyCollector.percentile(0.95)
        let allocatedDelta = memoryDeltaBytes(before: allocatedBefore, after: allocatedAfter)

        print("benchmark_iterations=\(iterations)")
        print("transport_calls=\(calls)")
        print(String(format: "elapsed_ms=%.2f", elapsedMs))
        print(String(format: "p95_latency_ms=%.2f", p95Latency))
        if let allocatedDelta {
            print("allocated_delta_bytes=\(allocatedDelta)")
        } else {
            print("allocated_delta_bytes=unknown")
        }

        if shouldCheckBaseline {
            let baselineURL = URL(fileURLWithPath: "Benchmarks/baseline.json")
            guard
                let data = try? Data(contentsOf: baselineURL),
                let baseline = try? JSONDecoder().decode(BenchmarkBaseline.self, from: data)
            else {
                // Asking for the check and not being able to perform it is a failure, not a pass.
                // The path is relative to the working directory, so a job run from the wrong place
                // would otherwise report success without having compared anything.
                reportToStandardError("baseline_check=failed reason=missing_or_invalid_baseline path=\(baselineURL.path)\n")
                Foundation.exit(1)
            }

            let elapsedOK = elapsedMs <= baseline.maxElapsedMilliseconds
            let callsOK = calls <= baseline.maxTransportCalls
            let latencyOK = p95Latency <= baseline.maxP95LatencyMilliseconds
            let allocationOK = (allocatedDelta ?? 0) <= baseline.maxAllocatedBytesDelta

            // How many calls the transport saw is a property of the code: coalescing, retry, and
            // caching decide it, and the answer is the same on any machine. Elapsed time, latency,
            // and allocations are properties of the machine as much as the code, so on a shared
            // runner they are reported and not enforced -- a budget that fails because a
            // neighbouring job was busy teaches a team to ignore the gate.
            let timingIsAdvisory = !strictTiming
            if !callsOK {
                reportToStandardError("baseline_check=failed reason=transport_calls transport_calls=\(calls) max_transport_calls=\(baseline.maxTransportCalls)\n")
                Foundation.exit(1)
            }

            if elapsedOK && latencyOK && allocationOK {
                print("baseline_check=passed")
                return
            }

            let detail = "elapsed_ms=\(elapsedMs) max_elapsed_ms=\(baseline.maxElapsedMilliseconds) p95_latency_ms=\(p95Latency) max_p95_latency_ms=\(baseline.maxP95LatencyMilliseconds) allocated_delta_bytes=\(allocatedDelta ?? 0) max_allocated_delta_bytes=\(baseline.maxAllocatedBytesDelta)"
            guard timingIsAdvisory else {
                reportToStandardError("baseline_check=failed reason=timing \(detail)\n")
                Foundation.exit(1)
            }
            reportToStandardError("baseline_check=advisory reason=timing \(detail)\n")
            print("baseline_check=passed_with_advisory")
        }
    }

    private static func runStressSuite(checkBaseline: Bool, strictTiming: Bool) async {
        let retryStorm = await runRetryStormScenario()
        let breakerFlapping = await runBreakerFlappingScenario()
        let runtimeUpdates = await runRuntimePolicyUpdateScenario()
        let mixedPriority = await runMixedPriorityQueuePressureScenario()
        let cancellationBurst = await runCancellationBurstScenario()
        let offlineRealtime = await runOfflineRealtimeCombinedScenario()

        print("stress_retry_storm_transport_calls=\(retryStorm.transportCalls)")
        print("stress_retry_storm_successes=\(retryStorm.successes)")
        print("stress_retry_storm_failures=\(retryStorm.failures)")
        print("stress_breaker_flapping_transitions=\(breakerFlapping.breakerTransitions)")
        print("stress_breaker_flapping_transport_calls=\(breakerFlapping.transportCalls)")
        print("stress_runtime_policy_successes=\(runtimeUpdates.successes)")
        print("stress_runtime_policy_failures=\(runtimeUpdates.failures)")
        print("stress_mixed_priority_successes=\(mixedPriority.successes)")
        print("stress_mixed_priority_failures=\(mixedPriority.failures)")
        print(String(format: "stress_mixed_priority_p95_ms=%.2f", mixedPriority.p95LatencyMilliseconds))
        print(String(format: "stress_mixed_priority_p99_ms=%.2f", mixedPriority.p99LatencyMilliseconds))
        print("stress_cancellation_burst_cancelled=\(cancellationBurst.cancelled)")
        print("stress_cancellation_burst_successes=\(cancellationBurst.successes)")
        print("stress_offline_realtime_replayed=\(offlineRealtime.replayed)")
        print("stress_offline_realtime_realtime_successes=\(offlineRealtime.realtimeSuccesses)")
        print("stress_offline_realtime_realtime_failures=\(offlineRealtime.realtimeFailures)")
        print("stress_offline_realtime_transport_calls=\(offlineRealtime.transportCalls)")
        print(String(format: "stress_offline_realtime_p95_ms=%.2f", offlineRealtime.realtimeP95LatencyMilliseconds))
        print(String(format: "stress_offline_realtime_p99_ms=%.2f", offlineRealtime.realtimeP99LatencyMilliseconds))

        guard checkBaseline else { return }

        let baselineURL = URL(fileURLWithPath: "Benchmarks/stress_baseline.json")
        guard
            let data = try? Data(contentsOf: baselineURL),
            let baseline = try? JSONDecoder().decode(StressBaseline.self, from: data)
        else {
            reportToStandardError("stress_baseline_check=failed reason=missing_or_invalid_baseline path=\(baselineURL.path)\n")
            Foundation.exit(1)
        }

        let retryCallsOK = retryStorm.transportCalls == baseline.retryStormExpectedTransportCalls
        let retrySuccessOK = retryStorm.successes == baseline.retryStormExpectedSuccesses
        let breakerOK = breakerFlapping.breakerTransitions >= baseline.breakerFlappingMinimumTransitions
        let runtimeOK = runtimeUpdates.successes >= baseline.runtimeUpdateMinimumSuccesses
        let mixedPriorityOK = mixedPriority.successes >= baseline.mixedPriorityMinimumSuccesses
        let mixedPriorityLatencyOK = mixedPriority.p99LatencyMilliseconds <= baseline.mixedPriorityMaximumP99LatencyMilliseconds
        let cancellationCancelledOK = cancellationBurst.cancelled >= baseline.cancellationBurstMinimumCancelled
        let cancellationSuccessOK = cancellationBurst.successes >= baseline.cancellationBurstMinimumSuccesses
        let offlineRealtimeReplayedOK = offlineRealtime.replayed >= baseline.offlineRealtimeMinimumReplayed
        let offlineRealtimeRealtimeSuccessOK = offlineRealtime.realtimeSuccesses >= baseline.offlineRealtimeMinimumRealtimeSuccesses
        let offlineRealtimeLatencyOK = offlineRealtime.realtimeP99LatencyMilliseconds <= baseline.offlineRealtimeMaximumP99LatencyMilliseconds
        let offlineRealtimeCallsOK = offlineRealtime.transportCalls <= baseline.offlineRealtimeMaximumTransportCalls

        // Counts and outcomes are decided by the code and hold on any machine; the two p99 budgets
        // are decided partly by the runner, so they advise unless timing is explicitly enforced.
        let behaviorOK = retryCallsOK
            && retrySuccessOK
            && breakerOK
            && runtimeOK
            && mixedPriorityOK
            && cancellationCancelledOK
            && cancellationSuccessOK
            && offlineRealtimeReplayedOK
            && offlineRealtimeRealtimeSuccessOK
            && offlineRealtimeCallsOK
        let latencyOK = mixedPriorityLatencyOK && offlineRealtimeLatencyOK

        if behaviorOK, latencyOK || !strictTiming {
            if latencyOK {
                print("stress_baseline_check=passed")
            } else {
                reportToStandardError("stress_baseline_check=advisory reason=timing mixed_priority_p99_ms=\(mixedPriority.p99LatencyMilliseconds) offline_realtime_p99_ms=\(offlineRealtime.realtimeP99LatencyMilliseconds)\n")
                print("stress_baseline_check=passed_with_advisory")
            }
            return
        }

        reportToStandardError("""
            stress_baseline_check=failed retry_calls=\(retryStorm.transportCalls) expected_retry_calls=\(baseline.retryStormExpectedTransportCalls) retry_successes=\(retryStorm.successes) expected_retry_successes=\(baseline.retryStormExpectedSuccesses) breaker_transitions=\(breakerFlapping.breakerTransitions) min_breaker_transitions=\(baseline.breakerFlappingMinimumTransitions) runtime_successes=\(runtimeUpdates.successes) min_runtime_successes=\(baseline.runtimeUpdateMinimumSuccesses) mixed_priority_successes=\(mixedPriority.successes) min_mixed_priority_successes=\(baseline.mixedPriorityMinimumSuccesses) mixed_priority_p99_ms=\(mixedPriority.p99LatencyMilliseconds) max_mixed_priority_p99_ms=\(baseline.mixedPriorityMaximumP99LatencyMilliseconds) cancellation_cancelled=\(cancellationBurst.cancelled) min_cancellation_cancelled=\(baseline.cancellationBurstMinimumCancelled) cancellation_successes=\(cancellationBurst.successes) min_cancellation_successes=\(baseline.cancellationBurstMinimumSuccesses) offline_realtime_replayed=\(offlineRealtime.replayed) min_offline_realtime_replayed=\(baseline.offlineRealtimeMinimumReplayed) offline_realtime_successes=\(offlineRealtime.realtimeSuccesses) min_offline_realtime_successes=\(baseline.offlineRealtimeMinimumRealtimeSuccesses) offline_realtime_p99_ms=\(offlineRealtime.realtimeP99LatencyMilliseconds) max_offline_realtime_p99_ms=\(baseline.offlineRealtimeMaximumP99LatencyMilliseconds) offline_realtime_transport_calls=\(offlineRealtime.transportCalls) max_offline_realtime_transport_calls=\(baseline.offlineRealtimeMaximumTransportCalls)\n
            """)
        Foundation.exit(1)
    }

    private static func runRetryStormScenario() async -> (transportCalls: Int, successes: Int, failures: Int) {
        let transport = RetryStormTransport(failuresBeforeSuccess: 1, delayNanoseconds: 0)
        let retryPolicy = RetryPolicy(
            maxAttempts: 2,
            baseDelayNanoseconds: 100_000,
            maxDelayNanoseconds: 100_000,
            jitterRange: nil,
            adaptiveProfiles: [
                .timeout: .init(maxAttempts: 2, baseDelayNanoseconds: 100_000, maxDelayNanoseconds: 100_000, jitterRange: nil)
            ]
        )
        let client = NetworkClient(transport: transport, retryPolicy: retryPolicy)
        let iterations = 80
        var successes = 0
        var failures = 0

        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<iterations {
                group.addTask {
                    let request = APIRequest(
                        method: .get,
                        url: URL(string: "https://example.com/stress-retry?id=\(index)")!
                    )
                    do {
                        _ = try await client.load(
                            request: request,
                            authScope: "bench",
                            options: .init(coalescingMode: .disabled)
                        )
                        return true
                    } catch {
                        return false
                    }
                }
            }

            for await success in group {
                if success {
                    successes += 1
                } else {
                    failures += 1
                }
            }
        }

        return (await transport.calls, successes, failures)
    }

    private static func runBreakerFlappingScenario() async -> (transportCalls: Int, breakerTransitions: Int) {
        let transport = FlappingTransport()
        let counter = EventCounter()
        let client = NetworkClient(
            transport: transport,
            networkObserver: { event in
                Task { await counter.append(event) }
            }
        )
        let options = RequestExecutionOptions(
            circuitBreakerPolicy: .init(
                scope: .host,
                failureThreshold: 1,
                cooldownSeconds: 0,
                halfOpenJitterSeconds: 0,
                probePolicy: .singleProbe
            )
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/stress-breaker")!)

        for _ in 0..<80 {
            _ = try? await client.load(
                request: request,
                authScope: "bench",
                options: options
            )
        }
        try? await Task.sleep(nanoseconds: 20_000_000)

        return (await transport.calls, await counter.breakerTransitions)
    }

    private static func runRuntimePolicyUpdateScenario() async -> (successes: Int, failures: Int) {
        let transport = BenchmarkTransport(delayNanoseconds: 100_000)
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/stress-runtime")!)

        var successes = 0
        var failures = 0
        let updates = Task {
            for index in 0..<120 {
                if index.isMultiple(of: 3) {
                    await client.updateRuntimePolicy(.init(deadlineBudgetSeconds: 0.001), scope: .global)
                } else {
                    await client.updateRuntimePolicy(.init(), scope: .global)
                }
                await Task.yield()
            }
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<120 {
                group.addTask {
                    do {
                        _ = try await client.load(request: request, authScope: "bench", options: .init(coalescingMode: .disabled))
                        return true
                    } catch {
                        return false
                    }
                }
            }
            for await success in group {
                if success {
                    successes += 1
                } else {
                    failures += 1
                }
            }
        }

        _ = await updates.result
        await client.updateRuntimePolicy(.init(), scope: .global)
        return (successes, failures)
    }

    private static func runMixedPriorityQueuePressureScenario() async -> (
        successes: Int,
        failures: Int,
        p95LatencyMilliseconds: Double,
        p99LatencyMilliseconds: Double
    ) {
        let transport = BenchmarkTransport(delayNanoseconds: 1_000_000)
        let client = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 1, maxWaitersPerKey: 10_000)
        )
        let collector = LatencyCollector()
        let iterations = 80

        var successes = 0
        var failures = 0
        await withTaskGroup(of: Bool.self) { group in
            for index in 0..<iterations {
                group.addTask {
                    let priority: RequestPriority = switch index % 3 {
                    case 0: .high
                    case 1: .medium
                    default: .low
                    }
                    let request = APIRequest(
                        method: .get,
                        url: URL(string: "https://example.com/stress-mixed-priority?id=\(index)")!
                    )
                    let startedAt = DispatchTime.now().uptimeNanoseconds
                    do {
                        _ = try await client.load(
                            request: request,
                            authScope: "bench",
                            options: .init(
                                priority: priority,
                                capacityScheduling: .queueByPriority,
                                coalescingMode: .disabled
                            )
                        )
                        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                        await collector.append(elapsedMs)
                        return true
                    } catch {
                        return false
                    }
                }
            }

            for await success in group {
                if success {
                    successes += 1
                } else {
                    failures += 1
                }
            }
        }

        return (
            successes,
            failures,
            await collector.percentile(0.95),
            await collector.percentile(0.99)
        )
    }

    private static func runCancellationBurstScenario() async -> (cancelled: Int, successes: Int) {
        let coalescer = RequestCoalescer<Data, NetworkError>(policy: .cancelWhenNoWaiters)
        let total = 80
        let toCancel = 45

        var tasks: [Task<Bool, Never>] = []
        tasks.reserveCapacity(total)

        for _ in 0..<total {
            tasks.append(
                Task {
                    do {
                        _ = try await coalescer.run(key: "cancellation-burst") {
                            do {
                                try await Task.sleep(nanoseconds: 120_000_000)
                                return .success(Data("ok".utf8))
                            } catch {
                                return .failure(.cancelled)
                            }
                        }
                        return true
                    } catch {
                        return false
                    }
                }
            )
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        for task in tasks.prefix(toCancel) {
            task.cancel()
        }

        var successes = 0
        for task in tasks {
            if await task.value {
                successes += 1
            }
        }
        let metrics = await coalescer.snapshotMetrics()
        return (metrics.waiterCancellations, successes)
    }

    private static func runOfflineRealtimeCombinedScenario() async -> (
        replayed: Int,
        realtimeSuccesses: Int,
        realtimeFailures: Int,
        realtimeP95LatencyMilliseconds: Double,
        realtimeP99LatencyMilliseconds: Double,
        transportCalls: Int
    ) {
        let queueURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-Benchmark-Combined-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: queueURL)
        let transport = BenchmarkTransport(delayNanoseconds: 300_000)
        let offlineClient = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 8, maxWaitersPerKey: 4_096),
            offlineWriteStore: store
        )
        let realtimeClient = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 8, maxWaitersPerKey: 4_096)
        )
        let collector = LatencyCollector()
        let queuedWriteRequest = APIRequest(method: .post, url: URL(string: "https://example.com/stress-combined-write")!)
        let realtimeRequestBase = URL(string: "https://example.com/stress-combined-read")!
        let queueEntries = 20
        let realtimeIterations = 40
        let replayWindow = OfflineReplayWindowPolicy(
            maxContinuousReplaySeconds: 8,
            coolDownSeconds: 0,
            maxReplaysPerSecond: 1_000
        )
        let combinedSchedulerPolicy = OfflineReplaySchedulerPolicy(replayWindow: replayWindow)

        for index in 0..<queueEntries {
            _ = try? await offlineClient.enqueueWrite(
                request: queuedWriteRequest,
                authScope: "bench-\(index)",
                options: .init(
                    idempotencyPolicy: .init(keyStrategy: .fingerprintDigest),
                    offlineQueuePolicy: .init(
                        mode: .alwaysEnqueue,
                        replayDedupeWindowSeconds: 0,
                        replaySchedulerPolicy: combinedSchedulerPolicy
                    )
                )
            )
        }

        let replayTask = Task {
            let queuedEntries = await store.snapshot(now: Date())
            var replayed = 0
            for entry in queuedEntries {
                do {
                    _ = try await offlineClient.load(
                        request: entry.request,
                        authScope: nil,
                        options: .init(coalescingMode: .disabled)
                    )
                    await store.markSucceeded(queueID: entry.receipt.queueID)
                    replayed += 1
                } catch {
                    await store.markRetryWaiting(
                        queueID: entry.receipt.queueID,
                        attempt: max(1, entry.attempt + 1),
                        reason: "combined_replay_failed",
                        nextRetryAt: Date().addingTimeInterval(1),
                        now: Date()
                    )
                }
            }
            return replayed
        }
        var realtimeSuccesses = 0
        var realtimeFailures = 0
        for index in 0..<realtimeIterations {
            let request = APIRequest(
                method: .get,
                url: realtimeRequestBase.appendingQueryItem(name: "id", value: "\(index)")
            )
            let startedAt = DispatchTime.now().uptimeNanoseconds
            do {
                _ = try await realtimeClient.load(
                    request: request,
                    authScope: "bench",
                    options: .init(
                        priority: .high,
                        capacityScheduling: .queueByPriority,
                        coalescingMode: .disabled
                    )
                )
                let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
                await collector.append(elapsedMs)
                realtimeSuccesses += 1
            } catch {
                realtimeFailures += 1
            }
        }

        let replayed = await replayTask.value
        return (
            replayed,
            realtimeSuccesses,
            realtimeFailures,
            await collector.percentile(0.95),
            await collector.percentile(0.99),
            await transport.calls
        )
    }
}

private extension URL {
    func queryItemValue(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }

    func appendingQueryItem(name: String, value: String) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url ?? self
    }
}

/// The process's memory footprint, on the platforms that can report it.
///
/// `task_info` is Mach, so on Linux this returns `nil` and the benchmark prints
/// `allocated_delta_bytes=unknown` -- which the allocation budget already treats as absent rather
/// than as zero.
#if canImport(Darwin)
private func currentMemoryFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return info.phys_footprint
}
#else
private func currentMemoryFootprintBytes() -> UInt64? { nil }
#endif

private func memoryDeltaBytes(before: UInt64?, after: UInt64?) -> UInt64? {
    guard let before, let after, after >= before else { return nil }
    return after - before
}

/// Writes a diagnostic line to standard error.
///
/// `fputs(_:stderr)` is not usable here: on Glibc `stderr` is a global `var`, which strict
/// concurrency rejects as shared mutable state. `FileHandle.standardError` says the same thing in a
/// way both platforms accept.
private func reportToStandardError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
