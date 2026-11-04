import Foundation
import NovaNetworkClient
import NovaNetworkCore

/// Whether to send a document's hash instead of the document.
public enum GraphQLPersistedQueries: Sendable, Equatable {
    /// Always send the document.
    case disabled
    /// Apollo's automatic persisted queries: send the SHA-256 of the document, and the document only
    /// when the server says it does not know the hash yet.
    case automatic
}

/// Runs GraphQL operations through a ``NovaNetworkClient/NetworkClient``.
///
/// Everything the client already does — coalescing, retries, hedging, authentication refresh,
/// diagnostics — applies to GraphQL requests too, because they are ordinary requests to it.
///
/// ```swift
/// let graphQL = GraphQLClient(endpoint: URL(string: "https://api.example.com/graphql")!, client: client)
///
/// let data = try await graphQL.data(for: CountryQuery(variables: .init(code: "NO")))
///
/// // Or keep the data and the errors together, for a screen that can show part of itself:
/// let response = try await graphQL.response(for: CountryQuery(variables: .init(code: "NO")))
/// ```
public actor GraphQLClient {
    /// Where operations are sent.
    public let endpoint: URL
    /// The client that sends them.
    public let client: NetworkClient
    /// Whether queries are sent as `GET`, so the HTTP cache or a CDN can answer them.
    public let usesGETForQueries: Bool
    /// Headers added to every request.
    public let headers: [String: String]

    private var persistedQueries: GraphQLPersistedQueries
    private let onEvent: (@Sendable (GraphQLEvent) -> Void)?

    /// Creates a GraphQL client.
    ///
    /// - Parameters:
    ///   - endpoint: The GraphQL endpoint.
    ///   - client: The client to send requests through.
    ///   - persistedQueries: Whether to send hashes instead of documents. Defaults to `.disabled`.
    ///   - usesGETForQueries: Sends queries as `GET`. Without persisted queries the whole document
    ///     goes in the URL, which some servers and proxies limit in length. Mutations are always
    ///     `POST`.
    ///   - headers: Headers added to every request.
    ///   - onEvent: Receives persisted-query and partial-response events.
    public init(
        endpoint: URL,
        client: NetworkClient,
        persistedQueries: GraphQLPersistedQueries = .disabled,
        usesGETForQueries: Bool = false,
        headers: [String: String] = [:],
        onEvent: (@Sendable (GraphQLEvent) -> Void)? = nil
    ) {
        self.endpoint = endpoint
        self.client = client
        self.persistedQueries = persistedQueries
        self.usesGETForQueries = usesGETForQueries
        self.headers = headers
        self.onEvent = onEvent
    }

    /// Whether this client is currently sending hashes instead of documents.
    ///
    /// Starts as configured, and turns off for good when the server says it does not support
    /// persisted queries.
    public var sendsPersistedQueries: Bool {
        persistedQueries == .automatic
    }

    /// Runs an operation and returns its data, throwing when the server reported any error.
    ///
    /// - Throws: ``GraphQLResponseError`` with the errors and any partial data; or the request's
    ///   `NetworkError`.
    public func data<Operation: GraphQLOperation>(
        for operation: Operation,
        authScope: String? = nil
    ) async throws -> Operation.Data {
        let response = try await response(for: operation, authScope: authScope)
        guard let data = response.data, response.errors.isEmpty else {
            throw GraphQLResponseError(errors: response.errors, partialData: response.data)
        }
        return data
    }

    /// Runs an operation and returns the data and the errors together.
    ///
    /// GraphQL resolves fields independently: one failed field leaves the rest of `data` intact. This
    /// returns both, so a screen can render what it has beside what failed.
    ///
    /// A non-2xx response whose body is a GraphQL response is returned like any other; any other
    /// non-2xx is thrown as the client's `NetworkError`.
    public func response<Operation: GraphQLOperation>(
        for operation: Operation,
        authScope: String? = nil
    ) async throws -> GraphQLResponse<Operation.Data> {
        let response: GraphQLResponse<Operation.Data>

        if persistedQueries == .automatic {
            let hash = SHA256Util.hex(Operation.document)
            let first = try await send(operation, sendingDocument: false, hash: hash, authScope: authScope)
            switch Self.persistedQueryProblem(in: first.errors) {
            case .none:
                response = first
            case .notFound:
                onEvent?(.persistedQueryRegistered(operationName: Operation.operationName))
                response = try await send(operation, sendingDocument: true, hash: hash, authScope: authScope)
            case .notSupported:
                persistedQueries = .disabled
                onEvent?(.persistedQueriesUnsupported)
                response = try await send(operation, sendingDocument: true, hash: nil, authScope: authScope)
            }
        } else {
            response = try await send(operation, sendingDocument: true, hash: nil, authScope: authScope)
        }

        if response.hasErrors {
            onEvent?(.partialResponse(
                operationName: Operation.operationName,
                errorCount: response.errors.count,
                hasData: response.data != nil
            ))
        }
        return response
    }

    // MARK: - Sending

    private func send<Operation: GraphQLOperation>(
        _ operation: Operation,
        sendingDocument: Bool,
        hash: String?,
        authScope: String?
    ) async throws -> GraphQLResponse<Operation.Data> {
        let request = try makeRequest(for: operation, sendingDocument: sendingDocument, hash: hash)
        // Two identical mutations are two writes; merging them would drop one.
        let options = RequestExecutionOptions(coalescingMode: Operation.kind == .mutation ? .disabled : .default)

        let body: Data
        do {
            body = try await client.load(request: request, authScope: authScope, options: options)
        } catch let NetworkError.httpStatus(code, headers, errorBody) {
            // The GraphQL-over-HTTP spec answers some failures with a 4xx carrying a GraphQL body.
            if let response = try? JSONDecoder().decode(GraphQLResponse<Operation.Data>.self, from: errorBody),
               response.hasErrors || response.data != nil {
                return response
            }
            throw NetworkError.httpStatus(code: code, headers: headers, body: errorBody)
        }

        do {
            return try JSONDecoder().decode(GraphQLResponse<Operation.Data>.self, from: body)
        } catch {
            throw NetworkError.decoding(underlying: error)
        }
    }

    func makeRequest<Operation: GraphQLOperation>(
        for operation: Operation,
        sendingDocument: Bool,
        hash: String?
    ) throws -> APIRequest {
        let variables: Operation.Variables? = operation.variables is GraphQLNoVariables ? nil : operation.variables
        let extensions = hash.map { RequestExtensions(persistedQuery: .init(sha256Hash: $0)) }
        let document = sendingDocument ? Operation.document : nil

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var headers = headers
        headers["Accept"] = "application/graphql-response+json, application/json"

        if Operation.kind == .query, usesGETForQueries {
            var items: [URLQueryItem] = []
            if let document { items.append(URLQueryItem(name: "query", value: document)) }
            if let name = Operation.operationName { items.append(URLQueryItem(name: "operationName", value: name)) }
            if let variables { items.append(URLQueryItem(name: "variables", value: try Self.json(variables, encoder))) }
            if let extensions { items.append(URLQueryItem(name: "extensions", value: try Self.json(extensions, encoder))) }
            return APIRequest(method: .get, url: endpoint, queryItems: items, headers: headers)
        }

        headers["Content-Type"] = "application/json"
        let body = RequestBody(
            query: document,
            operationName: Operation.operationName,
            variables: variables,
            extensions: extensions
        )
        return APIRequest(method: .post, url: endpoint, headers: headers, body: try encoder.encode(body))
    }

    private static func json(_ value: some Encodable, _ encoder: JSONEncoder) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    // MARK: - Persisted queries

    private enum PersistedQueryProblem {
        case notFound
        case notSupported
    }

    private static func persistedQueryProblem(in errors: [GraphQLError]) -> PersistedQueryProblem? {
        for error in errors {
            let code = error.code ?? ""
            if code == "PERSISTED_QUERY_NOT_FOUND" || error.message == "PersistedQueryNotFound" {
                return .notFound
            }
            if code == "PERSISTED_QUERY_NOT_SUPPORTED" || error.message == "PersistedQueryNotSupported" {
                return .notSupported
            }
        }
        return nil
    }
}

private struct RequestBody<Variables: Encodable>: Encodable {
    let query: String?
    let operationName: String?
    let variables: Variables?
    let extensions: RequestExtensions?
}

private struct RequestExtensions: Encodable {
    struct PersistedQuery: Encodable {
        var version = 1
        let sha256Hash: String
    }

    let persistedQuery: PersistedQuery
}
