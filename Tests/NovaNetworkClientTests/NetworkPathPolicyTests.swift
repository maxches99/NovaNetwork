import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import NovaNetworkClient
import NovaNetworkCore

// Requirements: FR-27 (decide from the path, not just from connected/not), FR-28 (essential
// requests are not blocked by a metered path), FR-29 (deferral reaches the offline queue, failure
// does not), FR-30 (no policy means no change), EC-23…EC-26.
// Tests: T-13.1…T-13.12.

private let wifi = NetworkPath(status: .satisfied, interfaces: [.wifi])
private let cellular = NetworkPath(status: .satisfied, interfaces: [.cellular], isExpensive: true)
private let lowDataMode = NetworkPath(status: .satisfied, interfaces: [.wifi], isConstrained: true)
private let offline = NetworkPath(status: .unsatisfied)

@Suite
struct NetworkPathPolicyDecisionTests {
    @Test
    func theDefaultPolicySendsOnAnyUsablePathAndDefersWhenThereIsNone() {
        let policy = NetworkPathPolicy()

        #expect(policy.decision(for: wifi) == .send)
        #expect(policy.decision(for: cellular) == .send)
        #expect(policy.decision(for: lowDataMode) == .send)
        #expect(policy.decision(for: offline) == .deferUntilPathImproves)
    }

    @Test
    func aMeteredPathIsHeldBackWhenTheCallerAsksForThat() {
        let policy = NetworkPathPolicy.respectMeteredPaths

        #expect(policy.decision(for: wifi) == .send)
        #expect(policy.decision(for: cellular) == .deferUntilPathImproves)
        #expect(policy.decision(for: lowDataMode) == .deferUntilPathImproves)
    }

    @Test
    func anEssentialRequestGoesOutOnAPathThatWouldOtherwiseBeRuledOut() {
        // A policy that also blocked the sign-in would be a policy nobody could adopt.
        let policy = NetworkPathPolicy(onExpensive: .fail, onConstrained: .fail)

        #expect(policy.decision(for: cellular, isEssential: true) == .send)
        #expect(policy.decision(for: lowDataMode, isEssential: true) == .send)
    }

    @Test
    func evenAnEssentialRequestCannotGoWhenThereIsNoPath() {
        let policy = NetworkPathPolicy(onUnsatisfied: .deferUntilPathImproves)

        // Being essential does not conjure a network; the policy still decides what happens next.
        #expect(policy.decision(for: offline, isEssential: true) == .deferUntilPathImproves)
        #expect(NetworkPathPolicy(onUnsatisfied: .fail).decision(for: offline, isEssential: true) == .fail)
    }

    @Test
    func theUsersRequestForLessDataOutranksAnInferenceAboutCost() {
        // Constrained is Low Data Mode: an explicit instruction. Expensive is a guess about the
        // link. When they disagree, the instruction wins.
        let policy = NetworkPathPolicy(onExpensive: .send, onConstrained: .fail)
        let expensiveAndConstrained = NetworkPath(
            status: .satisfied,
            interfaces: [.cellular],
            isExpensive: true,
            isConstrained: true
        )

        #expect(policy.decision(for: expensiveAndConstrained) == .fail)
    }

    @Test
    func aPathThatNeedsBringingUpIsNotUsableYet() {
        let requiresConnection = NetworkPath(status: .requiresConnection, interfaces: [.other])

        #expect(requiresConnection.isUsable == false)
        #expect(NetworkPathPolicy().decision(for: requiresConnection) == .deferUntilPathImproves)
    }

    @Test
    func alwaysSendIsTheBehaviourOfHavingNoPolicyAtAll() {
        for path in [wifi, cellular, lowDataMode, offline] {
            #expect(NetworkPathPolicy.alwaysSend.decision(for: path) == .send)
        }
    }
}

@Suite
struct StaticNetworkPathMonitorTests {
    @Test
    func itReportsItsPathOnceAndThenFinishes() async {
        let monitor = StaticNetworkPathMonitor(cellular)

        #expect(await monitor.currentPath() == cellular)

        var seen: [NetworkPath] = []
        for await path in monitor.pathStream() { seen.append(path) }
        // A path that never changes has nothing more to say; a stream that never finished would
        // keep its consumer waiting forever.
        #expect(seen == [cellular])
    }
}

// MARK: - Through the client

