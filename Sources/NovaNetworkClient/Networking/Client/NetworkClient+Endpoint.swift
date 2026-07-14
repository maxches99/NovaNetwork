import NovaNetworkCore
import Foundation

public extension NetworkClient {
    /// Executes a typed endpoint through the client's standard request pipeline.
    ///
    /// Request coalescing, cache policy, retry policy, circuit breaking, rate limiting,
    /// middleware, and telemetry are applied before the endpoint decodes the returned body.
    ///
    /// - Parameters:
    ///   - endpoint: Endpoint that builds the request and decodes its response.
    ///   - authScope: Stable credential scope used by fingerprinting and authentication.
    ///   - cachePolicy: Optional cache policy override.
    ///   - decoder: Optional JSON decoder used by the endpoint.
    ///   - options: Per-request execution options.
    /// - Returns: The endpoint's typed response.
    /// - Throws: Request construction errors, ``NetworkError``, or
    ///   ``NetworkError/decoding(underlying:)`` when endpoint decoding fails.
    func execute<E: Endpoint>(
        endpoint: E,
        authScope: String?,
        cachePolicy: CachePolicy? = nil,
        decoder: JSONDecoder? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> E.Response {
        let request = try endpoint.makeRequest()
        let data = try await load(
            request: request,
            authScope: authScope,
            cachePolicy: cachePolicy,
            options: options
        )

        do {
            return try endpoint.decode(data, using: decoder ?? self.decoder)
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.decoding(underlying: error)
        }
    }
}
