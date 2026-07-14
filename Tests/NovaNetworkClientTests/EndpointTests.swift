import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-END-1...3, EC-3.

private struct EndpointUser: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

private struct UserEndpoint: Endpoint {
    typealias Response = EndpointUser

    let url: URL

    func makeRequest() throws -> APIRequest {
        APIRequest(method: .get, url: url)
    }
}

private enum EndpointDecodeFailure: Error {
    case rejected
}

private actor EndpointTransport: NetworkTransport {
    private let response: NetworkResponse
    private var callCount = 0

    init(response: NetworkResponse) {
        self.response = response
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        callCount += 1
        return response
    }

    func calls() -> Int {
        callCount
    }
}

@Suite
struct EndpointTests {
    @Test
    func typedEndpointExecutesThroughNetworkClient() async throws {
        let expected = EndpointUser(id: 7, name: "Nova")
        let body = try JSONEncoder().encode(expected)
        let transport = EndpointTransport(response: .init(statusCode: 200, headers: [:], body: body))
        let client = NetworkClient(transport: transport)
        let endpoint = UserEndpoint(url: URL(string: "https://example.com/users/7")!)

        let actual = try await client.execute(endpoint: endpoint, authScope: "user:7")

        #expect(actual == expected)
        #expect(await transport.calls() == 1)
    }

    @Test
    func anyEndpointSupportsCustomDecoding() async throws {
        let transport = EndpointTransport(
            response: .init(statusCode: 200, headers: [:], body: Data("value=42".utf8))
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/value")!)
        let endpoint = AnyEndpoint<Int>(
            request: { request },
            decode: { data, _ in
                Int(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "value=", with: "")) ?? -1
            }
        )

        let value = try await client.execute(endpoint: endpoint, authScope: nil)

        #expect(value == 42)
    }

    @Test
    func endpointDecodeFailureMapsToNetworkError() async {
        let transport = EndpointTransport(
            response: .init(statusCode: 200, headers: [:], body: Data("bad".utf8))
        )
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/bad")!)
        let endpoint = AnyEndpoint<Int>(request: { request }, decode: { _, _ in throw EndpointDecodeFailure.rejected })

        do {
            _ = try await client.execute(endpoint: endpoint, authScope: nil)
            Issue.record("Expected endpoint decoding to fail")
        } catch let error as NetworkError {
            #expect(error.failureReason == .decoding)
        } catch {
            Issue.record("Expected NetworkError.decoding, received \(error)")
        }
    }
}
