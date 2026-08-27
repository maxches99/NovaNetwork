import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkDiagnostics

// Requirements: FR-6 (capture policy edges), FR-8 (HAR request bodies and status text), UR-2 (a
// record reads as a story). Tests: T-2.3, T-4.1, T-4.2.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite
struct BodyCapturePolicyTests {
    @Test
    func nothingIsSummarizedWhenThereIsNoBody() {
        for policy in [BodyCapturePolicy.none, .sizeOnly, .bounded(maxBytes: 10), .default] {
            #expect(policy.summarize(nil) == nil)
        }
    }

    @Test
    func sizeOnlyKeepsTheCountAndNoBytes() {
        let summary = BodyCapturePolicy.sizeOnly.summarize(Data(repeating: 0x41, count: 40))

        #expect(summary?.byteCount == 40)
        #expect(summary?.captured == nil)
        #expect(summary?.isTruncated == false)
    }

    @Test
    func aBodyUnderTheLimitIsKeptWhole() {
        let summary = BodyCapturePolicy.bounded(maxBytes: 100).summarize(Data("small".utf8))

        #expect(summary?.captured == Data("small".utf8))
        #expect(summary?.isTruncated == false)
    }

    @Test
    func theDefaultPolicyIsBoundedRatherThanUnlimited() {
        guard case let .bounded(maxBytes) = BodyCapturePolicy.default else {
            Issue.record("The default capture policy must be bounded")
            return
        }
        #expect(maxBytes == 64 * 1024)
    }
}

@Suite
struct DiagnosticsRedactionShapeTests {
    @Test
    func headersCanBeAddedToThePolicy() {
        let policy = DiagnosticsRedaction.default.redacting(headers: "X-Tenant-Signature")

        #expect(policy.redactsHeader(named: "x-tenant-signature"))
        #expect(policy.redactsHeader(named: "Authorization"))
    }

    @Test
    func aURLWithoutQueryItemsIsLeftAlone() {
        let policy = DiagnosticsRedaction.default.redacting(queryItems: "api_key")

        #expect(policy.redacted(url: "https://api.example.com/users") == "https://api.example.com/users")
        #expect(DiagnosticsRedaction.none.redacted(url: "https://api.example.com?api_key=live") == "https://api.example.com?api_key=live")
    }

    @Test
    func optionsClampANegativeCapacityToZero() {
        #expect(DiagnosticsOptions(capacity: -5).capacity == 0)
    }
}

@Suite
struct RequestDiagnosticShapeTests {
    private func record(outcome: RequestDiagnostic.Outcome, duration: Double? = 42) -> RequestDiagnostic {
        RequestDiagnostic(
            key: "k",
            method: "POST",
            url: "https://api.example.com/users",
            startedAt: epoch,
            durationMilliseconds: duration,
            outcome: outcome
        )
    }

    @Test
    func aRecordDescribesItselfDifferentlyForEachOutcome() {
        #expect(record(outcome: .completed(status: 201)).shortDescription == "POST /users — 201 in 42 ms")
        #expect(record(outcome: .failed(reason: "timeout", status: nil)).shortDescription == "POST /users — timeout in 42 ms")
        #expect(record(outcome: .failed(reason: "server error", status: 500)).shortDescription.contains("500 — server error"))
        #expect(record(outcome: .cancelled(reason: "user")).shortDescription.contains("cancelled (user)"))
        #expect(record(outcome: .inFlight, duration: nil).shortDescription == "POST /users — in flight")
    }

    @Test
    func statusIsReadableOnlyWhenOneWasReceived() {
        #expect(record(outcome: .completed(status: 200)).status == 200)
        #expect(record(outcome: .failed(reason: "x", status: 502)).status == 502)
        #expect(record(outcome: .failed(reason: "x", status: nil)).status == nil)
        #expect(record(outcome: .cancelled(reason: "x")).status == nil)
        #expect(record(outcome: .inFlight).status == nil)
    }

    @Test
    func aRecordWithNoObservedAttemptsStillCountsAsOne() {
        #expect(record(outcome: .completed(status: 200)).attemptCount == 1)
        #expect(!record(outcome: .completed(status: 200)).wasRetried)
    }

