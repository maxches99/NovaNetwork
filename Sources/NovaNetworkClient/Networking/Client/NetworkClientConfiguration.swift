import NovaNetworkCore
import Foundation

/// Groups every ``NetworkClient`` construction option into one mutable value.
///
/// Start from the defaulted `init()`, mutate the fields you need, and pass the result to
/// ``NetworkClient/init(configuration:)``:
///
/// ```swift
/// var configuration = NetworkClientConfiguration()
/// configuration.retryPolicy = RetryPolicy(maxAttempts: 3)
/// configuration.middlewares = [authMiddleware]
/// configuration.telemetryHooks = hooks
/// let client = NetworkClient(configuration: configuration)
/// ```
///
/// This is equivalent to, and interchangeable with, calling `NetworkClient.init` directly with
/// the same set of labeled arguments; use whichever reads better at the call site.
public struct NetworkClientConfiguration: Sendable {
    /// The transport used to execute requests.
    public var transport: any NetworkTransport
    /// Coalescer waiter cancellation behavior.
    public var cancellationPolicy: CancellationPolicy
    /// Coalescer capacity limits.
    public var coalescerLimits: RequestCoalescer<NetworkResponse, NetworkError>.Limits
    /// Request fingerprinting policy used for coalescing and caching keys.
    public var fingerprintPolicy: FingerprintPolicy
    /// Retry and backoff policy for transient failures.
    public var retryPolicy: RetryPolicy
    /// Clock used to sleep between retry attempts.
    public var retryClock: any RetryClock
    /// Random source used for retry jitter.
    public var retryRandomGenerator: any RetryRandomGenerator
    /// Cache policy applied when a request does not specify its own.
    public var defaultCachePolicy: CachePolicy
    /// Maximum entries for the default in-memory cache, when `cache` is `nil`.
    public var cacheMaxEntries: Int?
    /// Pluggable response cache; defaults to an in-memory cache bounded by `cacheMaxEntries`.
    public var cache: (any ResponseCache)?
    /// Durable store for offline-queued write requests.
    public var offlineWriteStore: (any OfflineWriteStore)?
    /// Monitor used to flush the offline queue when connectivity returns.
    public var offlineConnectivityMonitor: (any OfflineConnectivityMonitor)?
    /// Resolves conflicts encountered while replaying offline-queued writes.
    public var offlineConflictResolver: (@Sendable (OfflineQueueConflictMetadata) -> OfflineConflictResolutionDecision)?
    /// Low-level coalescer event observer.
    public var observer: RequestCoalescer<NetworkResponse, NetworkError>.Observer?
    /// High-level client event observer.
    public var networkObserver: (@Sendable (NetworkClientEvent) -> Void)?
    /// Request/response middleware pipeline, applied in order.
    public var middlewares: [NetworkMiddleware]
    /// Telemetry hooks for tracing/metrics adapters.
    public var telemetryHooks: NetworkTelemetryHooks?
    /// Enables single-flight HTTP authentication refresh when supplied.
    public var httpAuthRefreshProvider: HTTPAuthRefreshProvider?
    /// Controls which responses trigger authentication refresh and replay.
    public var httpAuthRefreshPolicy: HTTPAuthRefreshPolicy
    /// Decoder used for typed `Decodable` responses.
    public var decoder: JSONDecoder
    /// Default strategy for `NetworkClient.decode(request:...)`, used when a call site does not
    /// supply its own. `nil` uses `JSONResponseDecoding(decoder: decoder)`.
    public var responseDecoding: (any ResponseDecoding)?

    /// Creates a configuration with the same defaults as `NetworkClient.init`.
    public init(
        transport: any NetworkTransport = Transport(),
        cancellationPolicy: CancellationPolicy = .keepRunning,
        coalescerLimits: RequestCoalescer<NetworkResponse, NetworkError>.Limits = .init(),
        fingerprintPolicy: FingerprintPolicy = .default,
        retryPolicy: RetryPolicy = .none,
        retryClock: any RetryClock = SystemRetryClock(),
        retryRandomGenerator: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        defaultCachePolicy: CachePolicy = .networkOnly,
        cacheMaxEntries: Int? = 256,
        cache: (any ResponseCache)? = nil,
        offlineWriteStore: (any OfflineWriteStore)? = nil,
        offlineConnectivityMonitor: (any OfflineConnectivityMonitor)? = nil,
        offlineConflictResolver: (@Sendable (OfflineQueueConflictMetadata) -> OfflineConflictResolutionDecision)? = nil,
        observer: RequestCoalescer<NetworkResponse, NetworkError>.Observer? = nil,
        networkObserver: (@Sendable (NetworkClientEvent) -> Void)? = nil,
        middlewares: [NetworkMiddleware] = [],
        telemetryHooks: NetworkTelemetryHooks? = nil,
        httpAuthRefreshProvider: HTTPAuthRefreshProvider? = nil,
        httpAuthRefreshPolicy: HTTPAuthRefreshPolicy = .default,
        decoder: JSONDecoder = JSONDecoder(),
        responseDecoding: (any ResponseDecoding)? = nil
    ) {
        self.transport = transport
        self.cancellationPolicy = cancellationPolicy
        self.coalescerLimits = coalescerLimits
        self.fingerprintPolicy = fingerprintPolicy
        self.retryPolicy = retryPolicy
        self.retryClock = retryClock
        self.retryRandomGenerator = retryRandomGenerator
        self.defaultCachePolicy = defaultCachePolicy
        self.cacheMaxEntries = cacheMaxEntries
        self.cache = cache
        self.offlineWriteStore = offlineWriteStore
        self.offlineConnectivityMonitor = offlineConnectivityMonitor
        self.offlineConflictResolver = offlineConflictResolver
        self.observer = observer
        self.networkObserver = networkObserver
        self.middlewares = middlewares
        self.telemetryHooks = telemetryHooks
        self.httpAuthRefreshProvider = httpAuthRefreshProvider
        self.httpAuthRefreshPolicy = httpAuthRefreshPolicy
        self.decoder = decoder
        self.responseDecoding = responseDecoding
    }
}

public extension NetworkClientConfiguration {
    /// Appends one middleware to the pipeline, preserving existing entries' order.
    mutating func addMiddleware(_ middleware: NetworkMiddleware) {
        middlewares.append(middleware)
    }
}
