import Foundation
import Testing
@testable import NovaNetworkClient

final class DeterministicDiskStoreFaultInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var planned: [DiskOfflineWriteStoreFaultPoint: [DiskOfflineWriteStoreFaultAction]]

    init(planned: [DiskOfflineWriteStoreFaultPoint: [DiskOfflineWriteStoreFaultAction]]) {
        self.planned = planned
    }

    func action(for point: DiskOfflineWriteStoreFaultPoint) -> DiskOfflineWriteStoreFaultAction {
        lock.lock()
        defer { lock.unlock() }
        guard var actions = planned[point], !actions.isEmpty else {
            return .proceed
        }
        let next = actions.removeFirst()
        planned[point] = actions
        return next
    }
}

@Suite
struct OfflineQueueCoverageTests {
    private actor MinimalOfflineWriteStore: OfflineWriteStore {
        private(set) var entries: [OfflineWriteStoreEntry] = []

        func enqueue(request: APIRequest, requestKey: String, now: Date) async throws -> QueuedWriteReceipt {
            let receipt = QueuedWriteReceipt(queueID: UUID().uuidString, requestKey: requestKey, position: entries.count + 1, enqueuedAt: now)
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

    private static func fixedKey() -> Data {
        Data(repeating: 7, count: 32)
    }

    @Test
    func diskOfflineWriteStorePersistsAcrossRestart() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineStore-\(UUID().uuidString)")
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/items")!,
            headers: ["X-Test": "1"],
            body: Data("payload".utf8)
        )
        let now = Date(timeIntervalSince1970: 100)

        let first = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await first.enqueue(request: request, requestKey: "k1", now: now)

        let restored = DiskOfflineWriteStore(directoryURL: baseURL)
        let snapshot = await restored.snapshot(now: now)

        #expect(snapshot.count == 1)
        #expect(snapshot[0].request.method == .post)
        #expect(snapshot[0].request.url == request.url)
        #expect(snapshot[0].request.headers["X-Test"] == "1")
        #expect(snapshot[0].request.body == Data("payload".utf8))
    }

    @Test
    func diskOfflineWriteStoreSkipsMismatchedSchemaVersion() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineSchema-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/versioned")!)
        let now = Date(timeIntervalSince1970: 200)

        let writer = DiskOfflineWriteStore(directoryURL: baseURL, schemaVersion: 2)
        _ = try await writer.enqueue(request: request, requestKey: "k2", now: now)

