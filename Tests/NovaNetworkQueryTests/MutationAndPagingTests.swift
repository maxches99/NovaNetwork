import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkQuery

// Requirements: FR-8 (optimistic mutations and rollback), FR-9 (paged queries), AR-1 (unchanged
// client behavior). Tests: T-6.1, T-6.2, T-6.3, T-7.1, T-10.1.

@Suite
struct MutationTests {
    @Test
    func anOptimisticValueIsVisibleBeforeTheWorkFinishes() async throws {
        let queries = QueryClient(now: TestClock().now)
        await queries.setValue(["ada"], for: "users")

        let observed = Task { () -> [String]? in
            for await state in await queries.states(for: "users", as: [String].self)
            where state.value?.count == 2 {
                return state.value
            }
            return nil
        }
        try await waitUntil("subscribed") { await queries.subscriberCount(for: "users") == 1 }

        try await queries.mutate(optimistic: ["users": ["ada", "grace"]]) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await observed.value == ["ada", "grace"])
    }

    @Test
    func aFailedMutationRestoresExactlyWhatWasThere() async throws {
        let queries = QueryClient(now: TestClock().now)
        await queries.setValue(["ada"], for: "users")

        await #expect(throws: FetchFailure.self) {
            try await queries.mutate(optimistic: ["users": ["ada", "grace"]]) {
                throw FetchFailure()
            }
        }

        #expect(try await queries.cachedValue(for: "users", as: [String].self) == ["ada"])
    }

    @Test
    func rollbackRemovesAValueThatWasNeverThere() async throws {
        let queries = QueryClient(now: TestClock().now)

        await #expect(throws: FetchFailure.self) {
            try await queries.mutate(optimistic: ["users": ["grace"]]) {
                throw FetchFailure()
            }
        }

        #expect(try await queries.cachedValue(for: "users", as: [String].self) == nil)
    }

    @Test
    func racingMutationsEachRollBackToWhatTheyCaptured() async throws {
        // Restoring a captured snapshot rather than reversing a diff is the only approach that stays
        // correct here: the second mutation captured what the first had already written.
        let queries = QueryClient(now: TestClock().now)
        await queries.setValue(["ada"], for: "users")

        try await queries.mutate(optimistic: ["users": ["ada", "grace"]]) {}
        #expect(try await queries.cachedValue(for: "users", as: [String].self) == ["ada", "grace"])

        await #expect(throws: FetchFailure.self) {
            try await queries.mutate(optimistic: ["users": ["ada", "grace", "alan"]]) {
                throw FetchFailure()
            }
        }

        #expect(try await queries.cachedValue(for: "users", as: [String].self) == ["ada", "grace"])
    }

    @Test
    func aSuccessfulMutationInvalidatesWhatItAffected() async throws {
        let queries = QueryClient(now: TestClock().now)
        _ = try await queries.value(for: QueryKey("users", 1)) { "ada" }

        try await queries.mutate(invalidating: [QueryKey("users", 1)]) {}

        #expect(await queries.isStaleForTesting(QueryKey("users", 1)))
    }

    @Test
    func aMutationReturnsWhateverItsWorkProduced() async throws {
        let queries = QueryClient(now: TestClock().now)

        let created: String = try await queries.mutate { "created-id" }

        #expect(created == "created-id")
    }
}

@Suite
struct PagedQueryTests {
    private func numbersPage(after cursor: Int?) -> QueryPage<Int, Int> {
        let start = (cursor ?? 0) + 1
        guard start <= 6 else { return QueryPage(elements: [], nextCursor: nil) }
        let elements = Array(start..<(start + 3))
        let next = elements.last!
        return QueryPage(elements: elements, nextCursor: next >= 6 ? nil : next)
    }

