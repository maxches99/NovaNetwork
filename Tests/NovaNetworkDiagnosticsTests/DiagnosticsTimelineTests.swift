import Foundation
import Testing
@testable import NovaNetworkDiagnostics

// Requirements: FR-13 (one shared clock), FR-14 (a ruler a person can read), UR-5 (overlap is
// visible), EC-9…EC-12 (empty, instantaneous, in-flight, and unstarted records).
// Tests: T-9.1…T-9.10.

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ milliseconds: Double) -> Date {
    epoch.addingTimeInterval(milliseconds / 1000)
}

private func record(
    method: String = "GET",
    url: String = "https://api.example.com/users",
    startedAt: Date? = epoch,
    duration: Double?,
    attempts: [RequestDiagnostic.Attempt] = [],
    outcome: RequestDiagnostic.Outcome = .completed(status: 200)
) -> RequestDiagnostic {
    RequestDiagnostic(
        key: url,
        method: method,
        url: url,
        startedAt: startedAt,
        endedAt: startedAt.flatMap { start in duration.map { start.addingTimeInterval($0 / 1000) } },
        durationMilliseconds: duration,
        attempts: attempts.isEmpty ? [.init(number: 1, startedAt: startedAt ?? epoch)] : attempts,
        outcome: outcome
    )
}

@Suite
struct DiagnosticsTimelineTests {
    // MARK: - The window

    @Test
    func anEmptySnapshotProducesNothingToDraw() {
        let timeline = DiagnosticsTimeline(records: [], now: epoch)

        #expect(timeline.isEmpty)
        #expect(timeline.lanes.isEmpty)
        #expect(timeline.ticks.isEmpty)
        #expect(timeline.durationMilliseconds == 0)
    }

    @Test
    func theWindowSpansFromTheEarliestStartToTheLatestEnd() {
        let first = record(url: "https://api.example.com/a", startedAt: at(0), duration: 100)
        let second = record(
            url: "https://api.example.com/b",
            startedAt: at(400),
            duration: 200,
            attempts: [.init(number: 1, startedAt: at(400))]
        )

        let timeline = DiagnosticsTimeline(records: [second, first], now: at(1_000))

        #expect(timeline.start == epoch)
        #expect(timeline.durationMilliseconds == 600)
    }

    @Test
    func lanesReadForwardsRegardlessOfSnapshotOrder() {
        let early = record(url: "https://api.example.com/early", startedAt: at(0), duration: 10)
        let late = record(
            url: "https://api.example.com/late",
            startedAt: at(50),
            duration: 10,
            attempts: [.init(number: 1, startedAt: at(50))]
        )

        let timeline = DiagnosticsTimeline(records: [late, early], now: at(100))

        #expect(timeline.lanes.map(\.title) == ["GET /early", "GET /late"])
    }

    @Test
    func aRecordThatNeverStartedIsNotDrawn() {
        let ghost = record(startedAt: nil, duration: nil, attempts: [.init(number: 1, startedAt: epoch)])
        let real = record(url: "https://api.example.com/real", startedAt: at(0), duration: 20)

        let timeline = DiagnosticsTimeline(records: [ghost, real], now: at(100))

        #expect(timeline.lanes.count == 1)
        #expect(timeline.lanes[0].title == "GET /real")
    }

    @Test
    func aSnapshotTakenInASingleInstantStillDivides() {
        let timeline = DiagnosticsTimeline(records: [record(startedAt: at(0), duration: 0)], now: at(0))

        #expect(timeline.durationMilliseconds == 1)
        #expect(timeline.lanes[0].startFraction == 0)
        #expect(timeline.lanes[0].widthFraction == 0)
    }

    // MARK: - Placement

    @Test
    func overlappingRequestsOverlapOnTheTimeline() {
        // The point of the shared clock: two requests running at once must produce spans that
        // intersect, which is exactly what a per-request waterfall cannot show.
        let long = record(
            url: "https://api.example.com/long",
            startedAt: at(0),
            duration: 1_000,
            attempts: [.init(number: 1, startedAt: at(0))]
        )
        let short = record(
            url: "https://api.example.com/short",
            startedAt: at(250),
            duration: 250,
            attempts: [.init(number: 1, startedAt: at(250))]
        )

        let timeline = DiagnosticsTimeline(records: [long, short], now: at(1_000))
        let first = timeline.lanes[0]
        let second = timeline.lanes[1]

        #expect(first.startFraction == 0)
        #expect(first.widthFraction == 1)
        #expect(second.startFraction == 0.25)
        #expect(second.widthFraction == 0.25)
        #expect(second.startFraction > first.startFraction)
        #expect(second.startFraction + second.widthFraction < first.startFraction + first.widthFraction)
    }

