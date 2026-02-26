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

private struct BenchmarkBaseline: Decodable {
    let maxElapsedMilliseconds: Double
    let maxTransportCalls: Int
}

private struct StressBaseline: Decodable {
    let retryStormExpectedTransportCalls: Int
    let retryStormExpectedSuccesses: Int
    let breakerFlappingMinimumTransitions: Int
    let runtimeUpdateMinimumSuccesses: Int
}

@main
struct BenchmarksMain {
    static func main() async {
        let args = Set(CommandLine.arguments.dropFirst())
        let shouldRunStressSuite = args.contains("--stress-suite") || args.contains("--check-stress-baseline")
        let shouldCheckBaseline = args.contains("--check-baseline")
        let shouldCheckStressBaseline = args.contains("--check-stress-baseline")

        if shouldRunStressSuite {
            await runStressSuite(checkBaseline: shouldCheckStressBaseline)
            return
        }

        let transport = BenchmarkTransport(delayNanoseconds: 1_000_000)
        let client = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 64, maxWaitersPerKey: 10_000)
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/benchmark")!)
        let iterations = 2_000

        let start = DispatchTime.now().uptimeNanoseconds
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    _ = try? await client.load(request: request, authScope: "bench")
                }
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds

        let elapsedMs = Double(end - start) / 1_000_000
        let calls = await transport.calls
        print("benchmark_iterations=\(iterations)")
        print("transport_calls=\(calls)")
        print(String(format: "elapsed_ms=%.2f", elapsedMs))

        if shouldCheckBaseline {
            let baselineURL = URL(fileURLWithPath: "Benchmarks/baseline.json")
            guard
                let data = try? Data(contentsOf: baselineURL),
                let baseline = try? JSONDecoder().decode(BenchmarkBaseline.self, from: data)
            else {
                fputs("baseline_check=skipped missing_or_invalid_baseline\n", stderr)
                return
            }

            let elapsedOK = elapsedMs <= baseline.maxElapsedMilliseconds
            let callsOK = calls <= baseline.maxTransportCalls
            if elapsedOK && callsOK {
                print("baseline_check=passed")
                return
            }

            fputs(
                "baseline_check=failed elapsed_ms=\(elapsedMs) max_elapsed_ms=\(baseline.maxElapsedMilliseconds) transport_calls=\(calls) max_transport_calls=\(baseline.maxTransportCalls)\n",
                stderr
            )
            Foundation.exit(1)
        }
    }

    private static func runStressSuite(checkBaseline: Bool) async {
        let retryStorm = await runRetryStormScenario()
        let breakerFlapping = await runBreakerFlappingScenario()
        let runtimeUpdates = await runRuntimePolicyUpdateScenario()

        print("stress_retry_storm_transport_calls=\(retryStorm.transportCalls)")
        print("stress_retry_storm_successes=\(retryStorm.successes)")
        print("stress_retry_storm_failures=\(retryStorm.failures)")
        print("stress_breaker_flapping_transitions=\(breakerFlapping.breakerTransitions)")
        print("stress_breaker_flapping_transport_calls=\(breakerFlapping.transportCalls)")
        print("stress_runtime_policy_successes=\(runtimeUpdates.successes)")
        print("stress_runtime_policy_failures=\(runtimeUpdates.failures)")

        guard checkBaseline else { return }

        let baselineURL = URL(fileURLWithPath: "Benchmarks/stress_baseline.json")
        guard
            let data = try? Data(contentsOf: baselineURL),
            let baseline = try? JSONDecoder().decode(StressBaseline.self, from: data)
        else {
            fputs("stress_baseline_check=skipped missing_or_invalid_baseline\n", stderr)
            return
        }

        let retryCallsOK = retryStorm.transportCalls == baseline.retryStormExpectedTransportCalls
        let retrySuccessOK = retryStorm.successes == baseline.retryStormExpectedSuccesses
        let breakerOK = breakerFlapping.breakerTransitions >= baseline.breakerFlappingMinimumTransitions
        let runtimeOK = runtimeUpdates.successes >= baseline.runtimeUpdateMinimumSuccesses

        if retryCallsOK, retrySuccessOK, breakerOK, runtimeOK {
            print("stress_baseline_check=passed")
            return
        }

        fputs(
            """
            stress_baseline_check=failed retry_calls=\(retryStorm.transportCalls) expected_retry_calls=\(baseline.retryStormExpectedTransportCalls) retry_successes=\(retryStorm.successes) expected_retry_successes=\(baseline.retryStormExpectedSuccesses) breaker_transitions=\(breakerFlapping.breakerTransitions) min_breaker_transitions=\(baseline.breakerFlappingMinimumTransitions) runtime_successes=\(runtimeUpdates.successes) min_runtime_successes=\(baseline.runtimeUpdateMinimumSuccesses)\n
            """,
            stderr
        )
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
        let iterations = 120
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
                halfOpenJitterSeconds: 0.001
            )
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/stress-breaker")!)

        for _ in 0..<120 {
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
            for index in 0..<200 {
                if index.isMultiple(of: 3) {
                    await client.updateRuntimePolicy(.init(deadlineBudgetSeconds: 0.001), scope: .global)
                } else {
                    await client.updateRuntimePolicy(.init(), scope: .global)
                }
                await Task.yield()
            }
        }

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
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
}

private extension URL {
    func queryItemValue(named name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