        let reader = DiskOfflineWriteStore(directoryURL: baseURL, schemaVersion: 1)
        let snapshot = await reader.snapshot(now: now)
        #expect(snapshot.isEmpty)
    }

    @Test
    func diskOfflineWriteStoreTTLPrunesExpiredEntries() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineTTL-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/ttl")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL, ttlSeconds: 2)

        _ = try await store.enqueue(
            request: request,
            requestKey: "k3",
            now: Date(timeIntervalSince1970: 0)
        )

        #expect(await store.depth(now: Date(timeIntervalSince1970: 3)) == 0)
    }

    @Test
    func diskOfflineWriteStoreEvictsOldestWhenAtCapacity() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineCap-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/capacity")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL, maxEntries: 2, overflowPolicy: .evictOldest)

        _ = try await store.enqueue(request: request, requestKey: "first", now: Date(timeIntervalSince1970: 1))
        _ = try await store.enqueue(request: request, requestKey: "second", now: Date(timeIntervalSince1970: 2))
        _ = try await store.enqueue(request: request, requestKey: "third", now: Date(timeIntervalSince1970: 3))

        let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 3))
        #expect(snapshot.count == 2)
        #expect(snapshot.contains(where: { $0.receipt.requestKey == "second" }))
        #expect(snapshot.contains(where: { $0.receipt.requestKey == "third" }))
    }

    @Test
    func diskOfflineWriteStoreRejectsWhenConfiguredToRejectNew() async {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineReject-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/reject")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL, maxEntries: 1, overflowPolicy: .rejectNew)

        _ = try? await store.enqueue(request: request, requestKey: "first", now: Date(timeIntervalSince1970: 1))

        do {
            _ = try await store.enqueue(request: request, requestKey: "second", now: Date(timeIntervalSince1970: 2))
            Issue.record("Expected capacity error")
        } catch let error as OfflineWriteStoreError {
            #expect(error == .queueCapacityExceeded(limit: 1))
        } catch {
            Issue.record("Unexpected error")
        }
    }

    @Test
    func diskOfflineWriteStoreSkipsCorruptedEntryAndKeepsValidEntries() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineCorrupt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let corruptURL = baseURL.appendingPathComponent("broken.json")
        try Data("not json".utf8).write(to: corruptURL, options: .atomic)

        let request = APIRequest(method: .post, url: URL(string: "https://example.com/corrupt")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await store.enqueue(request: request, requestKey: "ok", now: Date(timeIntervalSince1970: 1))

        let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 1))
        #expect(snapshot.count == 1)
        #expect(snapshot[0].receipt.requestKey == "ok")
        #expect(FileManager.default.fileExists(atPath: corruptURL.path) == false)
    }

    @Test
    func diskOfflineWriteStoreNextBatchRespectsRetryScheduleAndOrder() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineBatch-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/batch")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        let now = Date(timeIntervalSince1970: 10)

        let first = try await store.enqueue(request: request, requestKey: "first", now: now)
        let second = try await store.enqueue(request: request, requestKey: "second", now: now.addingTimeInterval(1))

        await store.markRetryWaiting(
            queueID: first.queueID,
            attempt: 1,
            reason: "network",
            nextRetryAt: now.addingTimeInterval(60),
            now: now
        )
        await store.markReplaying(queueID: second.queueID, attempt: 1, now: now)

        let beforeReady = await store.nextBatch(limit: 10, now: now.addingTimeInterval(5))
        #expect(beforeReady.isEmpty)

        await store.markSucceeded(queueID: second.queueID)
        let afterReady = await store.nextBatch(limit: 10, now: now.addingTimeInterval(120))

        // Indexing after a failed count expectation traps and takes the whole test process with it,
        // so one regression here used to be reported as a crashed suite. `#require` fails this test
        // and lets the rest run. The recovery report goes in the message because the store answers
        // "no entries" both when there are none and when it decided what it found was corrupt, and
        // those are very different bugs.
        let report = await store.consumeRecoveryReport()
        let ready = try #require(
            afterReady.first,
            "expected the retry-waiting entry to be ready; recovery report: \(String(describing: report))"
        )
        #expect(afterReady.count == 1)
        #expect(ready.receipt.queueID == first.queueID)
    }

// AES-GCM encryption at rest is CryptoKit-only, and so are the tests that exercise it.
#if canImport(CryptoKit)
    @Test
    func diskOfflineWriteStoreEncryptedRoundTripAndLegacyReadCompatibility() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineEncrypt-\(UUID().uuidString)")
        let request = APIRequest(
            method: .post,
            url: URL(string: "https://example.com/encrypted")!,
            headers: ["X-Sensitive": "true"],
            body: Data("super-secret-payload".utf8)
        )
        let now = Date(timeIntervalSince1970: 500)
        let cipher = AESGCMOfflineWriteStoreCipher(keyProvider: { Self.fixedKey() })

        let legacyPlainStore = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await legacyPlainStore.enqueue(request: request, requestKey: "legacy", now: now)

        let encryptedReader = DiskOfflineWriteStore(directoryURL: baseURL, cipher: cipher)
        let legacySnapshot = await encryptedReader.snapshot(now: now)
        #expect(legacySnapshot.count == 1)
        #expect(legacySnapshot[0].receipt.requestKey == "legacy")

        _ = try await encryptedReader.enqueue(request: request, requestKey: "encrypted", now: now.addingTimeInterval(1))

        let files = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "replay_success_index.json" }
        let encryptedFile = try #require(
            files.first(where: { $0.lastPathComponent != "\(legacySnapshot[0].receipt.queueID).json" })
        )
        let encryptedContent = try Data(contentsOf: encryptedFile)
        let encryptedText = String(data: encryptedContent, encoding: .utf8) ?? ""
        #expect(!encryptedText.contains("super-secret-payload"))

        let restoredEncrypted = DiskOfflineWriteStore(directoryURL: baseURL, cipher: cipher)
        let snapshot = await restoredEncrypted.snapshot(now: now.addingTimeInterval(2))
        #expect(snapshot.count == 2)
    }
