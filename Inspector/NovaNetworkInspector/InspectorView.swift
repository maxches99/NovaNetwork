import SwiftUI
import UniformTypeIdentifiers
import NovaNetworkDiagnostics

/// The window: a place to drop a trace, and the panel once one is open.
struct InspectorView: View {
    @State private var model = InspectorModel()
    @State private var showsImporter = false
    @State private var isTargetedForDrop = false

    var body: some View {
        Group {
            if model.fileName == nil {
                emptyState
            } else {
                NetworkDiagnosticsView(recorder: model.recorder)
            }
        }
        // The panel owns the window title once a trace is open, so the file name goes in the
        // subtitle -- which is what tells two windows holding two traces apart.
        .navigationTitle("Nova Network Inspector")
        .navigationSubtitle(model.fileName.map { "\($0) — \(model.requestCount) requests" } ?? "")
        .toolbar {
            ToolbarItem {
                Button("Open", systemImage: "folder") { showsImporter = true }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.open(url) }
            return true
        } isTargeted: { isTargetedForDrop = $0 }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: Self.readableTypes) { result in
            guard case let .success(url) = result else { return }
            Task { await model.open(url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .inspectorOpenRequested)) { _ in
            showsImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .inspectorOpenFile)) { notification in
            guard let url = notification.object as? URL else { return }
            Task { await model.open(url) }
        }
        .alert(
            "Could not open that file",
            isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.clearFailure() } })
        ) {
            Button("OK") { model.clearFailure() }
        } message: {
            Text(model.failure ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)

            Text("Drop a HAR file here")
                .font(.title2)

            Text("A trace exported by NovaNetworkDiagnostics, or a HAR saved from a browser, Charles, or Proxyman.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Button("Open…") { showsImporter = true }
                .keyboardShortcut("o")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargetedForDrop ? AnyShapeStyle(.selection) : AnyShapeStyle(.background))
    }

    /// `.har` has no registered system type, so it is declared by extension and JSON is accepted
    /// alongside it — plenty of tools save a HAR as `.json`.
    private static let readableTypes: [UTType] = {
        var types: [UTType] = [.json]
        if let har = UTType(filenameExtension: "har") {
            types.insert(har, at: 0)
        }
        return types
    }()
}

#Preview {
    InspectorView()
}
