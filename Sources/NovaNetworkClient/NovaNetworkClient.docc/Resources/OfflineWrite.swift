import Foundation
import NovaNetworkClient

@main
struct OfflineWriteTutorial {
    static func main() async {
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaOfflineWriteTutorial", isDirectory: true)
        let store = DiskOfflineWriteStore(directoryURL: queueURL)
        let client = NetworkClient(transport: Transport(), offlineWriteStore: store)
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
            headers: ["Idempotency-Key": UUID().uuidString],
            body: Data("{\"title\":\"offline\",\"userId\":1}".utf8)
        )
        let options = RequestExecutionOptions(
            offlineQueuePolicy: .init(
                mode: .enqueueWhenOffline,
                maxEntries: 100,
                ttlSeconds: 86_400
            )
        )

        do {
            let result = try await client.enqueueWrite(
                request: request,
                authScope: "public",
                options: options
            )
            switch result {
            case .completed(let payload):
                print("Sent immediately: \(payload.count) bytes")
            case .queued(let receipt):
                print("Queued for replay: \(receipt.queueID)")
            }
            print("Queue depth: \(await client.offlineQueueDepth())")
        } catch {
            print("Offline write failed: \(error.localizedDescription)")
        }
    }
}
