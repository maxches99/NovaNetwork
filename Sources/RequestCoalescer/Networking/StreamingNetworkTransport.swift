import Foundation

public protocol StreamingNetworkTransport: NetworkTransport {
    func stream(_ request: APIRequest, authScope: String?) -> AsyncThrowingStream<Data, Error>
}
