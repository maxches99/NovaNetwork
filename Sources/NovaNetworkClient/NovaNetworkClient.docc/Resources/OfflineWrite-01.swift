import Foundation
import NovaNetworkClient

@main
struct OfflineWriteTutorial {
    static func main() async {
        let queueURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaOfflineWriteTutorial", isDirectory: true)
        let store = DiskOfflineWriteStore(directoryURL: queueURL)
        let client = NetworkClient(transport: Transport(), offlineWriteStore: store)
    }
}