private struct PathCountingTransport: NetworkTransport {
    let calls: Counter

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        await calls.increment()
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// The smallest store that can answer "was it queued": enough for a test about routing, and not a
/// second implementation of the queue.
private actor RecordingOfflineWriteStore: OfflineWriteStore {
    private var entries: [OfflineWriteStoreEntry] = []

    func enqueue(request: APIRequest, requestKey: String, now: Date) async throws -> QueuedWriteReceipt {
        let receipt = QueuedWriteReceipt(
            queueID: UUID().uuidString,
            requestKey: requestKey,
            position: entries.count + 1,
            enqueuedAt: now
        )
        entries.append(
            OfflineWriteStoreEntry(
                receipt: receipt,
                request: request,
                attempt: 0,
                nextRetryAt: nil,
                lastFailureReason: nil,
                state: .queued,
                updatedAt: now,
                replayMetadata: .init(replayIdentity: requestKey)
            )
        )
        return receipt
    }

    func nextBatch(limit: Int, now: Date) async -> [OfflineWriteStoreEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    func markReplaying(queueID: String, attempt: Int, now: Date) async {}
    func markRetryWaiting(queueID: String, attempt: Int, reason: String, nextRetryAt: Date, now: Date) async {}
    func markSucceeded(queueID: String) async {}
    func markDeadLetter(queueID: String, reason: String, now: Date) async {}
    func depth(now: Date) async -> Int { entries.count }
    func snapshot(now: Date) async -> [OfflineWriteStoreEntry] { entries }
    func drop(queueID: String) async -> Bool { false }
    func dropAll() async -> Int { 0 }
}

@Suite
struct NetworkPathClientTests {
    private func client(
        policy: NetworkPathPolicy?,
        path: NetworkPath,
        calls: Counter,
        offlineStore: (any OfflineWriteStore)? = nil
    ) -> NetworkClient {
        var configuration = NetworkClientConfiguration()
        configuration.transport = PathCountingTransport(calls: calls)
        configuration.networkPathPolicy = policy
        configuration.networkPathMonitor = StaticNetworkPathMonitor(path)
        configuration.offlineWriteStore = offlineStore
        return NetworkClient(configuration: configuration)
    }

    private var request: APIRequest {
        APIRequest(method: .get, url: URL(string: "https://api.example.com/feed")!)
    }

    @Test
    func aRuledOutPathStopsTheRequestBeforeItReachesTheTransport() async {
        let calls = Counter()
        let subject = client(policy: .respectMeteredPaths, path: cellular, calls: calls)

        do {
            _ = try await subject.load(request: request, authScope: nil)
            Issue.record("the request should not have been sent")
        } catch {
            // expected
        }

        #expect(await calls.value == 0)
    }

    @Test
    func anAllowedPathSendsNormally() async throws {
        let calls = Counter()
        let subject = client(policy: .respectMeteredPaths, path: wifi, calls: calls)

        _ = try await subject.load(request: request, authScope: nil)

        #expect(await calls.value == 1)
    }

    @Test
    func anEssentialRequestGoesOutOverAMeteredPath() async throws {
        let calls = Counter()
        let subject = client(policy: .respectMeteredPaths, path: cellular, calls: calls)

        _ = try await subject.load(
            request: request,
            authScope: nil,
            options: RequestExecutionOptions(isEssential: true)
        )

        #expect(await calls.value == 1)
    }

    @Test
    func withNoPolicyTheClientDoesNotLookAtThePathAtAll() async throws {
        let calls = Counter()
        // A path that any policy would rule out, and no policy to rule on it.
        let subject = client(policy: nil, path: offline, calls: calls)

        _ = try await subject.load(request: request, authScope: nil)

        #expect(await calls.value == 1)
        #expect(await subject.currentNetworkPath() == offline)
    }

    @Test
    func aFailDecisionCarriesAReasonAPersonCanRead() async {
        let calls = Counter()
        let subject = client(
            policy: NetworkPathPolicy(onExpensive: .fail),
            path: cellular,
            calls: calls
        )

        do {
            _ = try await subject.load(request: request, authScope: nil)
            Issue.record("the request should have failed")
        } catch let error as NetworkError {
            guard case let .transport(underlying) = error,
                  let restriction = underlying as? NetworkPathRestrictionError
            else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(restriction.decision == .fail)
            #expect(restriction.path == cellular)
            #expect(restriction.description.contains("expensive"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test
    func aDeferredWriteGoesToTheOfflineQueueAndAFailedOneDoesNot() async throws {
        // Deferral is reported as an error the queue already recognises, so it reaches the queue
        // through the machinery that was already there rather than a second path beside it.
        let write = APIRequest(method: .post, url: URL(string: "https://api.example.com/orders")!)
        let queueOptions = RequestExecutionOptions(offlineQueuePolicy: .init(mode: .enqueueWhenOffline))

        let deferring = client(
            policy: .respectMeteredPaths,
            path: cellular,
            calls: Counter(),
            offlineStore: RecordingOfflineWriteStore()
        )
        let deferred = try await deferring.enqueueWrite(request: write, authScope: nil, options: queueOptions)
        guard case .queued = deferred else {
            Issue.record("a deferred write should have been queued, got \(deferred)")
            return
        }
        #expect(await deferring.offlineQueueDepth() == 1)

        let failing = client(
            policy: NetworkPathPolicy(onExpensive: .fail),
            path: cellular,
            calls: Counter(),
            offlineStore: RecordingOfflineWriteStore()
        )
        do {
            _ = try await failing.enqueueWrite(request: write, authScope: nil, options: queueOptions)
            Issue.record("a failed write should not have been queued")
        } catch {
            // expected
        }
        #expect(await failing.offlineQueueDepth() == 0)
    }
}
