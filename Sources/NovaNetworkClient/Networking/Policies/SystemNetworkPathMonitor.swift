import Foundation

#if canImport(Network)
import Network

/// Reports the system's network path, from `Network.framework`.
///
/// The whole point of this type is to be thin: it translates `NWPath` into ``NetworkPath`` and does
/// nothing else, so everything that decides anything — ``NetworkPathPolicy`` — stays testable on a
/// machine that has never had a cellular interface.
@available(iOS 13.0, macOS 10.15, tvOS 13.0, watchOS 6.0, *)
public final class SystemNetworkPathMonitor: NetworkPathMonitor, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var latest: NetworkPath
    private var continuations: [UUID: AsyncStream<NetworkPath>.Continuation] = [:]

    /// Starts monitoring immediately, because a path that is only read on demand is a path that is
    /// always one change out of date.
    public init(queue: DispatchQueue = DispatchQueue(label: "nova.network.path")) {
        self.monitor = NWPathMonitor()
        self.queue = queue
        self.latest = NetworkPath.unrestricted
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        lock.lock()
        let pending = continuations.values
        continuations.removeAll()
        lock.unlock()
        for continuation in pending { continuation.finish() }
    }

    /// The path as of the last update.
    public func currentPath() async -> NetworkPath {
        readLatest()
    }

    /// Taking the lock has to happen outside the async function: `NSLock.lock()` is unavailable
    /// from an async context because a suspension while holding it would be a deadlock waiting to
    /// happen. Nothing suspends in here.
    private func readLatest() -> NetworkPath {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Every change, starting with the value at the moment of subscription.
    public func pathStream() -> AsyncStream<NetworkPath> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            continuations[id] = continuation
            let current = latest
            lock.unlock()

            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    private func handle(_ path: NWPath) {
        let translated = Self.translate(path)
        lock.lock()
        latest = translated
        let listeners = Array(continuations.values)
        lock.unlock()
        for listener in listeners { listener.yield(translated) }
    }

    /// Translates one `NWPath`. Kept `static` and free of instance state so it can be checked in
    /// isolation wherever an `NWPath` can be obtained.
    static func translate(_ path: NWPath) -> NetworkPath {
        var interfaces: Set<NetworkPath.Interface> = []
        if path.usesInterfaceType(.wifi) { interfaces.insert(.wifi) }
        if path.usesInterfaceType(.cellular) { interfaces.insert(.cellular) }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.insert(.wiredEthernet) }
        if path.usesInterfaceType(.loopback) { interfaces.insert(.loopback) }
        if path.usesInterfaceType(.other) { interfaces.insert(.other) }

        let status: NetworkPath.Status
        switch path.status {
        case .satisfied: status = .satisfied
        case .requiresConnection: status = .requiresConnection
        case .unsatisfied: status = .unsatisfied
        @unknown default: status = .unsatisfied
        }

        return NetworkPath(
            status: status,
            interfaces: interfaces,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}
#endif

/// A monitor that always reports the same path.
///
/// Useful as a default, and as the way to test a policy against a path the test machine does not
/// have: `StaticNetworkPathMonitor(.init(status: .satisfied, interfaces: [.cellular], isExpensive: true))`.
public struct StaticNetworkPathMonitor: NetworkPathMonitor {
    private let path: NetworkPath

    /// Creates a monitor reporting one path forever.
    public init(_ path: NetworkPath = .unrestricted) {
        self.path = path
    }

    public func currentPath() async -> NetworkPath { path }

    public func pathStream() -> AsyncStream<NetworkPath> {
        let path = path
        return AsyncStream { continuation in
            continuation.yield(path)
            // A path that never changes has nothing more to say, and a stream that never finishes
            // would keep a consumer waiting forever.
            continuation.finish()
        }
    }
}