#endif

// AES-GCM encryption at rest is CryptoKit-only, and so are the tests that exercise it.
#if canImport(CryptoKit)
    @Test
    func diskOfflineWriteStoreKeepsEncryptedEntriesWhenKeyUnavailable() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineEncryptKey-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/encrypted-key")!)
        let now = Date(timeIntervalSince1970: 600)
        let goodCipher = AESGCMOfflineWriteStoreCipher(keyProvider: { Self.fixedKey() })
        let unavailableCipher = AESGCMOfflineWriteStoreCipher(
            keyProvider: { throw OfflineWriteStoreCipherError.keyUnavailable }
        )

        let writer = DiskOfflineWriteStore(directoryURL: baseURL, cipher: goodCipher)
        _ = try await writer.enqueue(request: request, requestKey: "k-encrypted", now: now)

        let blockedReader = DiskOfflineWriteStore(directoryURL: baseURL, cipher: unavailableCipher)
        let blockedSnapshot = await blockedReader.snapshot(now: now)
        #expect(blockedSnapshot.isEmpty)
        let filesAfterBlockedRead = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
        #expect(filesAfterBlockedRead.contains(where: { $0.pathExtension == "json" }))

        let recoveredReader = DiskOfflineWriteStore(directoryURL: baseURL, cipher: goodCipher)
        let recoveredSnapshot = await recoveredReader.snapshot(now: now)
        #expect(recoveredSnapshot.count == 1)
        #expect(recoveredSnapshot[0].receipt.requestKey == "k-encrypted")
    }
#endif

// AES-GCM encryption at rest is CryptoKit-only, and so are the tests that exercise it.
#if canImport(CryptoKit)
    @Test
    func diskOfflineWriteStoreSkipsUnknownEncryptionVersionWithoutDeletingEntry() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineEncryptVersion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let fileURL = baseURL.appendingPathComponent("unknown-version.json")
        let unknownEnvelope = PersistedOfflineWriteEnvelope(
            schemaVersion: 1,
            entry: nil,
            encryptedEntry: Data("ciphertext".utf8),
            encryption: PersistedOfflineWriteEncryptionMetadata(algorithm: "AES.GCM", version: 999)
        )
        let encoded = try JSONEncoder().encode(unknownEnvelope)
        try encoded.write(to: fileURL, options: .atomic)

        let reader = DiskOfflineWriteStore(
            directoryURL: baseURL,
            cipher: AESGCMOfflineWriteStoreCipher(version: 1, keyProvider: { Self.fixedKey() })
        )
        let snapshot = await reader.snapshot(now: Date())
        #expect(snapshot.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }
#endif

    @Test
    func diskOfflineWriteStoreReadsOlderSchemaWithForwardCompatibility() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineSchemaForward-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/schema-forward")!)
        let now = Date(timeIntervalSince1970: 700)

        let writer = DiskOfflineWriteStore(directoryURL: baseURL, schemaVersion: 1)
        _ = try await writer.enqueue(request: request, requestKey: "legacy-schema", now: now)

        let reader = DiskOfflineWriteStore(directoryURL: baseURL, schemaVersion: 2)
        let snapshot = await reader.snapshot(now: now)
        #expect(snapshot.count == 1)
        #expect(snapshot[0].receipt.requestKey == "legacy-schema")
    }

