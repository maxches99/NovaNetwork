import Foundation

/// Every recorded request laid out on one shared clock, the way a trace viewer shows them.
///
/// The per-request waterfall answers "where did this request's time go". This answers the question
/// next to it: what else was happening at the same moment. Requests that overlap look like they
/// overlap, two callers coalesced onto one request start on the same vertical line, a cache hit is
/// a sliver, and a retry storm is a row of bars with gaps between them.
///
/// Nothing here imports SwiftUI: fractions are computed against the window so a caller can draw
/// them with any drawing API, and the whole thing is testable on Linux.
public struct DiagnosticsTimeline: Sendable, Equatable {
    /// One span within a lane: an attempt, or the backoff waited before the next one.
    public struct Bar: Sendable, Equatable, Identifiable {
        /// Identity within the lane.
        public let id: Int
        /// What the bar represents, for example `Attempt 2` or `Backoff 200 ms`.
        public let label: String
        /// Where the bar starts, as a fraction of the whole window.
        public let startFraction: Double
        /// How wide the bar is, as a fraction of the whole window.
        public let widthFraction: Double
        /// Whether this bar is waiting rather than working.
        public let isWait: Bool
    }

    /// One request's row on the timeline.
    public struct Lane: Sendable, Equatable, Identifiable {
        /// Identity of the underlying record.
        public let id: UUID
        /// Method and path: `GET /users/1`.
        public let title: String
        /// The host the request went to.
        public let subtitle: String
        /// Status or error text.
        public let statusText: String
        /// How the lane should be coloured.
        public let statusKind: DiagnosticsPanelState.StatusKind
        /// Where the request starts, as a fraction of the whole window.
        public let startFraction: Double
        /// How much of the window the request spans, including its waits.
        public let widthFraction: Double
        /// Duration, formatted, when the request finished.
        public let durationText: String?
        /// The attempts and backoffs inside the span.
        public let bars: [Bar]
    }

    /// One labelled gridline on the ruler.
    public struct Tick: Sendable, Equatable, Identifiable {
        /// Identity within the ruler.
        public let id: Int
        /// The offset from the start of the window, formatted.
        public let label: String
        /// Where the gridline sits, as a fraction of the whole window.
        public let fraction: Double
    }

    /// Rows, oldest first, because a timeline reads forwards.
    public let lanes: [Lane]
    /// Gridlines across the window.
    public let ticks: [Tick]
    /// When the window opens: the earliest moment any retained request started.
    public let start: Date
    /// How long the window is.
    public let durationMilliseconds: Double

    /// Whether there is anything to draw.
    public var isEmpty: Bool { lanes.isEmpty }

    /// Lays out a recorder snapshot on one clock.
    ///
    /// - Parameters:
    ///   - records: The retained records, in any order.
    ///   - now: The present moment, which is where a request that has not finished is drawn to.
    ///     Injected rather than read so the layout is deterministic in tests.
    public init(records: [RequestDiagnostic], now: Date = Date()) {
        let started = records.filter { $0.startedAt != nil }
        guard let windowStart = started.compactMap(\.startedAt).min() else {
            lanes = []
            ticks = []
            start = now
            durationMilliseconds = 0
            return
        }

        let ends = started.map { Self.end(of: $0, now: now) }
        let windowEnd = max(ends.max() ?? windowStart, windowStart)
        // A window of zero would divide every fraction by nothing. One millisecond keeps the
        // arithmetic honest and still draws a snapshot taken in a single instant.
        let window = max(DiagnosticsPanelState.milliseconds(from: windowStart, to: windowEnd), 1)

        start = windowStart
        durationMilliseconds = window
        ticks = Self.ticks(across: window)
        lanes = started
            .sorted { ($0.startedAt ?? windowStart) < ($1.startedAt ?? windowStart) }
            .map { Self.lane(for: $0, windowStart: windowStart, window: window, now: now) }
    }

    // MARK: - Layout

    private static func end(of record: RequestDiagnostic, now: Date) -> Date {
        guard let start = record.startedAt else { return now }
        if let duration = record.durationMilliseconds {
            return start.addingTimeInterval(duration / 1000)
        }
        // Still in flight: it is as long as it has been so far, and never shorter than its start.
        return max(now, start)
    }

    private static func lane(
        for record: RequestDiagnostic,
        windowStart: Date,
        window: Double,
        now: Date
    ) -> Lane {
        let row = DiagnosticsPanelState(records: [record]).rows[0]
        let recordStart = record.startedAt ?? windowStart
        let recordEnd = end(of: record, now: now)

        let bars = DiagnosticsPanelState.intervals(for: record, endingAt: recordEnd)
            .enumerated()
            .map { index, interval in
                Bar(
                    id: index,
                    label: interval.label,
                    startFraction: fraction(of: interval.start, from: windowStart, window: window),
                    widthFraction: width(from: interval.start, to: interval.end, window: window),
                    isWait: interval.isWait
                )
            }

        return Lane(
            id: record.id,
            title: row.title,
            subtitle: row.subtitle,
            statusText: row.statusText,
            statusKind: row.statusKind,
            startFraction: fraction(of: recordStart, from: windowStart, window: window),
            widthFraction: width(from: recordStart, to: recordEnd, window: window),
            durationText: row.durationText,
            bars: bars
        )
    }

    private static func fraction(of date: Date, from windowStart: Date, window: Double) -> Double {
        min(max(DiagnosticsPanelState.milliseconds(from: windowStart, to: date) / window, 0), 1)
    }

    private static func width(from start: Date, to end: Date, window: Double) -> Double {
        min(max(DiagnosticsPanelState.milliseconds(from: start, to: end), 0) / window, 1)
    }

    // MARK: - Ruler

    /// Steps a person reads without doing arithmetic. The first one that fits at most six gridlines
    /// across the window wins.
    private static let tickSteps: [Double] = [
        1, 2, 5, 10, 25, 50, 100, 250, 500,
        1_000, 2_000, 5_000, 10_000, 15_000, 30_000,
        60_000, 120_000, 300_000, 600_000,
    ]

    private static func ticks(across window: Double) -> [Tick] {
        let step = tickSteps.first { window / $0 <= 6 } ?? window
        guard step > 0 else { return [] }

        var ticks: [Tick] = []
        var offset: Double = 0
        while offset <= window, ticks.count < 12 {
            ticks.append(Tick(id: ticks.count, label: label(forOffset: offset), fraction: offset / window))
            offset += step
        }
        return ticks
    }

    private static func label(forOffset milliseconds: Double) -> String {
        if milliseconds >= 1_000 {
            let seconds = milliseconds / 1_000
            return seconds == seconds.rounded()
                ? String(format: "%.0f s", seconds)
                : String(format: "%.1f s", seconds)
        }
        return String(format: "%.0f ms", milliseconds)
    }
}
