import Foundation
import NovaNetworkClient

@main
struct OfflineQueueExample {
    static func main() async {
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaNetworkClientOfflineQueueExample", isDirectory: true)

        let client = NetworkClient(
            transport: Transport(),
            offlineWriteStore: DiskOfflineWriteStore(directoryURL: queueURL)
        )

        let writeRequest = APIRequest(
            method: .post,
            url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
            body: Data("{\"title\":\"from-example\",\"body\":\"hello\",\"userId\":1}".utf8)
        )

        do {
            let result = try await client.enqueueWrite(
                request: writeRequest,
                authScope: "public",
                options: .init(
                    offlineQueuePolicy: .init(mode: .enqueueWhenOffline)
                )
            )

            switch result {
            case .completed(let payload):
                print("Sent immediately, bytes: \(payload.count)")
            case .queued(let receipt):
                print("Queued for replay: \(receipt.queueID)")
            }

            let depth = await client.offlineQueueDepth()
            print("Current queue depth: \(depth)")
        } catch {
            print("Example failed: \(error)")
        }
    }
}