// AES-GCM encryption at rest is CryptoKit-only, and so are the tests that exercise it.
#if canImport(CryptoKit)
    @Test
    func diskOfflineWriteStoreRotateEncryptionRewritesEntriesWithNewVersion() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineRotate-\(UUID().uuidString)")
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/rotate")!)
        let now = Date(timeIntervalSince1970: 800)

        let rotatingV1 = RotatingAESGCMOfflineWriteStoreCipher(
            version: 1,
            currentKeyProvider: { Data(repeating: 1, count: 32) },
            historicalKeyProvider: { _ in Data(repeating: 1, count: 32) }
        )
        let writer = DiskOfflineWriteStore(directoryURL: baseURL, cipher: rotatingV1)
        _ = try await writer.enqueue(request: request, requestKey: "rotate-me", now: now)

        let rotatingV2 = RotatingAESGCMOfflineWriteStoreCipher(
            version: 2,
            currentKeyProvider: { Data(repeating: 2, count: 32) },
            historicalKeyProvider: { version in
                if version == 1 {
                    return Data(repeating: 1, count: 32)
                }
                return Data(repeating: 2, count: 32)
            }
        )
        let rotator = DiskOfflineWriteStore(directoryURL: baseURL, cipher: rotatingV2)
        let rewritten = await rotator.rotateEncryption(now: now.addingTimeInterval(5))
        #expect(rewritten == 1)

        let files = try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "replay_success_index.json" }
        let payload = try #require(files.first)
        let envelopeData = try Data(contentsOf: payload)
        let envelope = try JSONDecoder().decode(PersistedOfflineWriteEnvelope.self, from: envelopeData)
        #expect(envelope.encryption?.version == 2)

        let latestReader = DiskOfflineWriteStore(directoryURL: baseURL, cipher: rotatingV2)
        let snapshot = await latestReader.snapshot(now: now.addingTimeInterval(6))
        #expect(snapshot.count == 1)
    }