    @Test
    func pagesAccumulateInOrder() async throws {
        let queries = QueryClient(now: TestClock().now)
        let paged = PagedQuery<Int, Int>(key: "numbers", client: queries) { [self] cursor in
            numbersPage(after: cursor)
        }

        #expect(await paged.hasNextPage, "nobody has said there is no next page yet")
        let first = try await paged.loadNextPage()
        #expect(first == [1, 2, 3])

        let second = try await paged.loadNextPage()
        #expect(second == [1, 2, 3, 4, 5, 6], "a list renders everything loaded, not just the new page")
        #expect(await paged.hasNextPage == false)
    }

    @Test
    func accumulatedPagesLandInTheCacheSoAScreenCanSubscribe() async throws {
        let queries = QueryClient(now: TestClock().now)
        let paged = PagedQuery<Int, Int>(key: "numbers", client: queries) { [self] cursor in
            numbersPage(after: cursor)
        }

        _ = try await paged.loadNextPage()

        #expect(try await queries.cachedValue(for: "numbers", as: [Int].self) == [1, 2, 3])
    }

    @Test
    func loadingPastTheEndIsANoOpRatherThanAnError() async throws {
        // A scroll handler firing once more at the bottom of a list is normal.
        let queries = QueryClient(now: TestClock().now)
        let paged = PagedQuery<Int, Int>(key: "numbers", client: queries) { _ in
            QueryPage(elements: [1], nextCursor: nil)
        }

        _ = try await paged.loadNextPage()
        let again = try await paged.loadNextPage()

        #expect(again == [1])
        #expect(await paged.hasNextPage == false)
    }

    @Test
    func reloadingStartsOverFromTheFirstPage() async throws {
        let queries = QueryClient(now: TestClock().now)
        let paged = PagedQuery<Int, Int>(key: "numbers", client: queries) { [self] cursor in
            numbersPage(after: cursor)
        }
        _ = try await paged.loadNextPage()
        _ = try await paged.loadNextPage()

        let reloaded = try await paged.reload()

        #expect(reloaded == [1, 2, 3])
        #expect(await paged.hasNextPage)
    }

    @Test
    func resettingForgetsEverythingWithoutFetching() async throws {
        let queries = QueryClient(now: TestClock().now)
        let paged = PagedQuery<Int, Int>(key: "numbers", client: queries) { [self] cursor in
            numbersPage(after: cursor)
        }
        _ = try await paged.loadNextPage()

        await paged.reset()

        #expect(await paged.elements.isEmpty)
        #expect(try await queries.cachedValue(for: "numbers", as: [Int].self) == nil)
    }
}

// MARK: - T-10.1 over the real client

@Suite
struct QueryOverNetworkClientTests {
    private struct User: Codable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    private actor CountingTransport: NetworkTransport {
        private(set) var calls = 0

        func execute(_ request: APIRequest) async throws -> NetworkResponse {
            calls += 1
            return NetworkResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"id":1,"name":"Ada"}"#.utf8)
            )
        }

        func count() -> Int { calls }
    }

    @Test
    func aQueryWrappingTheClientBehavesLikeTheClient() async throws {
        let transport = CountingTransport()
        let client = NetworkClient(transport: transport)
        let queries = QueryClient(configuration: QueryConfiguration(staleTime: 60), now: TestClock().now)
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)

        let first: User = try await queries.value(for: QueryKey("users", 1)) {
            try await client.load(request: request, authScope: nil)
        }
        let second: User = try await queries.value(for: QueryKey("users", 1)) {
            try await client.load(request: request, authScope: nil)
        }

        #expect(first == User(id: 1, name: "Ada"))
        #expect(second == first)
        #expect(await transport.count() == 1, "the second read came from the query cache")
    }

    @Test
    func aQueryCanWrapAnythingNotJustHTTP() async throws {
        let queries = QueryClient(now: TestClock().now)

        let computed: Int = try await queries.value(for: "expensive") {
            (1...10).reduce(0, +)
        }

        #expect(computed == 55)
    }
}
