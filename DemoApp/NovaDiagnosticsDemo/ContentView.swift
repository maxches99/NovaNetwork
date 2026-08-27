import SwiftUI
import NovaNetworkDiagnostics

/// The demo's one screen: run traffic, then look at what the recorder saw.
struct ContentView: View {
    @State private var session = DemoSession()
    @State private var showsDiagnostics = false
    @State private var exportMessage: String?

    /// Launching with `--autorun` runs every scenario and opens the panel by itself, so screenshots
    /// and demos can be scripted: `xcrun simctl launch <device> <bundle-id> --args --autorun`.
    private var autoruns: Bool { ProcessInfo.processInfo.arguments.contains("--autorun") }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.summary)
                            .font(.callout.monospaced())
                        Text(session.lastAction)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Recorded so far")
                } footer: {
                    Text("Run a scenario, then open Diagnostics to see what the client reported: attempts, backoff, coalescing, cache, and headers with the credential already redacted.")
                }

                Section {
                    Picker("Requests", selection: $session.backend) {
                        ForEach(DemoBackend.allCases) { backend in
                            Text(backend.title).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    if session.backend == .live {
                        LabeledContent("Host") {
                            TextField("https://httpbin.org", text: $session.liveHost)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .multilineTextAlignment(.trailing)
                                .font(.callout.monospaced())
                        }
                    }
                } header: {
                    Text("Backend")
                } footer: {
                    Text(session.backend.explanation)
                }

                Section("Scenarios") {
                    scenario(
                        "Retry until it works",
                        path: session.endpoints.flaky,
                        detail: "Fails, then succeeds. The waterfall shows the time went to backoff, not to the server.",
                        systemImage: "arrow.triangle.2.circlepath"
                    ) { await session.runRetryStorm() }

                    scenario(
                        "Two callers, one request",
                        path: session.endpoints.profile,
                        detail: "Both screens ask for the same thing at the same moment; only one request is made.",
                        systemImage: "arrow.triangle.merge"
                    ) { await session.runCoalescedPair() }

                    scenario(
                        "Read it twice",
                        path: session.endpoints.settings,
                        detail: "The second read is served from cache and never reaches the transport.",
                        systemImage: "tray.full"
                    ) { await session.runCachedRead() }

                    scenario(
                        "Server says no",
                        path: session.endpoints.orders,
                        detail: "A 422 the client turns into an error. It counts as a failure in the summary.",
                        systemImage: "exclamationmark.octagon"
                    ) { await session.runServerRejection() }

                    scenario(
                        "Give up waiting",
                        path: session.endpoints.slow,
                        detail: "The caller cancels. With the default policy the operation keeps running, and the panel shows it still in flight.",
                        systemImage: "xmark.circle"
                    ) { await session.runCancellation() }
                }

                Section {
                    Button {
                        Task { await session.runEverything() }
                    } label: {
                        Label("Run every scenario", systemImage: "play.circle.fill")
                    }
                    .disabled(session.isRunning)

                    Button(role: .destructive) {
                        Task { await session.clear() }
                    } label: {
                        Label("Clear the recorder", systemImage: "trash")
                    }
                    .disabled(session.isRunning)
                }
            }
            .navigationTitle("Nova Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsDiagnostics = true
                    } label: {
                        Label("Diagnostics", systemImage: "waveform.path.ecg")
                    }
                    .badge(session.recordedCount)
                }
            }
            .sheet(isPresented: $showsDiagnostics) {
                // The panel brings its own navigation container, so it is presented bare -- wrapping
                // it in another one would nest two stacks. Swipe down to dismiss.
                NetworkDiagnosticsView(recorder: session.recorder) { _ in
                    Task { exportMessage = await session.exportHAR() }
                }
                .presentationDragIndicator(.visible)
            }
            .alert("HAR export", isPresented: .constant(exportMessage != nil)) {
                Button("OK") { exportMessage = nil }
            } message: {
                Text(exportMessage ?? "")
            }
            .overlay {
                if session.isRunning {
                    ProgressView().controlSize(.large)
                }
            }
            .task {
                guard autoruns else { return }
                await session.runEverything()
                showsDiagnostics = true
            }
        }
    }

    @ViewBuilder
    private func scenario(
        _ title: String,
        path: String,
        detail: String,
        systemImage: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body)
                    // Showing the path keeps the row honest when the backend changes underneath it.
                    Text(path).font(.caption.monospaced()).foregroundStyle(.tint)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(session.isRunning)
    }
}

#Preview {
    ContentView()
}
