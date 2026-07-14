import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-CONC-1...3.

private actor StreamTerminationProbe {
    private var terminated = false

    func markTerminated() {
        terminated = true
    }

    func isTerminated() -> Bool {
        terminated
    }
}

private struct LifetimeConnectivityMonitor: OfflineConnectivityMonitor {
    let stream: AsyncStream<Bool>

    init(probe: StreamTerminationProbe) {
        stream = AsyncStream { continuation in
            continuation.onTermination = { _ in
                Task {
                    await probe.markTerminated()
                }
            }
        }
    }

    func statusStream() -> AsyncStream<Bool> {
        stream
    }
}

@Suite
struct ConcurrencySafetyTests {
    @Test
    func networkClientIsStaticallySendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(NetworkClient.self)
    }

    @Test
    func clientLifetimeCancelsConnectivityListenerOnDeallocation() async {
        let probe = StreamTerminationProbe()
        let monitor = LifetimeConnectivityMonitor(probe: probe)
        weak var weakClient: NetworkClient?

        do {
            let client = NetworkClient(offlineConnectivityMonitor: monitor)
            weakClient = client
            for _ in 0..<20 {
                await Task.yield()
            }
        }

        for _ in 0..<200 {
            if weakClient == nil, await probe.isTerminated() {
                break
            }
            await Task.yield()
        }

        #expect(weakClient == nil)
        #expect(await probe.isTerminated())
    }
}
