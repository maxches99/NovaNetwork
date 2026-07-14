import NovaNetworkCore
import Foundation

/// The default URLSession-backed HTTP, streaming, upload, and download transport.
public struct Transport: NetworkTransport, StreamingNetworkTransport, TransferNetworkTransport {
    let session: URLSession

    /// Creates a transport backed by the supplied URL session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Executes a complete HTTP request, accepting successful and 304 responses.
    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        let urlRequest = request.urlRequest()

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { partial, item in
                guard let key = item.key as? String else { return }
                partial[key] = String(describing: item.value)
            }

            guard (200..<300).contains(httpResponse.statusCode) || httpResponse.statusCode == 304 else {
                throw NetworkError.httpStatus(code: httpResponse.statusCode, headers: headers, body: data)
            }

            return NetworkResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: data
            )
        } catch is CancellationError {
            throw NetworkError.cancelled
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.transport(underlying: error)
        }
    }
}
