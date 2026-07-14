/// Executes a network request and returns its complete HTTP response.
public protocol NetworkTransport: Sendable {
    /// Executes one request.
    ///
    /// - Parameter request: Immutable request description.
    /// - Returns: Complete response metadata and body.
    /// - Throws: A transport-specific error, normally mapped to ``NetworkError``.
    func execute(_ request: APIRequest) async throws -> NetworkResponse
}
