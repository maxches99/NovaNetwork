import Foundation

public struct NetworkMiddleware: Sendable {
    public typealias BeforeSend = @Sendable (_ request: APIRequest, _ authScope: String?) async throws -> APIRequest
    public typealias AfterResponse = @Sendable (_ request: APIRequest, _ authScope: String?, _ response: NetworkResponse) async throws -> NetworkResponse

    public let beforeSend: BeforeSend?
    public let afterResponse: AfterResponse?

    public init(
        beforeSend: BeforeSend? = nil,
        afterResponse: AfterResponse? = nil
    ) {
        self.beforeSend = beforeSend
        self.afterResponse = afterResponse
    }
}
