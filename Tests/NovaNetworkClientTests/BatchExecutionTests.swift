import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-BATCH-1...4, EC-1...2, AR-1.

private actor BatchTestTransport: NetworkTransport {
    private var active = 0
    private var peakActive = 0
    private var startedPaths: [String] = []
    private var cancelledCount = 0
    private let delayNanoseconds: UInt64
    private let failingPaths: Set<String>

    init(delayNanoseconds: UInt64 = 10_000_000, failingPaths: Set<String> = []) {
        self.delayNanoseconds = delayNanoseconds
        self.failingPaths = failingPaths
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        let path = request.url.path
        active += 1
        peakActive = max(peakActive, active)
        startedPaths.append(path)

        do {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        } catch {
            active -= 1
            cancelledCount += 1
            throw CancellationError()
        }

        active -= 1
        if failingPaths.contains(path) {
            throw NetworkError.httpStatus(code: 500, body: Data(path.utf8))
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: Data(path.utf8))
    }

    func peak() -> Int { peakActive }
    func started() -> [String] { startedPaths }
    func cancellations() -> Int { cancelledCount }
}

private actor BatchTelemetryProbe {
    private var contexts: [TelemetryBatchContext] = []

    func append(_ context: TelemetryBatchContext) {
        contexts.append(context)
    }

    func last() -> TelemetryBatchContext? {
        contexts.last
    }
}

@Suite
struct BatchExecutionTests {
    private func requests(count: Int) -> [APIRequest] {
        (0..<count).map { index in
            APIRequest(method: .get, url: URL(string: "https://example.com/\(index)")!)
        }
    }

    @Test
    func batchRespectsConcurrencyBoundAndPreservesOrder() async throws {
        let transport = BatchTestTransport()
        let client = NetworkClient(transport: transport)

        let values = try await client.loadBatch(
            requests: requests(count: 8),
            authScope: nil,
            batchOptions: .init(maxConcurrentRequests: 2)
        )

        #expect(values.map { String(decoding: $0, as: UTF8.self) } == (0..<8).map { "/\($0)" })
        #expect(await transport.peak() == 2)
    }

    @Test
    func collectingBatchReturnsSuccessesAndFailuresInInputOrder() async throws {
        let transport = BatchTestTransport(failingPaths: ["/1"])
        let client = NetworkClient(transport: transport)

        let results = try await client.loadBatchResults(
            requests: requests(count: 3),
            authScope: nil,
            batchOptions: .init(maxConcurrentRequests: 3)
        )

        #expect(results.map(\.index) == [0, 1, 2])
        #expect(results[0].result.isSuccess)
        #expect(results[1].result.isFailure)
        #expect(results[2].result.isSuccess)
    }

    @Test
    func invalidBatchLimitStartsNoRequests() async {
        let transport = BatchTestTransport()
        let client = NetworkClient(transport: transport)

        do {
            _ = try await client.loadBatch(
                requests: requests(count: 2),
                authScope: nil,
                batchOptions: .init(maxConcurrentRequests: 0)
            )
            Issue.record("Expected invalid batch configuration")
        } catch let error as BatchExecutionError {
            #expect(error == .invalidMaxConcurrentRequests(0))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await transport.started().isEmpty)
    }

    @Test
    func cancellingBatchCancelsActiveChildrenAndDoesNotStartPendingRequests() async {
        let transport = BatchTestTransport(delayNanoseconds: 5_000_000_000)
        let client = NetworkClient(transport: transport, cancellationPolicy: .cancelWhenNoWaiters)
        let task = Task {
            try await client.loadBatch(
                requests: requests(count: 10),
                authScope: nil,
                batchOptions: .init(maxConcurrentRequests: 2)
            )
        }

        for _ in 0..<100 {
            if await transport.started().count == 2 { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let activeCount = await transport.started().count
        #expect(activeCount == 2)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError || (error as? NetworkError)?.failureReason == .cancelled)
        }

        #expect(await transport.started().count == activeCount)
        for _ in 0..<200 {
            if await transport.cancellations() == activeCount { break }
            await Task.yield()
        }
        #expect(await transport.cancellations() == activeCount)
    }

    @Test
    func batchEmitsOneAggregateTelemetryContext() async throws {
        let transport = BatchTestTransport(failingPaths: ["/1"])
        let probe = BatchTelemetryProbe()
        let hooks = NetworkTelemetryHooks(onBatchCompleted: { context in
            Task { await probe.append(context) }
        })
        let client = NetworkClient(transport: transport, telemetryHooks: hooks)

        _ = try await client.loadBatchResults(
            requests: requests(count: 3),
            authScope: nil,
            batchOptions: .init(maxConcurrentRequests: 2)
        )

        for _ in 0..<100 {
            if await probe.last() != nil { break }
            await Task.yield()
        }
        let context = await probe.last()
        #expect(context?.total == 3)
        #expect(context?.succeeded == 2)
        #expect(context?.failed == 1)
        #expect(context?.maxConcurrentRequests == 2)
        #expect(context?.collectedFailures == true)
    }

    @Test
    func emptyBatchReturnsWithoutStartingTransportWork() async throws {
        let transport = BatchTestTransport()
        let client = NetworkClient(transport: transport)

        let values = try await client.loadBatch(requests: [], authScope: nil)
        let results = try await client.loadBatchResults(requests: [], authScope: nil)

        #expect(values.isEmpty)
        #expect(results.isEmpty)
        #expect(await transport.started().isEmpty)
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isFailure: Bool {
        !isSuccess
    }
}
