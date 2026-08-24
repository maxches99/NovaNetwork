import NovaNetworkCore
import Foundation

public extension NetworkClient {
    /// Loads a request and returns the full response (status code, headers, and body).
    ///
    /// Always bypasses the response cache, matching `cachePolicy: .networkOnly` semantics. Use
    /// this when a caller needs response headers — for example to negotiate a decoding strategy
    /// by `Content-Type` via ``decode(request:authScope:as:responseDecoding:options:)`` — since
    /// the plain `load(request:authScope:cachePolicy:options:)` only returns the body.
    func loadResponse(
        request: APIRequest,
        authScope: String?,
        options: RequestExecutionOptions = .init()
    ) async throws -> NetworkResponse {
        let key = makeFingerprint(for: request, authScope: authScope).key
        return try await fetchNetworkAndOptionallyStore(
            request: request,
            authScope: authScope,
            key: key,
            storeInCache: false,
            cachedETag: nil,
            options: options
        )
    }

    /// Loads and decodes a request using a ``ResponseDecoding`` strategy.
    ///
    /// Unlike `load<T: Decodable>(...)`, which always decodes with a fixed `JSONDecoder`, the
    /// strategy here sees the full response — including headers — so it can pick how to decode
    /// per response, for example negotiating by `Content-Type` via
    /// ``ContentTypeNegotiatingResponseDecoding``. Falls back to
    /// `configuration.responseDecoding`, or `JSONResponseDecoding` using the client's configured
    /// `decoder`, when `responseDecoding` is not supplied. Always bypasses the response cache,
    /// matching ``loadResponse(request:authScope:options:)``.
    func decode<T: Decodable & Sendable>(
        request: APIRequest,
        authScope: String?,
        as type: T.Type = T.self,
        responseDecoding: (any ResponseDecoding)? = nil,
        options: RequestExecutionOptions = .init()
    ) async throws -> T {
        let response = try await loadResponse(request: request, authScope: authScope, options: options)
        let decoding = responseDecoding ?? self.responseDecoding ?? JSONResponseDecoding(decoder: decoder)
        do {
            return try decoding.decode(T.self, from: response)
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.decoding(underlying: error)
        }
    }
}
