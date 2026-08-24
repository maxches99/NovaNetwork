import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-ERR-4 (client-level error context wrapping).

@Suite
struct NetworkClientErrorContextTests {
    @Test
    func loadWithContextWrapsThrownNetworkErrorWithRequestContext() async throws {
        let client = NetworkClient(transport: GenericThrowingTransport(error: NetworkError.invalidResponse))
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/items")!)

        do {
            _ = try await client.loadWithContext(request: request, authScope: "user:9")
            Issue.record("expected loadWithContext to throw")
        } catch let error as ContextualNetworkError {
            #expect(error.error == .invalidResponse)
            #expect(error.context.url == request.url)
            #expect(error.context.method == .post)
            #expect(error.context.authScope == "user:9")
        }
    }

    @Test
    func loadWithContextSucceedsIdenticallyToLoadOnTheHappyPath() async throws {
        let transport = RequestRecordingTransport()
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/items")!)

        let data = try await client.loadWithContext(request: request, authScope: nil)
        #expect(data == Data("ok".utf8))
    }
}
