import Foundation

/// Controls automatic reconnection for `NetworkClient.loadServerSentEvents`.
public struct SSEReconnectPolicy: Sendable, Equatable {
    /// Whether the client reconnects after the stream ends or fails.
    public var isEnabled: Bool
    /// Maximum consecutive reconnect attempts before giving up, or `nil` for unlimited.
    public var maxAttempts: Int?
    /// Reconnection delay used until the server sends a `retry:` field.
    public var defaultDelayNanoseconds: UInt64
    /// Upper bound applied to both the default delay and any server-provided `retry:` value.
    public var maxDelayNanoseconds: UInt64

    public init(
        isEnabled: Bool = true,
        maxAttempts: Int? = nil,
        defaultDelayNanoseconds: UInt64 = 3_000_000_000,
        maxDelayNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.isEnabled = isEnabled
        self.maxAttempts = maxAttempts
        self.defaultDelayNanoseconds = defaultDelayNanoseconds
        self.maxDelayNanoseconds = maxDelayNanoseconds
    }

    /// Reconnection disabled; the stream finishes or fails after the first attempt.
    public static let disabled = SSEReconnectPolicy(isEnabled: false)
}
