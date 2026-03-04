import Foundation

public protocol OfflineConnectivityMonitor: Sendable {
    func statusStream() -> AsyncStream<Bool>
}
