import Foundation
import Testing
@testable import NovaNetworkClient

extension NetworkingCoverageTests {
    @Test
    func cookbookScenarioCoalescedRequestUsesSingleTransportCall() async throws {
        let transport = StubNetworkTransport(delayNanos: 120_000_000, response: .success(Data("ok".utf8)))
        let client = NetworkClient(transport: transport)
        let request = APIRequest(method: .get, url: URL(string: "https://example.com/cookbook/coalesced")!)

        async let first = client.load(request: request, authScope: "cookbook")
        async let second = client.load(request: request, authScope: "cookbook")
        let _ = try await (first, second)

        #expect(await transport.calls() == 1)
    }

    @Test
    func cookbookScenarioProductionProfileForOfflineFirstRequiresStore() {
        let profile = NetworkClientProductionProfileGenerator().generate(
            goal: .offlineFirst,
            offlineStoreConfigured: false
        )

        #expect(profile.validation.isProductionReady == false)
        #expect(profile.validation.blockingIssues.contains { $0.code == "AP-OFFLINE-001" })
    }
}
