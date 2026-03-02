import Foundation
import NovaNetworkClient

@main
struct OfflineReplayReferenceExample {
    static func main() async {
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClientOfflineReplayReference", isDirectory: true)

        let preset = NetworkClientPreset.offlineFirst
        let client = NetworkClient(
            transport: Transport(),
            retryPolicy: preset.retryPolicy,
            defaultCachePolicy: preset.defaultCachePolicy,
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )
        await client.applyRuntimePolicy(from: preset)

        let writeRequest = APIRequest(
            method: .post,
            url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
            body: Data("{\"title\":\"offline-reference\",\"body\":\"queued\",\"userId\":1}".utf8)
        )

        do {
            let result = try await client.enqueueWrite(
                request: writeRequest,
                authScope: "public",
                options: preset.requestOptions()
            )

            switch result {
            case .completed(let body):
                print("Write completed immediately. Bytes: \(body.count)")
            case .queued(let receipt):
                print("Write queued with id: \(receipt.queueID)")
            }

            let replayed = await client.flushOfflineQueue(limit: 16)
            let metrics = await client.offlineQueuePipelineMetrics()
            print("Replayed entries: \(replayed)")
            print("Queue depth after replay: \(metrics.queueDepth)")
            print("Replay throughput rps: \(metrics.replayThroughput.replaysPerSecond)")
        } catch {
            print("Offline replay reference failed:", error)
        }
    }
}
