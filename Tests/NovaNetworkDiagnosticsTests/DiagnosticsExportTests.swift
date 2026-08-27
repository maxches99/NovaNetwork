import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkDiagnostics

// Requirements: FR-7 (summary), FR-8/UR-4 (HAR export), FR-9/DR-2 (redaction), FR-10 (signposts),
// FR-11/UR-2 (panel state). Tests: T-3.1, T-4.1…T-4.3, T-5.1, T-6.1, T-7.1.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func record(
    key: String = "k",
    method: String = "GET",
    url: String = "https://api.example.com/users/1",
    outcome: RequestDiagnostic.Outcome = .completed(status: 200),
    duration: Double? = 42,
    attempts: [RequestDiagnostic.Attempt] = [.init(number: 1, startedAt: epoch)],
    coalesced: Bool = false,
    cache: CacheOutcome? = nil,
    requestHeaders: [String: String] = [:],
    responseHeaders: [String: String] = ["Content-Type": "application/json"],
    responseBody: BodySummary? = BodySummary(byteCount: 11, captured: Data(#"{"ok":true}"#.utf8))
) -> RequestDiagnostic {
    RequestDiagnostic(
        key: key,
        method: method,
        url: url,
        startedAt: epoch,
        endedAt: duration.map { epoch.addingTimeInterval($0 / 1000) },
        durationMilliseconds: duration,
        attempts: attempts,
        outcome: outcome,
        wasCoalesced: coalesced,
        cacheOutcome: cache,
        requestHeaders: requestHeaders,
        responseHeaders: responseHeaders,
        responseBody: responseBody
    )
}

// MARK: - T-3.1 summary

@Suite
struct DiagnosticsSummaryTests {
    @Test
    func aggregatesCountOutcomesRatesAndPercentiles() {
        let summary = DiagnosticsSummary(records: [
            record(duration: 10),
            record(duration: 20, coalesced: true, cache: .hit(isStale: false, ageMilliseconds: 5)),
            record(outcome: .failed(reason: "timeout", status: nil), duration: 30),
            record(outcome: .cancelled(reason: "user"), duration: 40),
            record(outcome: .inFlight, duration: nil),
            record(duration: 100, cache: .miss),
        ])

        #expect(summary.requestCount == 6)
        #expect(summary.succeededCount == 3)
        #expect(summary.httpErrorCount == 0)
        #expect(summary.failedCount == 1)
        #expect(summary.cancelledCount == 1)
        #expect(summary.inFlightCount == 1)
        #expect(summary.coalescedCount == 1)
        #expect(summary.cacheObservedCount == 2)
        #expect(summary.cacheServedCount == 1)
        #expect(abs(summary.failureRate - 0.2) < 0.0001)
        #expect(abs(summary.cacheHitRate - 0.5) < 0.0001)
        #expect(summary.medianDurationMilliseconds == 30)
        #expect(summary.p95DurationMilliseconds == 100)
    }

    @Test
    func ratesAreZeroRatherThanUndefinedWhenNothingWasRecorded() {
        let summary = DiagnosticsSummary(records: [])

        #expect(summary.requestCount == 0)
        #expect(summary.failureRate == 0)
        #expect(summary.coalescingRate == 0)
        #expect(summary.cacheHitRate == 0)
        #expect(summary.medianDurationMilliseconds == nil)
        #expect(summary.shortDescription.contains("0 requests"))
    }

    @Test
    func cacheHitRateIsMeasuredAgainstObservedCacheOutcomesOnly() {
        // A client with caching off would otherwise report a misleading zero percent hit rate.
        let summary = DiagnosticsSummary(records: [record(), record(), record(cache: .hit(isStale: false, ageMilliseconds: 1))])

        #expect(summary.cacheObservedCount == 1)
        #expect(summary.cacheHitRate == 1)
    }

    @Test
    func anHTTPErrorCountsAsAFailureEvenThoughNothingThrew() {
        // A transport that returns a 500 as a response has completed the exchange. Reporting that
        // as a success because no error was thrown is the quiet lie this rate exists to avoid.
        let summary = DiagnosticsSummary(records: [
            record(outcome: .completed(status: 200), duration: 10),
            record(outcome: .completed(status: 500), duration: 20),
            record(outcome: .completed(status: 404), duration: 30),
            record(outcome: .completed(status: 304), duration: 40),
        ])

        #expect(summary.succeededCount == 2, "2xx and 3xx succeeded")
        #expect(summary.httpErrorCount == 2)
        #expect(summary.failedCount == 0)
        #expect(abs(summary.failureRate - 0.5) < 0.0001)
    }

    @Test
    func aRecordKnowsWhetherItIsAFailureWhateverEndedIt() {
        #expect(!record(outcome: .completed(status: 200)).isFailure)
        #expect(!record(outcome: .completed(status: 304)).isFailure)
        #expect(record(outcome: .completed(status: 400)).isFailure)
        #expect(record(outcome: .completed(status: 503)).isFailure)
        #expect(record(outcome: .failed(reason: "timeout", status: nil)).isFailure)
        #expect(record(outcome: .cancelled(reason: "user")).isFailure)
        #expect(!record(outcome: .inFlight, duration: nil).isFailure)
    }

    @Test
    func retriedRequestsAreCounted() {
        let retried = record(attempts: [
            .init(number: 1, startedAt: epoch),
            .init(number: 2, startedAt: epoch.addingTimeInterval(0.2), retryDelayMilliseconds: 200, retryReason: "server-error"),
        ])

        #expect(DiagnosticsSummary(records: [retried, record()]).retriedCount == 1)
    }
}

// MARK: - T-4.x HAR export

@Suite
struct HARExportTests {
    private func exported(_ records: [RequestDiagnostic]) throws -> [String: Any] {
        let data = try HARExporter().export(records)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(object)
    }

    /// Nested `#require` calls cannot expand, so the log is unwrapped one step at a time.
    private func firstEntry(_ records: [RequestDiagnostic]) throws -> [String: Any] {
        let json = try exported(records)
        let log = try #require(json["log"] as? [String: Any])
        let entries = try #require(log["entries"] as? [[String: Any]])
        return try #require(entries.first)
    }

    @Test
    func theLogCarriesOneEntryPerRecordWithTheRequiredFields() throws {
        let json = try exported([record(requestHeaders: ["Accept": "application/json"])])
        let log = try #require(json["log"] as? [String: Any])
        let entries = try #require(log["entries"] as? [[String: Any]])
        let entry = try #require(entries.first)

        #expect(log["version"] as? String == "1.2")
        #expect((log["creator"] as? [String: Any])?["name"] as? String == "NovaNetworkDiagnostics")
        #expect(entries.count == 1)
        #expect(entry["time"] as? Double == 42)
        #expect(entry["startedDateTime"] as? String != nil)

        let request = try #require(entry["request"] as? [String: Any])
        #expect(request["method"] as? String == "GET")
        #expect(request["url"] as? String == "https://api.example.com/users/1")
        #expect((request["headers"] as? [[String: String]])?.first?["name"] == "Accept")

        let response = try #require(entry["response"] as? [String: Any])
        #expect(response["status"] as? Int == 200)
        #expect((response["content"] as? [String: Any])?["text"] as? String == #"{"ok":true}"#)

        let timings = try #require(entry["timings"] as? [String: Any])
        #expect(timings["wait"] as? Double == 42)
        #expect(timings["send"] as? Double == 0)
    }

    @Test
    func queryItemsAreBrokenOutTheWayInspectorsExpect() throws {
        let entry = try firstEntry([record(url: "https://api.example.com/search?q=cats&page=2")])
        let query = try #require((entry["request"] as? [String: Any])?["queryString"] as? [[String: String]])

        #expect(query.contains { $0["name"] == "q" && $0["value"] == "cats" })
        #expect(query.contains { $0["name"] == "page" && $0["value"] == "2" })
    }

    @Test
    func retriesCoalescingAndCacheAppearInTheEntryComment() throws {
        let retried = record(
            attempts: [
                .init(number: 1, startedAt: epoch),
                .init(number: 2, startedAt: epoch.addingTimeInterval(0.2), retryDelayMilliseconds: 200, retryReason: "server-error"),
            ],
            coalesced: true,
            cache: .hit(isStale: false, ageMilliseconds: 10)
        )
        let entry = try firstEntry([retried])
        let comment = try #require(entry["comment"] as? String)

        #expect(comment.contains("attempts: 2"))
        #expect(comment.contains("server-error"))
        #expect(comment.contains("coalesced"))
        #expect(comment.contains("cache: served"))
    }

    @Test
    func anEmptyRecorderExportsAValidEmptyLog() throws {
        let json = try exported([])
        let log = try #require(json["log"] as? [String: Any])

        #expect((log["entries"] as? [[String: Any]])?.isEmpty == true)
        #expect(log["version"] as? String == "1.2")
    }

    @Test
    func aBinaryBodyIsBase64EncodedWithTheEncodingFieldSet() throws {
        let bytes = Data([0x00, 0xFF, 0xFE])
        let entry = try firstEntry([
            record(
                responseHeaders: ["Content-Type": "application/octet-stream"],
                responseBody: BodySummary(byteCount: 3, captured: bytes)
            ),
        ])
        let content = try #require((entry["response"] as? [String: Any])?["content"] as? [String: Any])

        #expect(content["encoding"] as? String == "base64")
        #expect(content["text"] as? String == bytes.base64EncodedString())
        #expect(content["size"] as? Int == 3)
    }

    @Test
    func exportIsDeterministicAcrossRuns() throws {
        let records = [record(), record(key: "other", url: "https://api.example.com/users/2")]

        #expect(try HARExporter().export(records) == HARExporter().export(records))
    }
}

// MARK: - T-5.1 redaction

@Suite
struct DiagnosticsRedactionTests {
    @Test
    func credentialsAreGoneBeforeARecordIsEverRetained() async throws {
        let recorder = DiagnosticsRecorder(now: TestClock().now)
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/me")!,
            headers: ["Authorization": "Bearer super-secret-token", "Accept": "application/json"]
        )

        await recorder.recordStart(startContext(request: request))
        await recorder.recordEnd(
            endContext(request: request, headers: ["Set-Cookie": "session=also-secret", "Content-Type": "application/json"])
        )

        let stored = try #require(await recorder.snapshot().first)
        #expect(stored.requestHeaders["Authorization"] == "<redacted>")
        #expect(stored.responseHeaders["Set-Cookie"] == "<redacted>")
        #expect(stored.requestHeaders["Accept"] == "application/json")

        let har = try String(decoding: await recorder.exportHAR(), as: UTF8.self)
        #expect(!har.contains("super-secret-token"))
        #expect(!har.contains("also-secret"))
    }

    @Test
    func theDefaultSetMatchesWhatTheCassetteModuleRedacts() {
        let policy = DiagnosticsRedaction.default

        for name in ["Authorization", "Proxy-Authorization", "Cookie", "Set-Cookie", "X-API-Key", "X-Auth-Token"] {
            #expect(policy.redactsHeader(named: name))
            #expect(policy.redactsHeader(named: name.uppercased()))
        }
        #expect(!policy.redactsHeader(named: "Accept"))
        #expect(!DiagnosticsRedaction.none.redactsHeader(named: "Authorization"))
    }

    @Test
    func queryItemsCanBeRedactedFromTheRecordedURL() async throws {
        let options = DiagnosticsOptions(redaction: .default.redacting(queryItems: "api_key"))
        let recorder = DiagnosticsRecorder(options: options, now: TestClock().now)
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/search")!,
            queryItems: [URLQueryItem(name: "api_key", value: "secret"), URLQueryItem(name: "q", value: "cats")]
        )

        await recorder.recordStart(startContext(request: request))

        let stored = try #require(await recorder.snapshot().first)
        #expect(!stored.url.contains("secret"))
        #expect(stored.url.contains("q=cats"))
    }
}

