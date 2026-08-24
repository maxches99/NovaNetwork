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
    }
}
