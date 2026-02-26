import Foundation

public protocol NetworkTransport: Sendable {
    func execute(_ request: APIRequest) async throws -> NetworkResponse
}

public struct Transport: NetworkTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        let urlRequest = request.urlRequest()

        do {
            let (data, response) = try await session.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw NetworkError.httpStatus(code: httpResponse.statusCode, body: data)
            }

            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { partial, item in
                guard let key = item.key as? String else { return }
                partial[key] = String(describing: item.value)
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
