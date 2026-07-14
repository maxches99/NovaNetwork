import NovaNetworkCore
import Foundation

private actor BatchCancellationController {
    private var cancellationActions: [UUID: @Sendable () -> Void] = [:]
    private var isCancelled = false

    func register(id: UUID, cancellation: @escaping @Sendable () -> Void) {
        if isCancelled {
            cancellation()
        } else {
            cancellationActions[id] = cancellation
        }
    }

    func unregister(id: UUID) {
        cancellationActions[id] = nil
    }

    func cancelAll() {
        isCancelled = true
        let actions = cancellationActions.values
        cancellationActions.removeAll()
        for action in actions {
            action()
        }
    }
}

public extension NetworkClient {
    /// Loads requests concurrently while preserving input order and fail-fast throwing behavior.
    ///
    /// Cancellation cancels active child requests and prevents pending requests from starting.
    ///
    /// - Parameters:
    ///   - requests: Requests to execute.
    ///   - authScope: Stable credential scope shared by the requests.
    ///   - cachePolicy: Optional cache policy override.
    ///   - options: Per-request execution options.
    ///   - batchOptions: Bounded concurrency configuration.
    /// - Returns: Response bodies in the same order as `requests`.
    /// - Throws: ``BatchExecutionError/invalidMaxConcurrentRequests(_:)``, cancellation,
    ///   or the first request error observed by the task group.
    func loadBatch(
        requests: [APIRequest],
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init(),
        batchOptions: BatchExecutionOptions = .init()
    ) async throws -> [Data] {
        try validate(batchOptions)
        guard !requests.isEmpty else { return [] }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        var completedCount = 0
        let cancellationController = BatchCancellationController()

        do {
            let values = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: (Int, Data).self, returning: [Data].self) { group in
                    var nextIndex = 0
                    var ordered = Array<Data?>(repeating: nil, count: requests.count)

                    func submit(_ index: Int) {
                        let request = requests[index]
                        group.addTask {
                            let taskID = UUID()
                            let child = Task {
                                try Task.checkCancellation()
                                return try await self.load(
                                    request: request,
                                    authScope: authScope,
                                    cachePolicy: cachePolicy,
                                    options: options
                                )
                            }
                            await cancellationController.register(id: taskID) { child.cancel() }
                            do {
                                let data = try await child.value
                                await cancellationController.unregister(id: taskID)
                                return (index, data)
                            } catch {
                                await cancellationController.unregister(id: taskID)
                                throw error
                            }
                        }
                    }

                    while nextIndex < min(batchOptions.maxConcurrentRequests, requests.count) {
                        submit(nextIndex)
                        nextIndex += 1
                    }

                    while let (index, data) = try await group.next() {
                        try Task.checkCancellation()
                        ordered[index] = data
                        completedCount += 1
                        if nextIndex < requests.count {
                            submit(nextIndex)
                            nextIndex += 1
                        }
                    }

                    return ordered.compactMap { $0 }
                }
            } onCancel: {
                Task { await cancellationController.cancelAll() }
            }

            emitBatchTelemetry(
                total: requests.count,
                succeeded: values.count,
                failed: 0,
                cancelled: 0,
                options: batchOptions,
                startedAt: startedAt,
                collectedFailures: false
            )
            return values
        } catch {
            let wasCancelled = error is CancellationError || Task.isCancelled
            emitBatchTelemetry(
                total: requests.count,
                succeeded: completedCount,
                failed: wasCancelled ? 0 : 1,
                cancelled: max(0, requests.count - completedCount - (wasCancelled ? 0 : 1)),
                options: batchOptions,
                startedAt: startedAt,
                collectedFailures: false
            )
            throw error
        }
    }

    /// Loads every request and collects per-item failures without failing the whole batch.
    ///
    /// Configuration errors and parent-task cancellation still throw. Network failures are
    /// returned in ``BatchItemResult/result``.
    ///
    /// - Parameters:
    ///   - requests: Requests to execute.
    ///   - authScope: Stable credential scope shared by the requests.
    ///   - cachePolicy: Optional cache policy override.
    ///   - options: Per-request execution options.
    ///   - batchOptions: Bounded concurrency configuration.
    /// - Returns: Indexed results in input order.
    func loadBatchResults(
        requests: [APIRequest],
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init(),
        batchOptions: BatchExecutionOptions = .init()
    ) async throws -> [BatchItemResult] {
        try validate(batchOptions)
        guard !requests.isEmpty else { return [] }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let cancellationController = BatchCancellationController()
        let results = try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(
                of: BatchItemResult.self,
                returning: [BatchItemResult].self
            ) { group in
                var nextIndex = 0
                var ordered = Array<BatchItemResult?>(repeating: nil, count: requests.count)

                func submit(_ index: Int) {
                    let request = requests[index]
                    group.addTask {
                        let taskID = UUID()
                        let child = Task { () -> BatchItemResult in
                            try Task.checkCancellation()
                            do {
                                let data = try await self.load(
                                    request: request,
                                    authScope: authScope,
                                    cachePolicy: cachePolicy,
                                    options: options
                                )
                                return BatchItemResult(index: index, request: request, result: .success(data))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch let error as NetworkError {
                                return BatchItemResult(index: index, request: request, result: .failure(error))
                            } catch {
                                return BatchItemResult(
                                    index: index,
                                    request: request,
                                    result: .failure(.transport(underlying: error))
                                )
                            }
                        }
                        await cancellationController.register(id: taskID) { child.cancel() }
                        do {
                            let value = try await child.value
                            await cancellationController.unregister(id: taskID)
                            return value
                        } catch {
                            await cancellationController.unregister(id: taskID)
                            throw error
                        }
                    }
                }

                while nextIndex < min(batchOptions.maxConcurrentRequests, requests.count) {
                    submit(nextIndex)
                    nextIndex += 1
                }

                while let result = try await group.next() {
                    try Task.checkCancellation()
                    ordered[result.index] = result
                    if nextIndex < requests.count {
                        submit(nextIndex)
                        nextIndex += 1
                    }
                }

                return ordered.compactMap { $0 }
            }
        } onCancel: {
            Task { await cancellationController.cancelAll() }
        }

        let succeeded = results.reduce(into: 0) { count, item in
            if case .success = item.result { count += 1 }
        }
        emitBatchTelemetry(
            total: requests.count,
            succeeded: succeeded,
            failed: results.count - succeeded,
            cancelled: 0,
            options: batchOptions,
            startedAt: startedAt,
            collectedFailures: true
        )
        return results
    }

    private func validate(_ options: BatchExecutionOptions) throws {
        guard options.maxConcurrentRequests > 0 else {
            throw BatchExecutionError.invalidMaxConcurrentRequests(options.maxConcurrentRequests)
        }
    }

    private func emitBatchTelemetry(
        total: Int,
        succeeded: Int,
        failed: Int,
        cancelled: Int,
        options: BatchExecutionOptions,
        startedAt: UInt64,
        collectedFailures: Bool
    ) {
        let elapsed = DispatchTime.now().uptimeNanoseconds &- startedAt
        telemetryHooks?.onBatchCompleted?(
            TelemetryBatchContext(
                total: total,
                succeeded: succeeded,
                failed: failed,
                cancelled: cancelled,
                maxConcurrentRequests: options.maxConcurrentRequests,
                durationMilliseconds: Double(elapsed) / 1_000_000,
                collectedFailures: collectedFailures
            )
        )
    }
}