// MARK: - T-6.1 signposts

@Suite
struct DiagnosticsSignposterTests {
    @Test
    func signpostingIsOffUnlessAskedFor() {
        #expect(DiagnosticsSignposter(isEnabled: false).begin(key: "k", method: "GET", url: "https://example.com") == nil)
        #expect(DiagnosticsOptions().emitsSignposts == false)
    }

    @Test
    func disabledSignpostingIgnoresEndAndRetryWithoutCrashing() {
        let signposter = DiagnosticsSignposter(isEnabled: false)

        signposter.end(nil, outcome: "200", durationMilliseconds: 5)
        signposter.emitRetry(nil, attempt: 2, delayMilliseconds: 10, reason: "server-error")
    }

    @Test
    func anEnabledRecorderRecordsNormallyWhetherOrNotThePlatformHasSignposts() async throws {
        let recorder = DiagnosticsRecorder(
            options: DiagnosticsOptions(emitsSignposts: true),
            now: TestClock().now
        )

        await recorder.recordStart(startContext())
        await recorder.recordEnd(endContext())

        #expect(await recorder.snapshot().first?.outcome == .completed(status: 200))
    }
}

// MARK: - T-7.1 panel state

@Suite
struct DiagnosticsPanelStateTests {
    @Test
    func rowsReadNewestFirstAndCarryTheirBadges() {
        let state = DiagnosticsPanelState(records: [
            record(key: "first", url: "https://api.example.com/a"),
            record(
                key: "second",
                url: "https://api.example.com/b",
                attempts: [
                    .init(number: 1, startedAt: epoch),
                    .init(number: 2, startedAt: epoch.addingTimeInterval(0.2), retryDelayMilliseconds: 200, retryReason: "server-error"),
                ],
                coalesced: true,
                cache: .hit(isStale: false, ageMilliseconds: 3)
            ),
        ])

        #expect(state.rows.count == 2)
        #expect(state.rows[0].title == "GET /b", "newest first")
        #expect(state.rows[0].subtitle == "api.example.com")
        #expect(state.rows[0].durationText == "42 ms")
        #expect(state.rows[0].badges == ["2 attempts", "coalesced", "cache"])
        #expect(state.rows[1].badges.isEmpty)
    }

