import Foundation
import NovaNetworkClient
import NovaNetworkCore

/// Collects what the client already reports into records a person can read.
///
/// The client emits everything worth knowing through ``NetworkTelemetryHooks`` and
/// ``NetworkClientEvent``; what has been missing is somewhere for it to land. Install the recorder's
/// ``hooks`` and, optionally, feed it the client's event stream:
///
/// ```swift
/// let recorder = DiagnosticsRecorder()
/// var configuration = NetworkClientConfiguration()
/// configuration.telemetryHooks = recorder.hooks
/// let client = NetworkClient(configuration: configuration)
/// recorder.startConsuming(client.events())
/// ```
///
/// Storage is bounded by construction and credentials are redacted before a record is retained, so
/// leaving a recorder installed does not turn into a memory leak or a place secrets accumulate.
public actor DiagnosticsRecorder {
    private struct PendingRetry {
        let attempt: Int
        let delayMilliseconds: Double
        let reason: String
    }

    /// Facts about a request that arrived before the request itself did.
    ///
    /// Coalescing and cache outcomes are announced around the moment a request starts, and hook
    /// delivery is unordered, so either can land first. Holding them by key until a record exists
    /// is the difference between a badge that is sometimes there and one that is always right.
    private struct PendingAnnotations {
        var wasCoalesced = false
        var cache: CacheOutcome?

        var isEmpty: Bool { !wasCoalesced && cache == nil }
    }

    /// How the recorder behaves.
    public let options: DiagnosticsOptions

    private var records: [RequestDiagnostic] = []
    private var pendingRetries: [String: PendingRetry] = [:]
    private var pendingAnnotations: [String: PendingAnnotations] = [:]
    private var signpostIDs: [UUID: UInt64] = [:]
    private let signposter: DiagnosticsSignposter
    private let now: @Sendable () -> Date

    /// Creates a recorder.
    ///
    /// - Parameters:
    ///   - options: Capacity, body capture, redaction, and signposting.
    ///   - now: Clock used for record timestamps. Injectable so tests are deterministic.
    public init(
        options: DiagnosticsOptions = DiagnosticsOptions(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.options = options
        self.now = now
        signposter = DiagnosticsSignposter(isEnabled: options.emitsSignposts)
    }

    // MARK: - Installation

    /// Telemetry hooks to install on a client.
    ///
    /// The closures do nothing but hand work to the recorder, so the request path pays for a task
    /// hand-off rather than for aggregation, formatting, or storage.
    public nonisolated var hooks: NetworkTelemetryHooks {
        NetworkTelemetryHooks(
            onRequestStart: { [self] context in
                Task { await recordStart(context) }
            },
            onRequestEnd: { [self] context in
                Task { await recordEnd(context) }
            },
            onCoalescerEvent: { [self] context in
                Task { await recordCoalescerEvent(context) }
            },
            onRetryScheduled: { [self] context in
                Task { await recordRetryScheduled(context) }
            },
            onRequestCancelled: { [self] context in
                Task { await recordCancellation(context) }
            }
        )
    }

    /// Consumes a client's event stream until it finishes.
    public func consume(_ events: AsyncStream<NetworkClientEvent>) async {
        for await event in events {
            record(event)
        }
    }

    /// Starts consuming a client's event stream in the background.
    ///
    /// - Returns: The task doing the consuming, so a caller that needs to stop can cancel it.
    @discardableResult
    public nonisolated func startConsuming(_ events: AsyncStream<NetworkClientEvent>) -> Task<Void, Never> {
        Task { await consume(events) }
    }

    // MARK: - Reading

    /// Every retained record, oldest first.
    public func snapshot() -> [RequestDiagnostic] {
        records
    }

    /// Aggregates over the retained records.
    public func summary() -> DiagnosticsSummary {
        DiagnosticsSummary(records: records)
    }

    /// Exports the retained records as a HAR 1.2 log.
    public func exportHAR() throws -> Data {
        try HARExporter().export(records)
    }

    /// Drops every record.
    public func clear() {
        records.removeAll()
        pendingRetries.removeAll()
        pendingAnnotations.removeAll()
        signpostIDs.removeAll()
    }

    // MARK: - Recording

    // Internal rather than private so tests can drive each hook directly.
    //
    // Every handler is order-independent on purpose. The hooks hand their work off through separate
    // tasks, so nothing guarantees that a start is processed before the end that followed it, or
    // that a cancellation lands while its record is still open. Handlers that assumed an order
    // would silently drop events on a busy device.

    func recordStart(_ context: TelemetryRequestContext) {
        guard options.capacity > 0 else { return }

        let index = activeIndex(forKey: context.key)
            ?? retriedIndex(forKey: context.key, attempt: context.attempt)
            ?? insertRecord(for: context)
        guard records.indices.contains(index) else { return }

        if records[index].startedAt == nil {
            records[index].startedAt = now()
        }
        // A retried attempt reopens the record the earlier attempt closed, so one logical request
        // stays one row with a waterfall rather than becoming three unrelated rows. A start that
        // arrives late, after its own end, must not reopen anything -- hence the newer check.
        if isNewerAttempt(context.attempt, than: index) {
            records[index].outcome = .inFlight
            records[index].endedAt = nil
        }
        appendAttempt(context.attempt, to: index)
        records[index].coalescingMode = context.coalescingMode.rawValue
    }

    func recordEnd(_ context: TelemetryResponseContext) {
        guard options.capacity > 0 else { return }

        // An end without a start still deserves a record: the alternative is losing the request
        // entirely because two asynchronous hooks arrived out of order.
        let index = activeIndex(forKey: context.request.key) ?? insertRecord(for: context.request)
        guard records.indices.contains(index) else { return }

        let endedAt = now()
        records[index].endedAt = endedAt
        // Total elapsed time, including the backoff between attempts, because that is the wait a
        // person actually experienced. The per-attempt figure is what the client reports.
        records[index].durationMilliseconds = records[index].startedAt.map {
            endedAt.timeIntervalSince($0) * 1000
        } ?? context.durationMilliseconds
        appendAttempt(context.request.attempt, to: index)

        if let response = context.response {
            records[index].responseHeaders = options.redaction.redacted(headers: response.headers)
            records[index].responseBody = options.bodyCapture.summarize(response.body.isEmpty ? nil : response.body)
            records[index].outcome = context.error == nil
                ? .completed(status: response.statusCode)
                : .failed(reason: describe(context.error), status: response.statusCode)
        } else {
            records[index].outcome = .failed(reason: describe(context.error), status: nil)
        }

        signposter.end(
            signpostIDs.removeValue(forKey: records[index].id),
            outcome: records[index].status.map(String.init) ?? "error",
            durationMilliseconds: context.durationMilliseconds
        )
    }

    func recordRetryScheduled(_ context: TelemetryRetryContext) {
        // The attempt this retry describes may already have been recorded, if its start won the
        // race, so annotate it in place instead of only remembering it for later.
        if let index = latestIndex(forKey: context.key),
           let attemptIndex = records[index].attempts.firstIndex(where: { $0.number == context.nextAttempt }) {
            records[index].attempts[attemptIndex].retryDelayMilliseconds = context.delayMilliseconds
            records[index].attempts[attemptIndex].retryReason = context.reason
        } else {
            pendingRetries[context.key] = PendingRetry(
                attempt: context.nextAttempt,
                delayMilliseconds: context.delayMilliseconds,
                reason: context.reason
            )
        }

        guard let index = activeIndex(forKey: context.key) else { return }
        signposter.emitRetry(
            signpostIDs[records[index].id],
            attempt: context.nextAttempt,
            delayMilliseconds: context.delayMilliseconds,
            reason: context.reason
        )
    }

    func recordCancellation(_ context: TelemetryCancellationContext) {
        guard options.capacity > 0 else { return }

        // A cancellation that arrives before its start still belongs to the request: fall back to
        // the newest record for the key, and create one when nothing has been seen at all.
        let index = activeIndex(forKey: context.key)
            ?? latestIndex(forKey: context.key)
            ?? insertRecord(for: TelemetryRequestContext(
                key: context.key,
                attempt: context.attempt,
                coalescingMode: context.coalescingMode,
                request: context.request
            ))
        guard records.indices.contains(index) else { return }

        records[index].outcome = .cancelled(reason: context.reason)
        records[index].endedAt = now()
        signposter.end(signpostIDs.removeValue(forKey: records[index].id), outcome: "cancelled", durationMilliseconds: nil)
    }

    func recordCoalescerEvent(_ context: TelemetryCoalescerContext) {
        guard context.type == .coalesced else { return }
        // Coalescing is announced around the same moment the request starts, so the record may or
        // may not be open yet; the newest one for the key is the right target either way.
        guard let index = activeIndex(forKey: context.key) ?? latestIndex(forKey: context.key) else {
            pendingAnnotations[context.key, default: PendingAnnotations()].wasCoalesced = true
            return
        }
        records[index].wasCoalesced = true
    }

    func record(_ event: NetworkClientEvent) {
        switch event {
        case let .cacheHit(key, isStale, age):
            annotate(key: key, cache: .hit(isStale: isStale, ageMilliseconds: age))
        case let .cacheMiss(key):
            annotate(key: key, cache: .miss)
        case let .cacheRevalidated(key, age):
            annotate(key: key, cache: .revalidated(ageMilliseconds: age))
        case let .cacheStaleIfError(key, _, reason):
            annotate(key: key, cache: .staleServedAfterError(reason: reason))
        default:
            break
        }
    }

    // MARK: - Storage

    /// The newest unfinished record for a key, which is the one further events belong to.
    private func activeIndex(forKey key: String) -> Int? {
        records.lastIndex { $0.key == key && !$0.outcome.isFinished }
    }

    /// The newest record for a key, finished or not, for annotations that can arrive late.
    private func latestIndex(forKey key: String) -> Int? {
        records.lastIndex { $0.key == key }
    }

    /// The record a retried attempt belongs to.
    ///
    /// The client reports a start and an end per attempt, and a retry is only announced after the
    /// failed attempt has already ended. Attempt numbers are what tie the pieces back together.
    private func retriedIndex(forKey key: String, attempt: Int) -> Int? {
        guard attempt > 1 else { return nil }
        return records.lastIndex { record in
            record.key == key && record.attempts.contains { $0.number == attempt - 1 }
        }
    }

    private func insertRecord(for context: TelemetryRequestContext) -> Int {
        let url = context.request.urlRequest().url?.absoluteString ?? context.request.url.absoluteString
        let waiting = pendingAnnotations.removeValue(forKey: context.key) ?? PendingAnnotations()
        let record = RequestDiagnostic(
            key: context.key,
            method: context.request.method.rawValue,
            url: options.redaction.redacted(url: url),
            coalescingMode: context.coalescingMode.rawValue,
            wasCoalesced: waiting.wasCoalesced,
            cacheOutcome: waiting.cache,
            requestHeaders: options.redaction.redacted(headers: context.request.headers),
            requestBody: options.bodyCapture.summarize(context.request.body)
        )
        append(record)

        if options.emitsSignposts, let index = records.indices.last {
            signpostIDs[records[index].id] = signposter.begin(
                key: record.key,
                method: record.method,
                url: record.url
            )
        }
        return records.count - 1
    }

    private func append(_ record: RequestDiagnostic) {
        records.append(record)
        while records.count > options.capacity {
            let evicted = records.removeFirst()
            signpostIDs.removeValue(forKey: evicted.id)
        }
    }

    /// Whether an attempt number is newer than everything already recorded for a request.
    private func isNewerAttempt(_ number: Int, than index: Int) -> Bool {
        guard let highest = records[index].attempts.map(\.number).max() else { return true }
        return number > highest
    }

    private func appendAttempt(_ number: Int, to index: Int) {
        guard !records[index].attempts.contains(where: { $0.number == number }) else { return }

        var attempt = RequestDiagnostic.Attempt(number: number, startedAt: now())
        if let pending = pendingRetries[records[index].key], pending.attempt == number {
            attempt.retryDelayMilliseconds = pending.delayMilliseconds
            attempt.retryReason = pending.reason
            pendingRetries.removeValue(forKey: records[index].key)
        }

        records[index].attempts.append(attempt)
        records[index].attempts.sort { $0.number < $1.number }
    }

    private func annotate(key: String, cache outcome: CacheOutcome) {
        guard let index = activeIndex(forKey: key) ?? latestIndex(forKey: key) else {
            pendingAnnotations[key, default: PendingAnnotations()].cache = outcome
            return
        }
        records[index].cacheOutcome = outcome
    }

    private func describe(_ error: NetworkError?) -> String {
        guard let error else { return "unknown" }
        return error.errorDescription ?? "\(error)"
    }
}