    @Test
    func outcomeKnowsWhetherItFinished() {
        #expect(!RequestDiagnostic.Outcome.inFlight.isFinished)
        #expect(RequestDiagnostic.Outcome.completed(status: 200).isFinished)
        #expect(RequestDiagnostic.Outcome.failed(reason: "x", status: nil).isFinished)
        #expect(RequestDiagnostic.Outcome.cancelled(reason: "x").isFinished)
    }
}

@Suite
struct HARRequestBodyTests {
    private func entry(_ record: RequestDiagnostic) throws -> [String: Any] {
        let data = try HARExporter().export([record])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let json = try #require(object)
        let log = try #require(json["log"] as? [String: Any])
        let entries = try #require(log["entries"] as? [[String: Any]])
        return try #require(entries.first)
    }

    private func posted(body: BodySummary?, contentType: String? = "application/json") -> RequestDiagnostic {
        RequestDiagnostic(
            key: "k",
            method: "POST",
            url: "https://api.example.com/users",
            startedAt: epoch,
            durationMilliseconds: 10,
            outcome: .completed(status: 201),
            requestHeaders: contentType.map { ["Content-Type": $0] } ?? [:],
            requestBody: body
        )
    }

    @Test
    func aCapturedRequestBodyBecomesPostData() throws {
        let payload = Data(#"{"name":"Ada"}"#.utf8)
        let request = try #require(
            entry(posted(body: BodySummary(byteCount: payload.count, captured: payload)))["request"] as? [String: Any]
        )
        let postData = try #require(request["postData"] as? [String: Any])

        #expect(postData["mimeType"] as? String == "application/json")
        #expect(postData["text"] as? String == #"{"name":"Ada"}"#)
        #expect(request["bodySize"] as? Int == payload.count)
    }

    @Test
    func aBodyKnownOnlyBySizeCarriesNoPostData() throws {
        let request = try #require(entry(posted(body: BodySummary(byteCount: 99)))["request"] as? [String: Any])

        #expect(request["postData"] == nil)
        #expect(request["bodySize"] as? Int == 99)
    }

    @Test
    func aBinaryRequestBodyFallsBackToBase64Text() throws {
        let bytes = Data([0x00, 0xFF])
        let request = try #require(
            entry(posted(body: BodySummary(byteCount: 2, captured: bytes), contentType: nil))["request"] as? [String: Any]
        )
        let postData = try #require(request["postData"] as? [String: Any])

        #expect(postData["mimeType"] as? String == "application/octet-stream")
        #expect(postData["text"] as? String == bytes.base64EncodedString())
    }

    @Test
    func statusTextReflectsHowTheRequestEnded() throws {
        let cancelled = RequestDiagnostic(
            key: "k", method: "GET", url: "https://api.example.com/x",
            startedAt: epoch, outcome: .cancelled(reason: "user")
        )
        let inFlight = RequestDiagnostic(key: "k", method: "GET", url: "https://api.example.com/x", startedAt: epoch)

        let cancelledResponse = try #require(entry(cancelled)["response"] as? [String: Any])
        let inFlightResponse = try #require(entry(inFlight)["response"] as? [String: Any])

        #expect(cancelledResponse["statusText"] as? String == "Cancelled: user")
        #expect(cancelledResponse["status"] as? Int == 0)
        #expect(inFlightResponse["statusText"] as? String == "In flight")
    }

    @Test
    func aTruncatedResponseBodySaysSoInTheComment() throws {
        let truncated = RequestDiagnostic(
            key: "k", method: "GET", url: "https://api.example.com/big",
            startedAt: epoch, durationMilliseconds: 5, outcome: .completed(status: 200),
            responseBody: BodySummary(byteCount: 1_000, captured: Data("partial".utf8), isTruncated: true)
        )

        let comment = try #require(entry(truncated)["comment"] as? String)
        #expect(comment.contains("truncated"))
    }

    @Test
    func aRecordWithNoTimestampsStillProducesAnEntry() throws {
        let undated = RequestDiagnostic(key: "k", method: "GET", url: "https://api.example.com/x")

        #expect(try entry(undated)["startedDateTime"] as? String != nil)
        #expect(try entry(undated)["time"] as? Double == 0)
    }
}

// MARK: - Installation surface

