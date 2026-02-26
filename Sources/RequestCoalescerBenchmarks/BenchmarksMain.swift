import Foundation
import RequestCoalescer

actor BenchmarkTransport: NetworkTransport {
    private(set) var calls = 0
    let delayNanoseconds: UInt64

    init(delayNanoseconds: UInt64) {
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("ok".utf8))
    }
}

@main
struct BenchmarksMain {
    static func main() async {
        let transport = BenchmarkTransport(delayNanoseconds: 1_000_000)
        let client = NetworkClient(
            transport: transport,
            coalescerLimits: .init(maxInFlightKeys: 64, maxWaitersPerKey: 10_000)
        )
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/benchmark")!)
        let iterations = 2_000

        let start = DispatchTime.now().uptimeNanoseconds
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<iterations {
                group.addTask {
                    _ = try? await client.load(request: request, authScope: "bench")
                }
            }
        }
        let end = DispatchTime.now().uptimeNanoseconds

        let elapsedMs = Double(end - start) / 1_000_000
        let calls = await transport.calls
        print("benchmark_iterations=\(iterations)")
        print("transport_calls=\(calls)")
        print(String(format: "elapsed_ms=%.2f", elapsedMs))
    }
}