#endif

    @Test
    func diskOfflineWriteStoreRecoveryReportCapturesPartialCorruption() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineRecoveryReport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let request = APIRequest(method: .post, url: URL(string: "https://example.com/recovery-good")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await store.enqueue(request: request, requestKey: "good", now: Date(timeIntervalSince1970: 900))

        try Data("not-json".utf8).write(to: baseURL.appendingPathComponent("broken.json"), options: .atomic)

        let unknownVersion = PersistedOfflineWriteEnvelope(
            schemaVersion: 999,
            entry: nil,
            encryptedEntry: Data("ciphertext".utf8),
            encryption: PersistedOfflineWriteEncryptionMetadata(algorithm: "AES.GCM", version: 999)
        )
        let unknownData = try JSONEncoder().encode(unknownVersion)
        try unknownData.write(to: baseURL.appendingPathComponent("future.json"), options: .atomic)

        let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 900))
        #expect(snapshot.count == 1)

        let report = await store.consumeRecoveryReport()
        #expect(report?.scannedRecords == 3)
        #expect(report?.recoveredRecords == 1)
        #expect(report?.skippedCorruptedRecords == 1)
        #expect(report?.skippedIncompatibleRecords == 1)
    }

    @Test
    func diskOfflineWriteStoreFaultInjectionCanForceDeterministicIOErrorOnWrite() async {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineFaultIO-\(UUID().uuidString)")
        let injector = DeterministicDiskStoreFaultInjector(
            planned: [.beforeWriteEntry: [.failIO]]
        )
        let store = DiskOfflineWriteStore(
            directoryURL: baseURL,
            faultInjector: { injector.action(for: $0) }
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/fault-io")!)

        do {
            _ = try await store.enqueue(request: request, requestKey: "io-fault", now: Date(timeIntervalSince1970: 1_000))
            Issue.record("Expected injected I/O write error")
        } catch {
            #expect(await store.depth(now: Date(timeIntervalSince1970: 1_000)) == 0)
        }
    }

    @Test
    func diskOfflineWriteStoreFaultInjectionPartialWriteRecoversWithLossMetrics() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineFaultPartial-\(UUID().uuidString)")
        let injector = DeterministicDiskStoreFaultInjector(
            planned: [.beforeCommitEntry: [.partialWriteAndFail]]
        )
        let store = DiskOfflineWriteStore(
            directoryURL: baseURL,
            faultInjector: { injector.action(for: $0) }
        )
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/fault-partial")!)
        let now = Date(timeIntervalSince1970: 1_100)

        _ = try? await store.enqueue(request: request, requestKey: "partial-corrupted", now: now)
        let degradedSnapshot = await store.snapshot(now: now)
        #expect(degradedSnapshot.isEmpty)
        let degradedReport = await store.consumeRecoveryReport()
        #expect((degradedReport?.skippedCorruptedRecords ?? 0) >= 1)
        #expect((degradedReport?.recoveryLossRate ?? 0) > 0)

        _ = try await store.enqueue(request: request, requestKey: "good", now: now.addingTimeInterval(1))

        let snapshot = await store.snapshot(now: now.addingTimeInterval(2))
        #expect(snapshot.count == 1)
        #expect(snapshot[0].receipt.requestKey == "good")
    }

    @Test
    func diskOfflineWriteStoreCorruptionBudgetFailClosedWhenCorruptionDominates() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineCorruptionBudget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let request = APIRequest(method: .post, url: URL(string: "https://example.com/budget")!)
        let store = DiskOfflineWriteStore(directoryURL: baseURL)
        _ = try await store.enqueue(request: request, requestKey: "survivor", now: Date(timeIntervalSince1970: 1_200))

        try Data("bad-1".utf8).write(to: baseURL.appendingPathComponent("bad-1.json"), options: .atomic)
        try Data("bad-2".utf8).write(to: baseURL.appendingPathComponent("bad-2.json"), options: .atomic)
        try Data("bad-3".utf8).write(to: baseURL.appendingPathComponent("bad-3.json"), options: .atomic)

        let snapshot = await store.snapshot(now: Date(timeIntervalSince1970: 1_200))
        #expect(snapshot.isEmpty)

        let report = await store.consumeRecoveryReport()
        #expect(report?.corruptionBudgetExceeded == true)
        #expect((report?.skippedCorruptedRecords ?? 0) >= 3)
    }

    @Test
    func diskOfflineWriteStoreTTLHandlesBackwardClockSkewWithoutPrematurePrune() async throws {
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RequestCoalescer-OfflineClockSkew-\(UUID().uuidString)")
        let store = DiskOfflineWriteStore(directoryURL: baseURL, ttlSeconds: 30)
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/clock-skew")!)

        _ = try await store.enqueue(request: request, requestKey: "clock-entry", now: Date(timeIntervalSince1970: 100))
        #expect(await store.depth(now: Date(timeIntervalSince1970: 50)) == 1)
        #expect(await store.depth(now: Date(timeIntervalSince1970: 200)) == 0)
    }

    @Test
    func offlineStoreRecoveryReportComputesLossRateAndTotalsIncludingOrphans() {
        let report = OfflineStoreRecoveryReport(
            scannedRecords: 10,
            recoveredRecords: 6,
            skippedCorruptedRecords: 2,
            skippedIncompatibleRecords: 1,
            orphanedTemporaryRecords: 1,
            corruptionBudgetExceeded: true
        )
        #expect(report.skippedTotal == 4)
        #expect(report.recoveryLossRate == 0.4)
        #expect(report.corruptionBudgetExceeded)
    }

    @Test
    func offlineWriteStoreProtocolDefaultsRemainSafeNoops() async throws {
        let store = MinimalOfflineWriteStore()
        let request = APIRequest(method: .post, url: URL(string: "https://example.com/defaults")!)
        _ = try await store.enqueue(
            request: request,
            requestKey: "defaults",
            replayMetadata: .init(replayIdentity: "defaults"),
            now: Date(timeIntervalSince1970: 1_300)
        )

        await store.markManualReview(queueID: "missing", reason: "noop", now: Date())
        let requeued = await store.requeueManualReview(queueID: "missing", reason: nil, now: Date())
        #expect(requeued == false)
        #expect(await store.hasReplayTerminalSuccess(replayIdentity: "defaults", within: 60, now: Date()) == false)
        await store.recordReplayTerminalSuccess(replayIdentity: "defaults", now: Date())
        #expect(await store.rotateEncryption(now: Date()) == 0)
        #expect(await store.consumeRecoveryReport() == nil)
    }
}
