import Foundation
import Testing
@testable import NovaNetworkQuery

// Requirements: FR-11/UR-1 (four states a screen can switch over), FR-12 (observable model).
// Tests: T-9.1, and the observation surface.

@Suite
struct QueryStateTests {
    @Test
    func idleHasNothingToShow() {
        let state = QueryState<String>.idle

        #expect(state.value == nil)
        #expect(state.error == nil)
        #expect(!state.isLoading)
        #expect(!state.isStale)
        #expect(!state.hasValue)
    }

    @Test
    func loadingKeepsThePreviousValueSoARefreshDoesNotBlankTheScreen() {
        let firstLoad = QueryState<String>.loading(previous: nil)
        let refresh = QueryState<String>.loading(previous: "ada")

        #expect(firstLoad.value == nil)
        #expect(firstLoad.isLoading)
        #expect(refresh.value == "ada")
        #expect(refresh.isLoading)
        #expect(refresh.hasValue)
    }

    @Test
    func successCarriesWhetherTheValueIsKnownToBeOutOfDate() {
        #expect(QueryState.success("ada", isStale: false).isStale == false)
        #expect(QueryState.success("ada", isStale: true).isStale)
        #expect(QueryState.success("ada", isStale: true).value == "ada")
        #expect(QueryState.success("ada", isStale: true).error == nil)
    }

    @Test
    func failureCarriesBothTheProblemAndWhatWasAlreadyOnScreen() {
        let state = QueryState<String>.failure(FetchFailure(), previous: "ada")

        #expect(state.error is FetchFailure)
        #expect(state.value == "ada")
        #expect(state.hasValue)
        #expect(!state.isLoading)
        #expect(!state.isStale)
    }
}

#if canImport(Observation)
@Suite
struct ObservableQueryTests {
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    @Test
    func theModelTracksTheQueryItWasGiven() async throws {
        let queries = QueryClient(now: TestClock().now)
        let model = await ObservableQuery<String>(key: "users", client: queries)

        let running = Task { await model.start() }
        try await waitUntil("the model subscribed") { await queries.subscriberCount(for: "users") == 1 }

        await queries.setValue("ada", for: "users")
        try await waitUntil("the model saw the value") { await model.value == "ada" }

        #expect(await model.state.value == "ada")
        #expect(await model.isLoading == false)
        #expect(await model.error == nil)

        await model.stop()
        running.cancel()
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    @Test
    func theModelStartsIdleBeforeAnythingIsAsked() async {
        let model = await ObservableQuery<String>(key: "users", client: QueryClient(now: TestClock().now))

        #expect(await model.value == nil)
        #expect(await model.error == nil)
        #expect(await model.isLoading == false)
    }
}
#endif
