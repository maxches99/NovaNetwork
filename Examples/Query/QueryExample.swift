import Foundation
import NovaNetworkClient
import NovaNetworkQuery

/// Shows the four things a screen needs from a query layer: one fetch for two screens, a stale value
/// that stays visible while it refreshes, an optimistic edit that rolls back when the server says no,
/// and a list that pages.
@main
struct QueryExample {
    struct User: Codable, Equatable, Sendable {
        let id: Int
        let name: String
    }

    /// Counts what the server was actually asked for.
    actor FakeAPI: NetworkTransport {
        private(set) var calls = 0
        private var name = "Ada"

        func execute(_ request: APIRequest) async throws -> NetworkResponse {
            calls += 1
            return NetworkResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"id":1,"name":"\#(name)"}"#.utf8)
            )
        }

        func rename(to newName: String) { name = newName }
        func count() -> Int { calls }
    }

    static func main() async {
        let api = FakeAPI()
        let client = NetworkClient(transport: api)
        let queries = QueryClient(configuration: QueryConfiguration(staleTime: 30))
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)

        let fetchUser: @Sendable () async throws -> User = {
            try await client.load(request: request, authScope: nil)
        }

        do {
            // 1. Two screens want the same user at the same moment.
            async let list: User = queries.value(for: QueryKey("users", 1), fetch: fetchUser)
            async let detail: User = queries.value(for: QueryKey("users", 1), fetch: fetchUser)
            let (fromList, fromDetail) = try await (list, detail)
            print("1. Two screens asked for the same user; the server saw \(await api.count()) request")
            print("   Both show: \(fromList.name) / \(fromDetail.name)")

            // 2. A subscriber sees every change to that key, whoever caused it.
            let states = await queries.states(for: QueryKey("users", 1), as: User.self)
            let watcher = Task {
                for await state in states {
                    let mark = state.isStale ? " (stale, refreshing)" : ""
                    print("   → screen renders: \(state.value?.name ?? "nothing")\(mark)")
                    if state.value?.name == "Grace" { break }
                }
            }

            // 3. An optimistic edit that the server rejects must not stay on screen.
            struct Rejected: Error {}
            do {
                try await queries.mutate(
                    optimistic: [QueryKey("users", 1): User(id: 1, name: "Typo")],
                    invalidating: [QueryKey("users", 1)]
                ) {
                    throw Rejected()
                }
            } catch {
                let current = try await queries.cachedValue(for: QueryKey("users", 1), as: User.self)
                print("2. Rejected edit rolled back to: \(current?.name ?? "nothing")")
            }

            // 4. A successful rename invalidates the key, and the watcher sees the new value.
            await api.rename(to: "Grace")
            try await queries.mutate(invalidating: [QueryKey("users", 1)]) {}
            _ = await watcher.value
            print("3. After the rename the server saw \(await api.count()) requests in total")

            // 5. A list that pages.
            let numbers = PagedQuery<Int, Int>(key: "numbers", client: queries) { cursor in
                let start = (cursor ?? 0) + 1
                guard start <= 9 else { return QueryPage(elements: [], nextCursor: nil) }
                let page = Array(start..<(start + 3))
                return QueryPage(elements: page, nextCursor: page.last == 9 ? nil : page.last)
            }
            while await numbers.hasNextPage {
                let all = try await numbers.loadNextPage()
                print("4. Loaded a page; the list now holds \(all.count) items, more to come: \(await numbers.hasNextPage)")
            }
        } catch {
            print("Example failed: \(error.localizedDescription)")
        }
    }
}
