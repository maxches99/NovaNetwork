import Foundation
import NovaNetworkClient
import NovaNetworkDiagnostics

/// Shows what the diagnostics recorder sees: retries with their backoff, coalesced callers, and a
/// HAR file you could attach to a bug report.
///
/// The transport is scripted rather than live so the interesting cases — a server error that gets
/// retried, two callers sharing one request — happen every time instead of only on a bad day.
@main
struct DiagnosticsExample {
    /// Fails the first two attempts, then succeeds, so a retry sequence is guaranteed.
    actor FlakyTransport: NetworkTransport {
        private var attempts = 0

        func execute(_ request: APIRequest) async throws -> NetworkResponse {
            attempts += 1
            if request.url.path == "/flaky", attempts <= 2 {
                // The real URLSession-backed Transport turns a non-2xx into this error, and that is
                // what the retry policy reacts to. A test transport that returns a 500 as a plain
                // response is telling the client the exchange succeeded with status 500.
                throw NetworkError.httpStatus(
                    code: 500,
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"try again"}"#.utf8)
                )
            }
            return NetworkResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"id":1,"name":"Ada"}"#.utf8)
            )
        }
    }

    struct User: Decodable, Sendable {
        let id: Int
        let name: String
    }

    static func main() async {
        let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 50, emitsSignposts: true))

        var configuration = NetworkClientConfiguration()
        configuration.transport = FlakyTransport()
        configuration.retryPolicy = RetryPolicy(maxAttempts: 3)
        configuration.telemetryHooks = recorder.hooks
        let client = NetworkClient(configuration: configuration)
        recorder.startConsuming(client.events())

        let flaky = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/flaky")!,
            headers: ["Authorization": "Bearer example-token"]
        )
        let shared = APIRequest(method: .get, url: URL(string: "https://api.example.com/shared")!)

        do {
            _ = try await client.load(request: flaky, authScope: "demo") as User

            // Two callers, one request: the second joins the first instead of starting its own.
            async let first: User = client.load(request: shared, authScope: "demo")
            async let second: User = client.load(request: shared, authScope: "demo")
            _ = try await (first, second)
        } catch {
            print("Requests failed: \(error.localizedDescription)")
        }

        // Hooks hand work to the recorder asynchronously, so let the last of it land.
        try? await Task.sleep(nanoseconds: 100_000_000)

        let summary = await recorder.summary()
        print(summary.shortDescription)
        print("")

        for record in await recorder.snapshot() {
            print(record.shortDescription)
            for segment in DiagnosticsPanelState.timeline(for: record) {
                let width = max(Int(segment.widthFraction * 40), 1)
                let indent = String(repeating: " ", count: Int(segment.startFraction * 40))
                let bar = String(repeating: segment.isWait ? "·" : "█", count: width)
                print("  \(indent)\(bar) \(segment.label)")
            }
        }

        do {
            let har = try await recorder.exportHAR()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nova-diagnostics.har")
            try har.write(to: url)
            let text = String(decoding: har, as: UTF8.self)
            print("")
            print("HAR written to \(url.path) (\(har.count) bytes)")
            print("Credential redacted in the export: \(!text.contains("example-token"))")
            print("Open it in any browser's network inspector, or attach it to a bug report.")
        } catch {
            print("Export failed: \(error.localizedDescription)")
        }
    }
}
