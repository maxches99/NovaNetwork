import NovaNetworkCore
import Foundation

public extension NetworkClient {
    /// Loads a request, wrapping any thrown ``NetworkError`` with ``ContextualNetworkError``
    /// carrying the request's URL, method, and auth scope — useful for logging or crash
    /// reporting call sites that want that context attached automatically. Otherwise identical
    /// to `load(request:authScope:cachePolicy:options:)`.
    func loadWithContext(
        request: APIRequest,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> Data {
        do {
            return try await load(
                request: request,
                authScope: authScope,
                cachePolicy: cachePolicy,
                options: options
            )
        } catch let error as NetworkError {
            throw error.with(request: request, authScope: authScope)
        }
    }
}
