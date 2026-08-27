import Foundation
import NovaNetworkClient
import NovaNetworkCore
import NovaNetworkDiagnostics
import Observation

/// Wires a client to a recorder and runs the scenarios the demo offers.
///
/// The wiring is the whole point, and it is four lines: build the recorder, hand it the hooks, feed
/// the client's events in. Nothing else in the app knows diagnostics exists — and nothing about it
/// changes when the traffic switches from the scripted transport to a real one.
@Observable
@MainActor
final class DemoSession {
    /// What the panel reads.
    let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 100, emitsSignposts: true))

    /// Whether requests are scripted in-process or actually go out over the network.
    ///
    /// Written as a computed property rather than one with a `didSet` so the initialiser can choose
    /// a starting backend without the observer firing before there is a client to replace.
    var backend: DemoBackend {
        get { storedBackend }
        set {
            guard newValue != storedBackend else { return }
            storedBackend = newValue
            rebuildClient()
        }
    }

    /// The httpbin-compatible host live requests go to.
    var liveHost = "https://httpbin.org"

    /// A short line describing what just happened, for the screen.
    private(set) var lastAction = "Nothing yet — run a scenario."
    /// Whether a scenario is in flight, so the buttons can show it.
    private(set) var isRunning = false
    /// Requests recorded so far, refreshed after each scenario.
    private(set) var recordedCount = 0
    /// The summary line the recorder produces.
    private(set) var summary = "No requests recorded yet."

    /// The paths the scenarios will use, so the screen can show what it is about to request.
    var endpoints: DemoEndpoints {
        switch backend {
        case .scripted:
            .scripted
        case .live:
            .live(host: URL(string: liveHost.trimmingCharacters(in: .whitespaces)) ?? DemoEndpoints.scripted.base)
        }
    }

    private var storedBackend: DemoBackend
    @ObservationIgnored private var client: NetworkClient
    @ObservationIgnored private var consumer: Task<Void, Never>?

    init() {
        // `--live` starts against the real host, so the live path can be demonstrated and screenshot
        // without anyone tapping the picker.
        let initial: DemoBackend = ProcessInfo.processInfo.arguments.contains("--live") ? .live : .scripted
        storedBackend = initial
        client = NetworkClient(configuration: DemoSession.configuration(for: initial, recorder: recorder))
        consumer = recorder.startConsuming(client.events())
    }

    deinit {
        consumer?.cancel()
    }

    // MARK: - Scenarios

    /// A request that fails before it works. The panel shows where the time actually went.
    func runRetryStorm() async {
        await run("Retried until it worked") { client, endpoints in
            _ = try? await client.load(
                request: Self.request(endpoints.url(endpoints.flaky), headers: ["Authorization": "Bearer demo-token"]),
                authScope: "user:42"
            )
        }
    }

    /// Two screens asking for the same thing at the same moment.
    func runCoalescedPair() async {
        await run("Two callers shared one request") { client, endpoints in
            let request = Self.request(endpoints.url(endpoints.profile))
            async let first = client.load(request: request, authScope: "user:42")
            async let second = client.load(request: request, authScope: "user:42")
            _ = try? await (first, second)
        }
    }

    /// The same read twice: the second comes from cache and never reaches the transport.
    func runCachedRead() async {
        await run("Second read came from cache") { client, endpoints in
            let request = Self.request(endpoints.url(endpoints.settings))
            _ = try? await client.load(request: request, authScope: "user:42", cachePolicy: .cacheFirst(maxAge: 120))
            _ = try? await client.load(request: request, authScope: "user:42", cachePolicy: .cacheFirst(maxAge: 120))
        }
    }

    /// A request the server rejects, so the panel has something red in it.
    func runServerRejection() async {
        await run("Server rejected the order") { client, endpoints in
            _ = try? await client.load(
                request: Self.request(
                    endpoints.url(endpoints.orders),
                    method: .post,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"lineItems":[]}"#.utf8)
                ),
                authScope: "user:42"
            )
        }
    }

    /// A caller that gives up. The operation keeps running, and the panel says so.
    func runCancellation() async {
        await run("Caller gave up; the request did not") { client, endpoints in
            let task = Task {
                try await client.load(request: Self.request(endpoints.url(endpoints.slow)), authScope: "user:42")
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            task.cancel()
            _ = await task.result
        }
    }

    /// Everything above, in order.
    func runEverything() async {
        await runRetryStorm()
        await runCoalescedPair()
        await runCachedRead()
        await runServerRejection()
        await runCancellation()
        lastAction = "Ran every scenario"
    }

    /// Forgets every recorded request.
    func clear() async {
        await recorder.clear()
        await refresh()
        lastAction = "Cleared the recorder"
    }

    /// Writes a HAR next to the app's documents, the way a support build would.
    func exportHAR() async -> String {
        guard let data = try? await recorder.exportHAR() else { return "Export failed" }
        let url = URL.documentsDirectory.appendingPathComponent("nova-diagnostics.har")
        do {
            try data.write(to: url)
            return "Wrote \(data.count) bytes to \(url.lastPathComponent)"
        } catch {
            return "Could not write the file: \(error.localizedDescription)"
        }
    }

    // MARK: - Plumbing

    /// A backend switch means a new client, a new event stream, and a recorder that would otherwise
    /// be showing two backends' requests in one list.
    private func rebuildClient() {
        consumer?.cancel()
        client = NetworkClient(configuration: DemoSession.configuration(for: backend, recorder: recorder))
        consumer = recorder.startConsuming(client.events())
        Task {
            await recorder.clear()
            await refresh()
            lastAction = "Switched to \(backend.title.lowercased()) requests"
        }
    }

    private static func configuration(
        for backend: DemoBackend,
        recorder: DiagnosticsRecorder
    ) -> NetworkClientConfiguration {
        var configuration = NetworkClientConfiguration()
        if backend == .scripted {
            configuration.transport = DemoAPI()
        }
        configuration.retryPolicy = RetryPolicy(maxAttempts: 3)
        configuration.cache = MemoryResponseCache(maxEntries: 32)
        configuration.telemetryHooks = recorder.hooks
        return configuration
    }

    private func run(
        _ label: String,
        _ work: @escaping @Sendable (NetworkClient, DemoEndpoints) async -> Void
    ) async {
        isRunning = true
        lastAction = "Running…"
        await work(client, endpoints)
        // Hooks hand their work to the recorder asynchronously, so give the last of it a moment.
        try? await Task.sleep(nanoseconds: 120_000_000)
        await refresh()
        lastAction = label
        isRunning = false
    }

    private func refresh() async {
        let snapshot = await recorder.snapshot()
        recordedCount = snapshot.count
        summary = await recorder.summary().shortDescription
    }

    /// Building a request touches no state, so scenarios can do it off the main actor.
    private nonisolated static func request(
        _ url: URL,
        method: URLMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> APIRequest {
        APIRequest(method: method, url: url, headers: headers, body: body)
    }
}