    @Test
    func coalescedCallersStartOnTheSameLine() {
        let start = at(120)
        let one = record(url: "https://api.example.com/profile", startedAt: start, duration: 80)
        let two = record(url: "https://api.example.com/profile", startedAt: start, duration: 80)

        let timeline = DiagnosticsTimeline(records: [one, two], now: at(400))

        #expect(timeline.lanes[0].startFraction == timeline.lanes[1].startFraction)
    }

    @Test
    func backoffIsDrawnAsWaitingBetweenTheAttemptsItSeparates() {
        let retried = record(
            url: "https://api.example.com/flaky",
            startedAt: at(0),
            duration: 1_000,
            attempts: [
                .init(number: 1, startedAt: at(0)),
                .init(number: 2, startedAt: at(600), retryDelayMilliseconds: 400, retryReason: "503"),
            ]
        )

        let timeline = DiagnosticsTimeline(records: [retried], now: at(1_000))
        let bars = timeline.lanes[0].bars

        #expect(bars.map(\.label) == ["Attempt 1", "Backoff 400 ms", "Attempt 2"])
        #expect(bars.map(\.isWait) == [false, true, false])
        // Attempt 1 works for 200 ms, then 400 ms of backoff, then attempt 2 runs to the end.
        #expect(bars[0].startFraction == 0)
        #expect(bars[0].widthFraction == 0.2)
        #expect(bars[1].startFraction == 0.2)
        #expect(bars[1].widthFraction == 0.4)
        #expect(bars[2].startFraction == 0.6)
        #expect(bars[2].widthFraction == 0.4)
    }

    @Test
    func barsArePlacedAgainstTheWindowRatherThanTheirOwnRequest() {
        // A lane starting halfway through the window must have its first bar there too -- placing
        // bars against the record's own duration is the bug this guards.
        let late = record(
            url: "https://api.example.com/late",
            startedAt: at(500),
            duration: 500,
            attempts: [.init(number: 1, startedAt: at(500))]
        )
        let anchor = record(url: "https://api.example.com/anchor", startedAt: at(0), duration: 10)

        let timeline = DiagnosticsTimeline(records: [anchor, late], now: at(1_000))
        let lane = try! #require(timeline.lanes.first { $0.title == "GET /late" })

        #expect(lane.bars[0].startFraction == 0.5)
        #expect(lane.bars[0].widthFraction == 0.5)
    }

    @Test
    func anInFlightRequestIsDrawnUpToTheMomentItIsRead() {
        let pending = record(
            url: "https://api.example.com/slow",
            startedAt: at(0),
            duration: nil,
            attempts: [.init(number: 1, startedAt: at(0))],
            outcome: .inFlight
        )

        let timeline = DiagnosticsTimeline(records: [pending], now: at(800))

        #expect(timeline.durationMilliseconds == 800)
        #expect(timeline.lanes[0].widthFraction == 1)
        #expect(timeline.lanes[0].statusKind == .inFlight)
        #expect(timeline.lanes[0].durationText == nil)
    }

    // MARK: - The ruler

    @Test
    func theRulerPicksAStepAPersonCanRead() {
        let cases: [(window: Double, expected: [String])] = [
            (10, ["0 ms", "2 ms", "4 ms", "6 ms", "8 ms", "10 ms"]),
            (600, ["0 ms", "100 ms", "200 ms", "300 ms", "400 ms", "500 ms", "600 ms"]),
            (4_000, ["0 ms", "1 s", "2 s", "3 s", "4 s"]),
        ]

        for testCase in cases {
            let timeline = DiagnosticsTimeline(
                records: [record(startedAt: at(0), duration: testCase.window)],
                now: at(testCase.window)
            )
            #expect(timeline.ticks.map(\.label) == testCase.expected, "window \(testCase.window)")
        }
    }

    @Test
    func gridlinesSitWhereTheirLabelSays() {
        let timeline = DiagnosticsTimeline(records: [record(startedAt: at(0), duration: 500)], now: at(500))

        #expect(timeline.ticks.first?.fraction == 0)
        #expect(timeline.ticks.last?.fraction == 1)
        #expect(timeline.ticks.allSatisfy { (0...1).contains($0.fraction) })
    }
}
