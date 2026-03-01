import Foundation
import NovaNetworkClient

@main
struct DiagnosticsReferenceExample {
    static func main() async {
        let preset = NetworkClientPreset.restHeavy
        let client = NetworkClient(
            transport: Transport(),
            retryPolicy: preset.retryPolicy,
            defaultCachePolicy: preset.defaultCachePolicy,
            telemetryHooks: .init(
                onRequestStart: { context in
                    print("[telemetry] start key=\(context.key) attempt=\(context.attempt)")
                },
                onRequestEnd: { context in
                    print("[telemetry] end durationMs=\(Int(context.durationMilliseconds)) error=\(String(describing: context.error))")
                },
                onPolicyUpdated: { context in
                    print("[telemetry] policy scope=\(context.scope) changed=\(context.changedFields)")
                }
            )
        )

        await client.applyRuntimePolicy(from: preset)

        let eventStream = client.events()
        let eventTask = Task {
            var count = 0
            for await event in eventStream {
                print("[event] \(event)")
                count += 1
                if count >= 4 { break }
            }
        }

        let request = APIRequest(method: .get, url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!)

        do {
            _ = try await client.load(request: request, authScope: "public", options: preset.requestOptions())
            _ = try await client.load(request: request, authScope: "public", options: preset.requestOptions())
            let inFlight = await client.inFlightRequests()
            print("In-flight after requests: \(inFlight.count)")
        } catch {
            print("Diagnostics reference failed:", error)
        }

        eventTask.cancel()
    }
}