    @Test(arguments: [
        (RequestDiagnostic.Outcome.completed(status: 200), DiagnosticsPanelState.StatusKind.success, "200"),
        (.completed(status: 404), .failure, "404"),
        (.failed(reason: "timeout", status: nil), .failure, "timeout"),
        (.cancelled(reason: "user"), .cancelled, "cancelled"),
        (.inFlight, .inFlight, "in flight"),
    ])
    func statusKindSeparatesSuccessFromEverythingElse(
        outcome: RequestDiagnostic.Outcome,
        kind: DiagnosticsPanelState.StatusKind,
        text: String
    ) {
        let state = DiagnosticsPanelState(records: [record(outcome: outcome)])

        #expect(state.rows[0].statusKind == kind)
        #expect(state.rows[0].statusText == text)
    }

    @Test
    func theTimelineShowsEachAttemptAndTheBackoffBeforeIt() throws {
        let retried = record(
            duration: 500,
            attempts: [
                .init(number: 1, startedAt: epoch),
                .init(number: 2, startedAt: epoch.addingTimeInterval(0.3), retryDelayMilliseconds: 200, retryReason: "server-error"),
            ]
        )

        let segments = DiagnosticsPanelState.timeline(for: retried)

        #expect(segments.count == 3)
        #expect(segments[0].label == "Attempt 1")
        #expect(segments[0].startFraction == 0)
        #expect(abs(segments[0].widthFraction - 0.6) < 0.01)
        #expect(segments[1].label == "Backoff 200 ms")
        #expect(segments[1].isWait)
        #expect(abs(segments[1].startFraction - 0.2) < 0.01)
        #expect(segments[2].label == "Attempt 2")
        #expect(abs(segments[2].startFraction - 0.6) < 0.01)
    }

    @Test
    func aRequestWithNoMeasuredDurationHasNoTimeline() {
        #expect(DiagnosticsPanelState.timeline(for: record(outcome: .inFlight, duration: nil)).isEmpty)
    }

    @Test
    func theStateCanFindTheRecordBehindARow() throws {
        let state = DiagnosticsPanelState(records: [record(), record(key: "other")])
        let id = try #require(state.rows.first?.id)

        #expect(state.record(for: id)?.key == "other")
        #expect(state.record(for: UUID()) == nil)
    }
}
