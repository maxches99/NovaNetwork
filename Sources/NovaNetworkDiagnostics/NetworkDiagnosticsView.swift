#if canImport(SwiftUI)
import SwiftUI

/// A panel showing what the client has been doing: live requests, a summary, and one request's
/// timeline.
///
/// This is a development and support tool, not production monitoring — the OpenTelemetry adapter
/// remains the path to a backend. Present it from a debug menu, a shake gesture, or a preview:
///
/// ```swift
/// .sheet(isPresented: $showsDiagnostics) {
///     NetworkDiagnosticsView(recorder: recorder)
/// }
/// ```
@available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *)
public struct NetworkDiagnosticsView: View {
    private let recorder: DiagnosticsRecorder
    private let onExportHAR: (@Sendable (Data) -> Void)?

    @State private var state = DiagnosticsPanelState(records: [])
    @State private var timeline = DiagnosticsTimeline(records: [], now: Date())
    @State private var mode = Mode.list

    /// The two ways to read the same snapshot.
    private enum Mode: String, CaseIterable, Identifiable {
        /// Newest request first, which is what you want while something is going wrong now.
        case list = "List"
        /// Every request on one clock, which is what you want to see what overlapped what.
        case timeline = "Timeline"

        var id: String { rawValue }
    }

    /// Creates the panel.
    ///
    /// - Parameters:
    ///   - recorder: The recorder to read from.
    ///   - onExportHAR: Called with an exported HAR when the export button is used. Presenting a
    ///     share sheet or writing the file is left to the app, which knows where its files go.
    public init(recorder: DiagnosticsRecorder, onExportHAR: (@Sendable (Data) -> Void)? = nil) {
        self.recorder = recorder
        self.onExportHAR = onExportHAR
    }