@Suite
struct DiagnosticsInstallationTests {
    @Test
    func theHooksProperyFeedsEveryLifecycleCallbackIntoTheRecorder() async throws {
        let recorder = DiagnosticsRecorder()
        let hooks = recorder.hooks
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)
        let start = TelemetryRequestContext(key: "k", attempt: 1, coalescingMode: .default, request: request)

        hooks.onRequestStart?(start)
        hooks.onCoalescerEvent?(TelemetryCoalescerContext(type: .coalesced, key: "k", waiterCount: 2))
        hooks.onRetryScheduled?(
            TelemetryRetryContext(key: "k", attempt: 1, nextAttempt: 2, delayMilliseconds: 50, reason: "server-error", request: request)
        )
        hooks.onRequestEnd?(
            TelemetryResponseContext(
                request: start,
                response: NetworkResponse(statusCode: 200, headers: [:], body: Data()),
                error: nil,
                durationMilliseconds: 12
            )
        )

        // The hooks hand work off asynchronously, which is the point: the request path pays for a
        // task hand-off, not for aggregation.
        try await waitUntil("the hook-delivered record is complete") {
            await recorder.snapshot().first?.outcome.isFinished == true
        }

        let record = try #require(await recorder.snapshot().first)
        #expect(record.wasCoalesced)
        #expect(record.outcome == .completed(status: 200))
        #expect(record.durationMilliseconds != nil)
    }

    @Test
    func cancellationArrivingThroughTheHooksIsRecorded() async throws {
        let recorder = DiagnosticsRecorder()
        let hooks = recorder.hooks
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/slow")!)

        hooks.onRequestStart?(TelemetryRequestContext(key: "slow", attempt: 1, coalescingMode: .default, request: request))
        hooks.onRequestCancelled?(
            TelemetryCancellationContext(key: "slow", attempt: 1, reason: "caller-cancelled", request: request)
        )

        try await waitUntil("the cancellation lands") {
            await recorder.snapshot().first?.outcome.isFinished == true
        }

        #expect(await recorder.snapshot().first?.outcome == .cancelled(reason: "caller-cancelled"))
    }

    @Test
    func consumingAnEventStreamAnnotatesRecordsAndEndsWithTheStream() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)
        await recorder.recordStart(startContext(key: "cached"))

        let (stream, continuation) = AsyncStream<NetworkClientEvent>.makeStream()
        let task = recorder.startConsuming(stream)
        continuation.yield(.cacheHit(key: "cached", isStale: false, ageMilliseconds: 20))
        continuation.finish()
        await task.value

        #expect(await recorder.snapshot().first?.cacheOutcome == .hit(isStale: false, ageMilliseconds: 20))
    }

    @Test
    func eventsWithNoDiagnosticMeaningAreIgnored() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)
        await recorder.recordStart(startContext(key: "k"))

        await recorder.record(.requestSucceeded(key: "k", attempts: 1))
        await recorder.record(.circuitBreakerOpen(identifier: "host"))
        await recorder.record(.cacheStaleIfError(key: "k", ageMilliseconds: 5, reason: "offline"))

        let record = try #require(await recorder.snapshot().first)
        #expect(record.cacheOutcome == .staleServedAfterError(reason: "offline"))
        #expect(record.cacheOutcome?.servedFromCache == true)
    }
}

@Suite
struct SignpostEmissionTests {
    @Test
    func anEnabledSignposterOpensAndClosesIntervals() {
        let signposter = DiagnosticsSignposter(isEnabled: true)
        let id = signposter.begin(key: "k", method: "GET", url: "https://api.example.com/users/1")

        #if canImport(os)
        #expect(id != nil, "Apple platforms emit real signposts")
        #else
        #expect(id == nil, "platforms without os compile the signposts away")
        #endif

        signposter.emitRetry(id, attempt: 2, delayMilliseconds: 100, reason: "server-error")
        signposter.end(id, outcome: "200", durationMilliseconds: 12)
    }

