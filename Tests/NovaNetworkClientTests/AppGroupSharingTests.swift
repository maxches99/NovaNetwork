import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore

// Requirements: FR-32 (a lock two processes can agree on), FR-33 (the lock is released however the
// work ends), FR-34 (a store wrapped in it behaves exactly as the store did), FR-35 (App Group
// container resolution reports a missing entitlement clearly), EC-27…EC-30.
// Tests: T-14.1…T-14.10.

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite
struct CrossProcessFileLockTests {
    @Test
    func theLockIsTakenAndGivenBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = CrossProcessFileLock(url: directory.appendingPathComponent(".lock"))

        let result = try await lock.withLock { 42 }

        #expect(result == 42)
        #expect(await lock.isAvailable())
    }

    @Test
    func theLockIsGivenBackWhenTheWorkThrows() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = CrossProcessFileLock(url: directory.appendingPathComponent(".lock"))

        struct Boom: Error {}
        do {
            _ = try await lock.withLock { throw Boom() }
            Issue.record("the work should have thrown")
        } catch is Boom {
            // expected
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        // A lock that survived its own failure would deadlock the next caller, which in a share
        // extension means a queue that never drains again.
        #expect(await lock.isAvailable())
    }

    @Test
    func aSecondHolderIsExcludedWhileTheFirstHasIt() async throws {
        // flock is per file descriptor, so two locks over the same path genuinely contend even
        // inside one process. That is the same exclusion two processes get, tested without needing
        // two processes.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".lock")
        let holder = CrossProcessFileLock(url: path)
        let contender = CrossProcessFileLock(url: path, timeoutSeconds: 0.2, pollIntervalSeconds: 0.01)

        try await holder.withLock {
            #expect(await contender.isAvailable() == false)

            do {
                _ = try await contender.withLock { 1 }
                Issue.record("the contender should not have been let in")
            } catch let failure as CrossProcessFileLock.Failure {
                #expect(failure == .timedOut(path: path.path))
                #expect(failure.description.contains("Timed out"))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        // Once the holder is done the contender gets in without waiting.
        #expect(try await contender.withLock { 7 } == 7)
    }

    @Test
    func theLockFileIsCreatedAlongWithItsDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("queue/inner/.lock")
        let lock = CrossProcessFileLock(url: nested)

        _ = try await lock.withLock { true }

        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test
    func nonsensicalTimingIsClampedRatherThanTrusted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A negative timeout and a zero poll interval would otherwise mean "never wait" and "spin".
        let lock = CrossProcessFileLock(
            url: directory.appendingPathComponent(".lock"),
            timeoutSeconds: -10,
            pollIntervalSeconds: 0
        )

        #expect(try await lock.withLock { "ok" } == "ok")
    }
}

@Suite
struct AppGroupContainerTests {
    @Test
    func platformsDisagreeAboutTheUnentitledCaseAndTheDocumentationSaysSo() throws {
        // Worth pinning down, because it decides where an adopter's mistake surfaces. iOS returns
        // nil without the entitlement, which becomes `unavailable`. macOS hands back a path under
        // Group Containers regardless, so the missing entitlement is only found when something
        // tries to write there.
        let identifier = "group.com.example.definitely-not-entitled"
        #if os(macOS)
        let url = try AppGroupContainer.url(forAppGroup: identifier)
        #expect(url.path.contains(identifier))
        #elseif canImport(Darwin)
        #expect(throws: AppGroupContainer.Failure.unavailable(identifier: identifier)) {
            try AppGroupContainer.url(forAppGroup: identifier)
        }
        #else
        #expect(throws: AppGroupContainer.Failure.unsupportedPlatform) {
            try AppGroupContainer.url(forAppGroup: identifier)
        }
        #endif
    }

    @Test
    func theFailureSaysWhatToCheck() {
        let failure = AppGroupContainer.Failure.unavailable(identifier: "group.com.example.app")

        #expect(failure.description.contains("group.com.example.app"))
        #expect(failure.description.contains("com.apple.security.application-groups"))
    }
}

@Suite
struct CoordinatedOfflineWriteStoreTests {
    private func request(_ path: String) -> APIRequest {
        APIRequest(method: .post, url: URL(string: "https://api.example.com\(path)")!)
    }

    private func makeStore(in directory: URL) -> CoordinatedOfflineWriteStore {
        CoordinatedOfflineWriteStore(
            wrapping: DiskOfflineWriteStore(directoryURL: directory),
            lock: CrossProcessFileLock(url: directory.appendingPathComponent(".lock"))
        )
    }

    @Test
    func wrappingAStoreDoesNotChangeWhatItDoes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let receipt = try await store.enqueue(request: request("/orders"), requestKey: "orders", now: now)

        #expect(receipt.requestKey == "orders")
        #expect(await store.depth(now: now) == 1)
        #expect(await store.snapshot(now: now).count == 1)
        #expect(await store.nextBatch(limit: 10, now: now).count == 1)

        await store.markSucceeded(queueID: receipt.queueID)
        #expect(await store.depth(now: now) == 0)
    }

    @Test
    func twoStoresOverOneDirectorySeeEachOthersWork() async throws {
        // The whole point: an app and its extension are two stores over one directory. Each takes
        // the lock, so neither writes over what the other just did.
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = makeStore(in: directory)
        let extensionSide = makeStore(in: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await extensionSide.enqueue(request: request("/share"), requestKey: "share", now: now)

        #expect(await app.depth(now: now) == 1)
        #expect(await app.snapshot(now: now).first?.receipt.requestKey == "share")
    }

    @Test
    func concurrentEnqueuesFromBothSidesAllSurvive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = makeStore(in: directory)
        let extensionSide = makeStore(in: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                let store = index.isMultiple(of: 2) ? app : extensionSide
                group.addTask {
                    _ = try? await store.enqueue(
                        request: self.request("/item/\(index)"),
                        requestKey: "item-\(index)",
                        now: now
                    )
                }
            }
        }

        // Without the lock this is where entries go missing: two readers see the same count and
        // two writers claim the same position.
        #expect(await app.depth(now: now) == 6)
    }

    @Test
    func aDroppedQueueIsEmptyFromBothSides() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = makeStore(in: directory)
        let extensionSide = makeStore(in: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await app.enqueue(request: request("/a"), requestKey: "a", now: now)
        _ = try await app.enqueue(request: request("/b"), requestKey: "b", now: now)

        #expect(await extensionSide.dropAll() == 2)
        #expect(await app.depth(now: now) == 0)
    }
}