    public var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .list: requestList
                case .timeline: requestTimeline
                }
            }
            .navigationTitle("Network")
            .navigationDestination(for: UUID.self) { id in
                if let record = state.record(for: id) {
                    detail(for: record)
                }
            }
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                Button("Clear", systemImage: "trash") {
                    Task {
                        await recorder.clear()
                        await refresh()
                    }
                }
                if let onExportHAR {
                    Button("Export", systemImage: "square.and.arrow.up") {
                        Task {
                            if let data = try? await recorder.exportHAR() {
                                onExportHAR(data)
                            }
                        }
                    }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        let records = await recorder.snapshot()
        state = DiagnosticsPanelState(records: records)
        timeline = DiagnosticsTimeline(records: records, now: Date())
    }

    // MARK: - List

    @ViewBuilder
    private var requestList: some View {
        List {
            Section {
                modePicker
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                Text(state.summary.shortDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Requests") {
                if state.rows.isEmpty {
                    Text("No requests recorded yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(state.rows) { row in
                    NavigationLink(value: row.id) {
                        rowView(row)
                    }
                }
            }
        }
        .refreshable { await refresh() }
    }

    private var modePicker: some View {
        Picker("View", selection: $mode) {
            ForEach(Mode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .padding(.vertical, 4)
    }

    // MARK: - Timeline

    /// Every request on one clock: a fixed gutter of names, and a shared track beside it.
    ///
    /// The ruler sits outside the scroll view so it stays put while the lanes move, which is the
    /// whole reason to read a trace this way.
    @ViewBuilder
    private var requestTimeline: some View {
        VStack(spacing: 0) {
            modePicker
                .padding(.horizontal)

            Text(state.summary.shortDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 6)

            if timeline.isEmpty {
                Spacer()
                Text("No requests recorded yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ruler
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(timeline.lanes.enumerated()), id: \.element.id) { index, lane in
                            NavigationLink(value: lane.id) {
                                laneRow(lane)
                            }
                            .buttonStyle(.plain)
                            .background(index.isMultiple(of: 2) ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quinary))
                        }
                    }
                }
            }
        }
    }

    private var ruler: some View {
        HStack(spacing: 0) {
            Text(Self.windowLabel(for: timeline))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: Self.gutterWidth, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // Labels sit just right of the gridline they name, and one that would not fit
                    // before the edge is left off rather than clipped mid-word. The gridline is
                    // still drawn, and the gutter already says how long the whole window is.
                    ForEach(timeline.ticks.filter { Self.labelFits($0, within: proxy.size.width) }) { tick in
                        Text(tick.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .offset(x: proxy.size.width * tick.fraction + 3)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
    }

    private func laneRow(_ lane: DiagnosticsTimeline.Lane) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(lane.title)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(lane.durationText ?? lane.statusText)
                    .font(.caption2)
                    .foregroundStyle(color(for: lane.statusKind))
                    .lineLimit(1)
            }
            .frame(width: Self.gutterWidth, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    gridlines(width: proxy.size.width)

                    ForEach(lane.bars) { bar in
                        // A rectangle rather than a capsule: at these widths a capsule rounds itself
                        // into a dot, and a dot does not read as a span of time.
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(bar.isWait ? AnyShapeStyle(.tertiary) : AnyShapeStyle(color(for: lane.statusKind)))
                            .frame(width: max(proxy.size.width * bar.widthFraction, 3), height: bar.isWait ? 4 : 9)
                            .offset(x: proxy.size.width * bar.startFraction)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
            }
            .frame(height: 26)
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
    }

    private func gridlines(width: CGFloat) -> some View {
        ForEach(timeline.ticks) { tick in
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .offset(x: width * tick.fraction)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
    }

    /// How much wall-clock time the whole track covers.
    private static func windowLabel(for timeline: DiagnosticsTimeline) -> String {
        let window = timeline.durationMilliseconds
        return window >= 1_000
            ? String(format: "%.1f s total", window / 1_000)
            : String(format: "%.0f ms total", window)
    }

    /// Whether a tick's label still has room before the right edge of the track.
    ///
    /// Caption text is not measured here -- a per-character estimate is enough to decide whether to
    /// draw a label at all, and being a few points pessimistic only drops a label that was going to
    /// be cut off anyway.
    private static func labelFits(_ tick: DiagnosticsTimeline.Tick, within width: CGFloat) -> Bool {
        let estimated = CGFloat(tick.label.count) * 6.5 + 6
        return width * tick.fraction + estimated <= width
    }

    /// Wide enough for `POST /orders` at caption size, narrow enough to leave the track the screen.
    private static let gutterWidth: CGFloat = 132

    @ViewBuilder
    private func rowView(_ row: DiagnosticsPanelState.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.title).font(.callout.monospaced()).lineLimit(1)
                Spacer()
                Text(row.statusText).font(.caption).foregroundStyle(color(for: row.statusKind))
            }
            HStack(spacing: 6) {
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(row.badges, id: \.self) { badge in
                    Text(badge)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let durationText = row.durationText {
                    Text(durationText).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(for record: RequestDiagnostic) -> some View {
        List {
            Section("Outcome") {
                LabeledContent("Status", value: record.shortDescription)
                if let cache = record.cacheOutcome {
                    LabeledContent("Cache", value: cache.servedFromCache ? "served" : "miss")
                }
                LabeledContent("Coalesced", value: record.wasCoalesced ? "yes" : "no")
            }

            let segments = DiagnosticsPanelState.timeline(for: record)
            if !segments.isEmpty {
                Section("Timeline") {
                    ForEach(segments) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(segment.label).font(.caption)
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(segment.isWait ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                                    .frame(width: max(proxy.size.width * segment.widthFraction, 2), height: 6)
                                    .offset(x: proxy.size.width * segment.startFraction)
                            }
                            .frame(height: 8)
                        }
                    }
                }
            }

            headerSection("Request headers", record.requestHeaders)
            headerSection("Response headers", record.responseHeaders)
        }
        // The method alone does not identify the request when several share it.
        .navigationTitle("\(record.method) \(URL(string: record.url)?.path ?? record.url)")
    }

    @ViewBuilder
    private func headerSection(_ title: String, _ headers: [String: String]) -> some View {
        if !headers.isEmpty {
            Section(title) {
                ForEach(headers.keys.sorted(), id: \.self) { name in
                    LabeledContent(name, value: headers[name] ?? "")
                        .font(.caption.monospaced())
                }
            }
        }
    }

    private func color(for kind: DiagnosticsPanelState.StatusKind) -> Color {
        switch kind {
        case .success: .green
        case .failure: .red
        case .cancelled: .orange
        case .inFlight: .secondary
        }
    }
}
#endif
