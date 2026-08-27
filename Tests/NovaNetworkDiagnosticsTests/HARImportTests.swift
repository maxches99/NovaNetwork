import Foundation
import Testing
@testable import NovaNetworkDiagnostics

// Requirements: FR-15 (read a HAR back), FR-16 (round-trip our own exports), EC-13…EC-16 (foreign
// producers, malformed entries, unsupported versions, missing timestamps).
// Tests: T-10.1…T-10.9.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite
struct HARImportTests {
    // MARK: - Round trip

    @Test
    func aRecordSurvivesExportAndImport() throws {
        let original = RequestDiagnostic(
            key: "https://api.example.com/users/1",
            method: "GET",
            url: "https://api.example.com/users/1",
            startedAt: epoch,
            endedAt: epoch.addingTimeInterval(0.25),
            durationMilliseconds: 250,
            attempts: [.init(number: 1, startedAt: epoch)],
            outcome: .completed(status: 200),
            requestHeaders: ["Accept": "application/json"],
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: BodySummary(byteCount: 17, captured: Data(#"{"id":1,"ok":true}"#.utf8))
        )

        let data = try HARExporter().export([original])
        let imported = try HARImporter().import(data)

        let record = try #require(imported.first)
        #expect(imported.count == 1)
        #expect(record.method == "GET")
        #expect(record.url == "https://api.example.com/users/1")
        #expect(record.startedAt == epoch)
        #expect(record.durationMilliseconds == 250)
        #expect(record.outcome == .completed(status: 200))
        #expect(record.requestHeaders["Accept"] == "application/json")
        #expect(record.responseHeaders["Content-Type"] == "application/json")
        #expect(record.responseBody?.captured == Data(#"{"id":1,"ok":true}"#.utf8))
    }

    @Test
    func theRetryStoryComesBackFromTheComment() throws {
        // HAR has no field for attempts, so the exporter writes them into `comment`. Losing them on
        // the way back would make an imported trace look like every request succeeded first time.
        let retried = RequestDiagnostic(
            key: "https://api.example.com/flaky",
            method: "GET",
            url: "https://api.example.com/flaky",
            startedAt: epoch,
            durationMilliseconds: 900,
            attempts: [
                .init(number: 1, startedAt: epoch),
                .init(number: 2, startedAt: epoch.addingTimeInterval(0.4), retryDelayMilliseconds: 300, retryReason: "503"),
                .init(number: 3, startedAt: epoch.addingTimeInterval(0.7), retryDelayMilliseconds: 200, retryReason: "503"),
            ],
            outcome: .completed(status: 200)
        )

        let imported = try HARImporter().import(HARExporter().export([retried]))
        let record = try #require(imported.first)

        #expect(record.attemptCount == 3)
        #expect(record.wasRetried)
        #expect(record.attempts[1].retryReason == "503")
    }

    @Test
    func coalescingAndCacheOutcomesComeBack() throws {
        let coalesced = RequestDiagnostic(
            key: "https://api.example.com/profile",
            method: "GET",
            url: "https://api.example.com/profile",
            startedAt: epoch,
            durationMilliseconds: 40,
            outcome: .completed(status: 200),
            wasCoalesced: true,
            cacheOutcome: .hit(isStale: false, ageMilliseconds: 120)
        )

        let record = try #require(try HARImporter().import(HARExporter().export([coalesced])).first)

        #expect(record.wasCoalesced)
        #expect(record.cacheOutcome?.servedFromCache == true)
    }

    @Test
    func aFailureIsNotReadBackAsASuccess() throws {
        let failed = RequestDiagnostic(
            key: "https://api.example.com/orders",
            method: "POST",
            url: "https://api.example.com/orders",
            startedAt: epoch,
            durationMilliseconds: 60,
            outcome: .failed(reason: "The network connection was lost.", status: nil)
        )
        let cancelled = RequestDiagnostic(
            key: "https://api.example.com/slow",
            method: "GET",
            url: "https://api.example.com/slow",
            startedAt: epoch,
            durationMilliseconds: 10,
            outcome: .cancelled(reason: "the caller went away")
        )

        let imported = try HARImporter().import(HARExporter().export([failed, cancelled]))

        #expect(imported[0].outcome == .failed(reason: "The network connection was lost.", status: nil))
        #expect(imported[0].isFailure)
        #expect(imported[1].outcome == .cancelled(reason: "the caller went away"))
    }

    @Test
    func anHTTPErrorStaysAnHTTPError() throws {
        let rejected = RequestDiagnostic(
            key: "https://api.example.com/orders",
            method: "POST",
            url: "https://api.example.com/orders",
            startedAt: epoch,
            durationMilliseconds: 60,
            outcome: .completed(status: 422)
        )

        let record = try #require(try HARImporter().import(HARExporter().export([rejected])).first)

        #expect(record.outcome == .completed(status: 422))
        #expect(record.isFailure)
    }

    // MARK: - Foreign files

    @Test
    func aHARFromAnotherToolIsReadWithoutItsExtras() throws {
        // No `comment`, no fractional seconds, headers a browser would write.
        let foreign = """
        {"log":{"version":"1.2","creator":{"name":"WebInspector","version":"18.0"},"entries":[
          {"startedDateTime":"2027-01-15T10:00:00+00:00","time":123.5,
           "request":{"method":"POST","url":"https://api.example.com/login",
                      "headers":[{"name":"Content-Type","value":"application/json"}],
                      "postData":{"mimeType":"application/json","text":"{}"},"bodySize":2},
           "response":{"status":201,"statusText":"Created",
                       "headers":[{"name":"Location","value":"/sessions/9"}],
                       "content":{"size":4,"mimeType":"application/json","text":"null"}}}
        ]}}
        """

        let record = try #require(try HARImporter().import(Data(foreign.utf8)).first)

        #expect(record.method == "POST")
        #expect(record.durationMilliseconds == 123.5)
        #expect(record.outcome == .completed(status: 201))
        #expect(record.responseHeaders["Location"] == "/sessions/9")
        #expect(record.requestBody?.captured == Data("{}".utf8))
        #expect(record.attemptCount == 1)
        #expect(record.wasCoalesced == false)
        #expect(record.cacheOutcome == nil)
    }

    @Test
    func aBase64BodyIsDecodedRatherThanKeptAsText() throws {
        let bytes = Data([0x00, 0x01, 0xFF, 0xFE])
        let har = """
        {"log":{"version":"1.2","entries":[
          {"startedDateTime":"2027-01-15T10:00:00.000+00:00","time":1,
           "request":{"method":"GET","url":"https://api.example.com/blob","headers":[]},
           "response":{"status":200,"statusText":"OK","headers":[],
                       "content":{"size":4,"mimeType":"application/octet-stream","text":"\(bytes.base64EncodedString())","encoding":"base64"}}}
        ]}}
        """

        let record = try #require(try HARImporter().import(Data(har.utf8)).first)

        #expect(record.responseBody?.captured == bytes)
    }

    // MARK: - Bad input

    @Test
    func filesThatAreNotHARAreRejectedWithAReasonAPersonCanRead() {
        let importer = HARImporter()

        #expect(throws: HARImporter.Failure.notJSON) { try importer.import(Data("not json".utf8)) }
        #expect(throws: HARImporter.Failure.notHAR) { try importer.import(Data(#"{"log":{}}"#.utf8)) }
        #expect(throws: HARImporter.Failure.unsupportedVersion("2.0")) {
            try importer.import(Data(#"{"log":{"version":"2.0","entries":[]}}"#.utf8))
        }
        #expect(HARImporter.Failure.notHAR.description.contains("log.entries"))
    }

    @Test
    func oneBrokenEntryDoesNotThrowAwayTheRestOfTheTrace() throws {
        // Support artifacts arrive truncated. Reading four of five entries beats reading none.
        let har = """
        {"log":{"version":"1.2","entries":[
          {"time":5,"response":{"status":200}},
          {"startedDateTime":"2027-01-15T10:00:00.000+00:00","time":5,
           "request":{"method":"GET","url":"https://api.example.com/ok","headers":[]},
           "response":{"status":200,"statusText":"OK","headers":[],"content":{"size":0,"mimeType":""}}}
        ]}}
        """

        let imported = try HARImporter().import(Data(har.utf8))

        #expect(imported.count == 1)
        #expect(imported[0].url == "https://api.example.com/ok")
    }

    @Test
    func anEntryWithoutATimestampIsKeptButNotDated() throws {
        let har = """
        {"log":{"version":"1.2","entries":[
          {"time":-1,"request":{"method":"GET","url":"https://api.example.com/x","headers":[]},
           "response":{"status":0,"statusText":"","headers":[],"content":{"size":0,"mimeType":""}}}
        ]}}
        """

        let record = try #require(try HARImporter().import(Data(har.utf8)).first)

        #expect(record.startedAt == nil)
        #expect(record.durationMilliseconds == nil)
        #expect(record.attempts.isEmpty)
        #expect(record.outcome == .failed(reason: "The request did not complete.", status: nil))
        // A record with no start cannot be placed on a clock, so the timeline leaves it out.
        #expect(DiagnosticsTimeline(records: [record], now: epoch).isEmpty)
    }
}

@Suite
struct RecorderLoadingTests {
    // Requirements: FR-17 (a file can be loaded into a recorder). Tests: T-10.10, T-10.11.

    @Test
    func aFileLoadedIntoARecorderIsReadBackByTheSameAPIsALiveSessionUses() async throws {
        let recorder = DiagnosticsRecorder()
        let har = try HARExporter().export([
            RequestDiagnostic(
                key: "https://api.example.com/a",
                method: "GET",
                url: "https://api.example.com/a",
                startedAt: epoch,
                durationMilliseconds: 30,
                outcome: .completed(status: 200)
            ),
            RequestDiagnostic(
                key: "https://api.example.com/b",
                method: "GET",
                url: "https://api.example.com/b",
                startedAt: epoch,
                durationMilliseconds: 30,
                outcome: .completed(status: 500)
            ),
        ])

        await recorder.load(try HARImporter().import(har))

        #expect(await recorder.snapshot().count == 2)
        #expect(await recorder.summary().failureRate == 0.5)
    }

    @Test
    func loadingReplacesWhatWasThereAndRespectsTheCapacity() async {
        let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 2))
        let records = (1...5).map { index in
            RequestDiagnostic(
                key: "\(index)",
                method: "GET",
                url: "https://api.example.com/\(index)",
                startedAt: epoch,
                durationMilliseconds: 1,
                outcome: .completed(status: 200)
            )
        }

        await recorder.load(records)
        await recorder.load(records)

        let snapshot = await recorder.snapshot()
        #expect(snapshot.count == 2)
        #expect(snapshot.map(\.url) == ["https://api.example.com/4", "https://api.example.com/5"])
    }
}
