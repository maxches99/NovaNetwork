import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-DEC-3 (loadResponse), FR-DEC-4 (client decode(request:...:responseDecoding:)).

private struct DecodingTestPayload: Decodable, Equatable, Sendable {
    let value: Int
}

private actor FixedResponseTransport: NetworkTransport {
    private let response: NetworkResponse

    init(response: NetworkResponse) {
        self.response = response
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        response
    }
}

private struct XMLDecoding: ResponseDecoding {
    func decode<T: Decodable & Sendable>(_ type: T.Type, from response: NetworkResponse) throws -> T {
        guard let string = String(data: response.body, encoding: .utf8),
              let match = string.range(of: #"<value>(\d+)</value>"#, options: .regularExpression) else {
            throw NetworkError.decoding(underlying: NSError(domain: "XMLDecoding", code: 1))
        }
        let digits = string[match].filter(\.isNumber)
        guard let value = Int(digits), let payload = DecodingTestPayload(value: value) as? T else {
            throw NetworkError.decoding(underlying: NSError(domain: "XMLDecoding", code: 2))
        }
        return payload
    }
}

@Suite
struct NetworkClientResponseDecodingTests {
    @Test
    func loadResponseReturnsHeadersAndStatusAlongsideTheBody() async throws {
        let expected = NetworkResponse(
            statusCode: 201,
            headers: ["Content-Type": "application/json", "X-Custom": "1"],
            body: Data(#"{"value":1}"#.utf8)
        )
        let client = NetworkClient(transport: FixedResponseTransport(response: expected))

        let response = try await client.loadResponse(
            request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
            authScope: nil
        )

        #expect(response.statusCode == 201)
        #expect(response.headers["X-Custom"] == "1")
        #expect(response.body == expected.body)
    }

    @Test
    func decodeUsesJSONResponseDecodingByDefault() async throws {
        let response = NetworkResponse(statusCode: 200, headers: [:], body: Data(#"{"value":5}"#.utf8))
        let client = NetworkClient(transport: FixedResponseTransport(response: response))

        let decoded: DecodingTestPayload = try await client.decode(
            request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
            authScope: nil
        )

        #expect(decoded == DecodingTestPayload(value: 5))
    }

    @Test
    func decodeUsesAPerCallResponseDecodingStrategyOverTheClientDefault() async throws {
        let response = NetworkResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/xml"],
            body: Data("<value>8</value>".utf8)
        )
        let client = NetworkClient(transport: FixedResponseTransport(response: response))

        let decoded: DecodingTestPayload = try await client.decode(
            request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
            authScope: nil,
            responseDecoding: XMLDecoding()
        )

        #expect(decoded == DecodingTestPayload(value: 8))
    }

    @Test
    func decodeUsesTheClientsConfiguredResponseDecodingWhenNoPerCallStrategyIsSupplied() async throws {
        let response = NetworkResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/xml"],
            body: Data("<value>13</value>".utf8)
        )
        var configuration = NetworkClientConfiguration()
        configuration.transport = FixedResponseTransport(response: response)
        configuration.responseDecoding = ContentTypeNegotiatingResponseDecoding(
            decodersByMediaType: ["application/xml": XMLDecoding()]
        )
        let client = NetworkClient(configuration: configuration)

        let decoded: DecodingTestPayload = try await client.decode(
            request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
            authScope: nil
        )

        #expect(decoded == DecodingTestPayload(value: 13))
    }

    @Test
    func decodeWrapsUnderlyingDecodingFailuresAsNetworkErrorDecoding() async throws {
        let response = NetworkResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))
        let client = NetworkClient(transport: FixedResponseTransport(response: response))

        do {
            let _: DecodingTestPayload = try await client.decode(
                request: APIRequest(method: .get, url: URL(string: "https://example.com")!),
                authScope: nil
            )
            Issue.record("expected decoding to throw")
        } catch let error as NetworkError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
    }
}
