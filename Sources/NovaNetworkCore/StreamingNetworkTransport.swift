import Foundation

/// Transport capability for incrementally consuming response body chunks.
public protocol StreamingNetworkTransport: NetworkTransport {
    /// Starts an incremental response stream.
    ///
    /// Cancelling or terminating iteration must cancel the underlying transfer.
    func stream(_ request: APIRequest, authScope: String?) -> AsyncThrowingStream<Data, Error>
}
