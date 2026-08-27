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
    @State private var selected: UUID?

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
            List(selection: $selected) {
                Section {
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
            .refreshable { await refresh() }
        }
    }

    private func refresh() async {
        state = DiagnosticsPanelState(records: await recorder.snapshot())
    }

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
        .navigationTitle(record.method)
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
