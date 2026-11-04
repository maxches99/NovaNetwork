import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkGraphQL

// Requirements: FR-GQL-2, FR-GQL-3 against a real server (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §E).
// Tests: T-22.8. Runs only with RUN_E2E_TESTS=1, against a public API, with the real transport.

private struct CountryQuery: GraphQLOperation {
    static let document = "query Country($code: ID!) { country(code: $code) { name capital currency } }"
    static let operationName: String? = "Country"

    struct Variables: Encodable, Sendable { let code: String }
    struct Data: Decodable, Sendable {
        struct Country: Decodable, Sendable {
            let name: String
            let capital: String?
            let currency: String?
        }
        let country: Country?
    }

    let variables: Variables
}

private struct BrokenQuery: GraphQLOperation {
    static let document = "{ noSuchField }"
    struct Data: Decodable, Sendable {}
}

@Suite
struct GraphQLE2ECoverageTests {
    private var enabled: Bool {
        ProcessInfo.processInfo.environment["RUN_E2E_TESTS"] == "1"
    }

    private let graphQL = GraphQLClient(
        endpoint: URL(string: "https://countries.trevorblades.com/graphql")!,
        client: NetworkClient(transport: Transport())
    )

    @Test // T-22.8
    func e2eATypedQueryDecodesFromARealGraphQLServer() async throws {
        guard enabled else { return }

        let data = try await graphQL.data(for: CountryQuery(variables: .init(code: "NO")))

        #expect(data.country?.name == "Norway")
        #expect(data.country?.capital == "Oslo")
    }

    @Test // T-22.8
    func e2eAValidationErrorFromARealServerIsAGraphQLError() async throws {
        guard enabled else { return }

        let response = try await graphQL.response(for: BrokenQuery())

        #expect(response.data == nil)
        #expect(!response.errors.isEmpty)
    }
}
