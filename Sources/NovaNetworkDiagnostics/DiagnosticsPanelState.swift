import Foundation

/// Everything the panel draws, computed without SwiftUI.
///
/// Keeping the presentation logic here rather than inside a view means it can be tested on any
/// platform, and it keeps the UI from becoming the only way to read the data.
public struct DiagnosticsPanelState: Sendable, Equatable {
    /// How a row should read at a glance.
    public enum StatusKind: String, Sendable, Equatable {
        case success
        case failure
        case cancelled
        case inFlight
    }

    /// One row of the request list.
    public struct Row: Sendable, Equatable, Identifiable {
        /// Identity of the underlying record.
        public let id: UUID
        /// Method and path: `GET /users/1`.
        public let title: String
        /// The host the request went to.
        public let subtitle: String
        /// Status or error text.
        public let statusText: String
        /// How the row should be coloured.
        public let statusKind: StatusKind
        /// Duration, formatted, when the request finished.
        public let durationText: String?
        /// Short flags worth showing inline: retries, coalescing, cache.
        public let badges: [String]
    }

    /// One bar of a request's timeline.
    public struct TimelineSegment: Sendable, Equatable, Identifiable {
        /// Identity within the timeline.
        public let id: Int
        /// What the bar represents, for example `Attempt 2` or `Backoff 200 ms`.
        public let label: String
        /// Where the bar starts, as a fraction of the request's total duration.
        public let startFraction: Double
        /// How wide the bar is, as a fraction of the request's total duration.
        public let widthFraction: Double
        /// Whether this bar is waiting rather than working.
        public let isWait: Bool
    }

    /// Aggregates across the retained records.
    public let summary: DiagnosticsSummary
    /// Rows, newest first, because that is what a developer is looking for.
    public let rows: [Row]
    /// The records behind the rows, newest first.
    public let records: [RequestDiagnostic]

    /// Builds panel state from a recorder snapshot.
    public init(records: [RequestDiagnostic]) {
        summary = DiagnosticsSummary(records: records)
        let newestFirst = records.reversed().map { $0 }
        self.records = newestFirst
        rows = newestFirst.map(Self.row(for:))
    }

    /// The record behind a row.
    public func record(for id: UUID) -> RequestDiagnostic? {
        records.first { $0.id == id }
    }

    private static func row(for record: RequestDiagnostic) -> Row {
        let url = URL(string: record.url)
        var badges: [String] = []
        if record.wasRetried { badges.append("\(record.attemptCount) attempts") }
        if record.wasCoalesced { badges.append("coalesced") }
        if record.cacheOutcome?.servedFromCache == true { badges.append("cache") }
        if record.responseBody?.isTruncated == true { badges.append("truncated") }

        return Row(
            id: record.id,
            title: "\(record.method) \(url?.path ?? record.url)",
            subtitle: url?.host ?? "",
            statusText: statusText(for: record),
            statusKind: statusKind(for: record),
            durationText: record.durationMilliseconds.map { String(format: "%.0f ms", $0) },
            badges: badges
        )
    }

    private static func statusText(for record: RequestDiagnostic) -> String {
        switch record.outcome {
        case .inFlight: "in flight"
        case let .completed(status): "\(status)"
        case let .failed(reason, status): status.map { "\($0)" } ?? reason
        case .cancelled: "cancelled"
        }
    }

    private static func statusKind(for record: RequestDiagnostic) -> StatusKind {
        switch record.outcome {
        case .inFlight: .inFlight
        case let .completed(status): (200..<400).contains(status) ? .success : .failure
        case .failed: .failure
        case .cancelled: .cancelled
        }
    }

    /// The waterfall for one request: each attempt, and the backoff waited before it.
    ///
    /// Fractions are relative to the request's total duration, so a caller can draw bars without
    /// knowing anything about time.
    public static func timeline(for record: RequestDiagnostic) -> [TimelineSegment] {
        guard let start = record.startedAt, let total = record.durationMilliseconds, total > 0 else {
            return []
        }

        let end = start.addingTimeInterval(total / 1000)
        return intervals(for: record, endingAt: end).enumerated().map { index, interval in
            let offset = milliseconds(from: start, to: interval.start)
            let width = milliseconds(from: interval.start, to: interval.end)
            return TimelineSegment(
                id: index,
                label: interval.label,
                startFraction: min(offset / total, 1),
                widthFraction: min(max(width, 0) / total, 1),
                isWait: interval.isWait
            )
        }
    }

    /// Milliseconds between two instants, with the noise of `Date` arithmetic rounded away.
    ///
    /// `Date` counts seconds from 2001 as a `Double`, so a 600 ms difference comes back as
    /// 600.0000238. That is invisible on screen but not in arithmetic: a ruler asking whether a
    /// window divides into six 100 ms steps got seven, and every fraction carried the noise into
    /// public API. Nanosecond precision is far finer than anything measured here.
    static func milliseconds(from start: Date, to end: Date) -> Double {
        (end.timeIntervalSince(start) * 1_000 * 10_000).rounded() / 10_000
    }

    /// One span of a request placed on a real clock rather than on a fraction.
    ///
    /// The waterfall and the shared timeline draw the same spans against different axes, so the rule
    /// for where an attempt ends and its successor's backoff begins lives here once.
    struct Interval: Sendable, Equatable {
        let label: String
        let start: Date
        let end: Date
        let isWait: Bool
    }

    /// Every attempt and backoff of a request, as absolute intervals.
    ///
    /// - Parameters:
    ///   - record: The request to lay out.
    ///   - end: When the request finished, or the present moment while it is still in flight.
    static func intervals(for record: RequestDiagnostic, endingAt end: Date) -> [Interval] {
        let ordered = record.attempts.sorted { $0.number < $1.number }
        guard !ordered.isEmpty else { return [] }

        var intervals: [Interval] = []
        for (index, attempt) in ordered.enumerated() {
            let isLast = index + 1 >= ordered.count
            let nextStart = isLast ? end : ordered[index + 1].startedAt
            let nextDelay = isLast ? 0 : (ordered[index + 1].retryDelayMilliseconds ?? 0)

            // An attempt ends where its successor's backoff begins, not where the successor starts.
            // Running the bar all the way to the next attempt would draw the wait as part of the
            // work, which is exactly the thing a waterfall exists to tell apart.
            let attemptEnd = max(min(nextStart.addingTimeInterval(-nextDelay / 1000), nextStart), attempt.startedAt)

            intervals.append(
                Interval(label: "Attempt \(attempt.number)", start: attempt.startedAt, end: attemptEnd, isWait: false)
            )

            if nextDelay > 0 {
                intervals.append(
                    Interval(
                        label: String(format: "Backoff %.0f ms", nextDelay),
                        start: attemptEnd,
                        end: max(nextStart, attemptEnd),
                        isWait: true
                    )
                )
            }
        }

        return intervals
    }
}