    @Test
    func aRecorderWithSignpostsEnabledStillRecordsTheSameFacts() async throws {
        let recorder = DiagnosticsRecorder(
            options: DiagnosticsOptions(capacity: 5, emitsSignposts: true),
            now: TestClock().now
        )

        await recorder.recordStart(startContext())
        await recorder.recordRetryScheduled(
            TelemetryRetryContext(key: "k", attempt: 1, nextAttempt: 2, delayMilliseconds: 10, reason: "timeout", request: sampleRequest())
        )
        await recorder.recordStart(startContext(attempt: 2))
        await recorder.recordEnd(endContext(attempt: 2))

        let record = try #require(await recorder.snapshot().first)
        #expect(record.attemptCount == 2)
        #expect(record.attempts[1].retryReason == "timeout")
    }

    @Test
    func evictionForgetsTheSignpostsOfDroppedRecords() async {
        let recorder = DiagnosticsRecorder(
            options: DiagnosticsOptions(capacity: 2, emitsSignposts: true),
            now: TestClock().now
        )

        for index in 0..<5 {
            await recorder.recordStart(startContext(key: "k\(index)"))
        }

        #expect(await recorder.snapshot().count == 2)
    }
}

// MARK: - Order independence

@Suite
struct DiagnosticsOrderIndependenceTests {
    /// Hook delivery is asynchronous, so nothing guarantees the order handlers observe. These drive
    /// the handlers directly, in the worst order, to prove no fact is lost when the race is lost.
    @Test
    func anEndProcessedBeforeItsStartDoesNotReopenTheRequest() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordEnd(endContext(attempt: 1))
        await recorder.recordStart(startContext(attempt: 1))

        let record = try #require(await recorder.snapshot().first)
        #expect(record.outcome == .completed(status: 200), "a late start must not mark a finished request in flight")
        #expect(record.attemptCount == 1)
    }

    @Test
    func aCoalescingEventBeforeTheRequestIsHeldUntilTheRecordExists() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordCoalescerEvent(TelemetryCoalescerContext(type: .coalesced, key: "k", waiterCount: 2))
        await recorder.recordStart(startContext(key: "k"))

        #expect(await recorder.snapshot().first?.wasCoalesced == true)
    }

    @Test
    func aCacheEventBeforeTheRequestIsHeldUntilTheRecordExists() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.record(.cacheHit(key: "k", isStale: false, ageMilliseconds: 12))
        await recorder.recordStart(startContext(key: "k"))

        #expect(await recorder.snapshot().first?.cacheOutcome == .hit(isStale: false, ageMilliseconds: 12))
    }

    @Test
    func aCancellationBeforeTheRequestStillProducesACancelledRecord() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordCancellation(
            TelemetryCancellationContext(key: "k", attempt: 1, reason: "caller-cancelled", request: sampleRequest())
        )

        let record = try #require(await recorder.snapshot().first)
        #expect(record.outcome == .cancelled(reason: "caller-cancelled"))
        #expect(record.method == "GET")
    }

    @Test
    func aRetryAnnouncedAfterItsAttemptStartedStillAnnotatesThatAttempt() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        await recorder.recordStart(startContext(attempt: 1))
        await recorder.recordEnd(endContext(attempt: 1, status: 500))
        await recorder.recordStart(startContext(attempt: 2))
        // The retry announcement lost the race with the attempt it describes.
        await recorder.recordRetryScheduled(
            TelemetryRetryContext(key: "k", attempt: 1, nextAttempt: 2, delayMilliseconds: 250, reason: "server-error", request: sampleRequest())
        )
        await recorder.recordEnd(endContext(attempt: 2))

        let record = try #require(await recorder.snapshot().first)
        #expect(record.attemptCount == 2, "both attempts belong to one request")
        #expect(record.attempts[1].retryDelayMilliseconds == 250)
        #expect(record.attempts[1].retryReason == "server-error")
        #expect(record.outcome == .completed(status: 200))
    }

    @Test
    func aRetriedRequestStaysOneRecordWhateverTheOrder() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)

        for attempt in 1...3 {
            await recorder.recordStart(startContext(attempt: attempt))
            await recorder.recordEnd(endContext(attempt: attempt, status: attempt == 3 ? 200 : 503))
        }

        let records = await recorder.snapshot()
        #expect(records.count == 1, "three attempts are one request, not three rows")
        #expect(records[0].attemptCount == 3)
        #expect(records[0].outcome == .completed(status: 200))
    }
}
