import Foundation

/// Optional asynchronous transformations around one HTTP execution.
public struct NetworkMiddleware: Sendable {
    /// Transforms a request before transport execution.
    public typealias BeforeSend = @Sendable (_ request: APIRequest, _ authScope: String?) async throws -> APIRequest
    /// Transforms a successful response after transport execution.
    public typealias AfterResponse = @Sendable (_ request: APIRequest, _ authScope: String?, _ response: NetworkResponse) async throws -> NetworkResponse

    /// Request transformation, or `nil` when unused.
    public let beforeSend: BeforeSend?
    /// Response transformation, or `nil` when unused.
    public let afterResponse: AfterResponse?

    /// Creates middleware from optional before-send and after-response operations.
    public init(
        beforeSend: BeforeSend? = nil,
        afterResponse: AfterResponse? = nil
    ) {
        self.beforeSend = beforeSend
        self.afterResponse = afterResponse
    }
}
