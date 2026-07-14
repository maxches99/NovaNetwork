import Foundation
import Testing
import NovaNetworkCore

// Requirements: FR-MOD-1...2.

private struct CorePayload: Codable, Equatable, Sendable {
    let value: Int
}

@Suite
struct NovaNetworkCoreTests {
    @Test
    func coreRequestAndEndpointWorkWithoutUmbrellaModule() throws {
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://example.com/core")!,
            queryItems: [URLQueryItem(name: "page", value: "1")]
        )
        let endpoint = AnyEndpoint<CorePayload>(request: request)
        let data = try JSONEncoder().encode(CorePayload(value: 42))

        #expect(try endpoint.makeRequest().urlRequest().url?.absoluteString == "https://example.com/core?page=1")
        #expect(try endpoint.decode(data, using: JSONDecoder()) == CorePayload(value: 42))
    }

    @Test
    func coreTransportProtocolAcceptsSendableImplementations() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable((any NetworkTransport).self)
    }
}
