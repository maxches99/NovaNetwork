import Foundation

enum DiskOfflineWriteStoreFaultPoint: Hashable, Sendable {
    case createDirectory
    case listEntries
    case readEntry
    case beforeWriteEntry
    case afterWriteTemporaryEntry
    case beforeCommitEntry
    case readReplaySuccessIndex
    case writeReplaySuccessIndex
}

enum DiskOfflineWriteStoreFaultAction: Sendable, Equatable {
    case proceed
    case failIO
    case partialWriteAndFail
}

typealias DiskOfflineWriteStoreFaultInjector = @Sendable (DiskOfflineWriteStoreFaultPoint) -> DiskOfflineWriteStoreFaultAction

public actor DiskOfflineWriteStore: OfflineWriteStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let maxEntries: Int?
    private let ttlSeconds: TimeInterval?
    private let overflowPolicy: OfflineWriteStoreOverflowPolicy
    private let schemaVersion: Int
    private let cipher: (any OfflineWriteStoreCipher)?
    private let corruptionBudgetMaxCorruptedRecords: Int
    private let corruptionBudgetMaxCorruptedRatio: Double
    private let faultInjector: DiskOfflineWriteStoreFaultInjector?

    private var replaySuccessIndex: [String: Date] = [:]
    private var didLoadReplaySuccessIndex = false
    private var pendingRecoveryReport: OfflineStoreRecoveryReport?

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maxEntries: Int? = nil,
        ttlSeconds: TimeInterval? = nil,
        overflowPolicy: OfflineWriteStoreOverflowPolicy = .evictOldest,
        schemaVersion: Int = 1,
        cipher: (any OfflineWriteStoreCipher)? = nil
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxEntries = maxEntries.map { max(1, $0) }
        self.ttlSeconds = ttlSeconds.map { max(0, $0) }
        self.overflowPolicy = overflowPolicy
        self.schemaVersion = max(1, schemaVersion)
        self.cipher = cipher
        // Corruption budget intentionally conservative to preserve partial recovery while preventing unsafe replay.
        self.corruptionBudgetMaxCorruptedRecords = 32
        self.corruptionBudgetMaxCorruptedRatio = 0.5
        self.faultInjector = nil
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maxEntries: Int? = nil,
        ttlSeconds: TimeInterval? = nil,
        overflowPolicy: OfflineWriteStoreOverflowPolicy = .evictOldest,
        schemaVersion: Int = 1,
        cipher: (any OfflineWriteStoreCipher)? = nil,
        corruptionBudgetMaxCorruptedRecords: Int = 32,
        corruptionBudgetMaxCorruptedRatio: Double = 0.5,
        faultInjector: DiskOfflineWriteStoreFaultInjector? = nil
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxEntries = maxEntries.map { max(1, $0) }
        self.ttlSeconds = ttlSeconds.map { max(0, $0) }
        self.overflowPolicy = overflowPolicy
        self.schemaVersion = max(1, schemaVersion)
        self.cipher = cipher
        self.corruptionBudgetMaxCorruptedRecords = max(0, corruptionBudgetMaxCorruptedRecords)
        self.corruptionBudgetMaxCorruptedRatio = min(1, max(0, corruptionBudgetMaxCorruptedRatio))
        self.faultInjector = faultInjector
    }

    @discardableResult
    public func enqueue(request: APIRequest, requestKey: String, now: Date = Date()) async throws -> QueuedWriteReceipt {
        try await enqueue(
            request: request,
            requestKey: requestKey,
            replayMetadata: .init(replayIdentity: requestKey),
            now: now
        )
    }

    @discardableResult
    public func enqueue(
        request: APIRequest,
        requestKey: String,
        replayMetadata: OfflineReplayMetadata,
        now: Date = Date()
    ) async throws -> QueuedWriteReceipt {
        ensureDirectory()
        await prune(now: now)

        if let maxEntries, await countEntries() >= maxEntries {
            switch overflowPolicy {
            case .evictOldest:
                await removeOldestEntryIfNeeded()
            case .rejectNew:
                throw OfflineWriteStoreError.queueCapacityExceeded(limit: maxEntries)
            }
        }

        let position = (await maxPosition()) + 1
        let receipt = QueuedWriteReceipt(
            queueID: UUID().uuidString,
            requestKey: requestKey,
            position: position,
            enqueuedAt: now
        )
        let entry = OfflineWriteStoreEntry(
            receipt: receipt,
            request: request,
            attempt: 0,
            nextRetryAt: nil,
            lastFailureReason: nil,
            state: .queued,
            updatedAt: now,
            replayMetadata: replayMetadata
        )
        try write(entry)
        return receipt
    }

    public func nextBatch(limit: Int, now: Date = Date()) async -> [OfflineWriteStoreEntry] {
        await prune(now: now)
        guard limit > 0 else { return [] }
        return await loadEntries()
            .filter { entry in
                switch entry.state {
                case .queued, .replayScheduled:
                    return true
                case .retryWaiting:
                    guard let nextRetryAt = entry.nextRetryAt else { return true }
                    return nextRetryAt <= now
                case .replaying, .deadLetter, .manualReview:
                    return false
                }
            }
            .sorted { lhs, rhs in lhs.receipt.position < rhs.receipt.position }
            .prefix(limit)
            .map { $0 }
    }

    public func markReplaying(queueID: String, attempt: Int, now: Date = Date()) async {
        await mutate(queueID: queueID) { entry in
            OfflineWriteStoreEntry(
                receipt: entry.receipt,
                request: entry.request,
                attempt: max(entry.attempt, attempt),
                nextRetryAt: nil,
                lastFailureReason: entry.lastFailureReason,
                state: .replaying,
                updatedAt: now,
                replayMetadata: entry.replayMetadata,
                lastTerminalStatus: entry.lastTerminalStatus,
                lastTerminalAt: entry.lastTerminalAt
            )
        }
    }

    public func markRetryWaiting(
        queueID: String,
        attempt: Int,
        reason: String,
        nextRetryAt: Date,
        now: Date = Date()
    ) async {
        await mutate(queueID: queueID) { entry in
            OfflineWriteStoreEntry(
                receipt: entry.receipt,
                request: entry.request,
                attempt: max(entry.attempt, attempt),
                nextRetryAt: nextRetryAt,
                lastFailureReason: reason,
                state: .retryWaiting,
                updatedAt: now,
                replayMetadata: entry.replayMetadata,
                lastTerminalStatus: .failed,
                lastTerminalAt: now
            )
        }
    }

    public func markSucceeded(queueID: String) async {
        try? fileManager.removeItem(at: fileURL(forQueueID: queueID))
    }

    public func markDeadLetter(queueID: String, reason: String, now: Date = Date()) async {
        await mutate(queueID: queueID) { entry in
            OfflineWriteStoreEntry(
                receipt: entry.receipt,
                request: entry.request,
                attempt: entry.attempt,
                nextRetryAt: nil,
                lastFailureReason: reason,
                state: .deadLetter,
                updatedAt: now,
                replayMetadata: entry.replayMetadata,
                lastTerminalStatus: .failed,
                lastTerminalAt: now
            )
        }
    }

    public func markManualReview(queueID: String, reason: String, now: Date = Date()) async {
        await mutate(queueID: queueID) { entry in
            OfflineWriteStoreEntry(
                receipt: entry.receipt,
                request: entry.request,
                attempt: entry.attempt,
                nextRetryAt: nil,
                lastFailureReason: reason,
                state: .manualReview,
                updatedAt: now,
                replayMetadata: entry.replayMetadata,
                lastTerminalStatus: .manualReview,
                lastTerminalAt: now
            )
        }
    }

    public func requeueManualReview(queueID: String, reason: String?, now: Date = Date()) async -> Bool {
        guard let current = await loadEntry(queueID: queueID) else { return false }
        guard current.state == .manualReview else { return false }
        let updated = OfflineWriteStoreEntry(
            receipt: current.receipt,
            request: current.request,
            attempt: current.attempt,
            nextRetryAt: nil,
            lastFailureReason: reason ?? current.lastFailureReason,
            state: .replayScheduled,
            updatedAt: now,
            replayMetadata: current.replayMetadata,
            lastTerminalStatus: .failed,
            lastTerminalAt: now
        )
        do {
            try write(updated)
            return true
        } catch {
            return false
        }
    }

    public func hasReplayTerminalSuccess(replayIdentity: String, within: TimeInterval, now: Date = Date()) async -> Bool {
        await loadReplaySuccessIndexIfNeeded()
        guard let successAt = replaySuccessIndex[replayIdentity] else {
            return false
        }
        return now.timeIntervalSince(successAt) <= max(0, within)
    }

    public func recordReplayTerminalSuccess(replayIdentity: String, now: Date = Date()) async {
        await loadReplaySuccessIndexIfNeeded()
        replaySuccessIndex[replayIdentity] = now
        writeReplaySuccessIndex()
    }

    public func rotateEncryption(now: Date = Date()) async -> Int {
        let entries = await loadEntries()
        guard !entries.isEmpty else { return 0 }
        var rewritten = 0
        for entry in entries {
            let rewrittenEntry = OfflineWriteStoreEntry(
                receipt: entry.receipt,
                request: entry.request,
                attempt: entry.attempt,
                nextRetryAt: entry.nextRetryAt,
                lastFailureReason: entry.lastFailureReason,
                state: entry.state,
                updatedAt: now,
                replayMetadata: entry.replayMetadata,
                lastTerminalStatus: entry.lastTerminalStatus,
                lastTerminalAt: entry.lastTerminalAt
            )
            if (try? write(rewrittenEntry)) != nil {
                rewritten += 1
            }
        }
        return rewritten
    }

    public func consumeRecoveryReport() async -> OfflineStoreRecoveryReport? {
        defer { pendingRecoveryReport = nil }
        return pendingRecoveryReport
    }

    public func depth(now: Date = Date()) async -> Int {
        await prune(now: now)
        return await countEntries()
    }

    public func snapshot(now: Date = Date()) async -> [OfflineWriteStoreEntry] {
        await prune(now: now)
        return await loadEntries()
            .sorted { lhs, rhs in lhs.receipt.position < rhs.receipt.position }
    }

    @discardableResult
    public func drop(queueID: String) async -> Bool {
        let fileURL = fileURL(forQueueID: queueID)
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        try? fileManager.removeItem(at: fileURL)
        return true
    }

    @discardableResult
    public func dropAll() async -> Int {
        let files = entryFileURLs()
        for file in files {
            try? fileManager.removeItem(at: file)
        }
        return files.count
    }

    private func ensureDirectory() {
        guard injectedAction(for: .createDirectory) != .failIO else { return }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(forQueueID queueID: String) -> URL {
        directoryURL.appendingPathComponent("\(queueID).json")
    }

    private func partialFileURL(forQueueID queueID: String) -> URL {
        directoryURL.appendingPathComponent("\(queueID).json.partial")
    }

    private func replaySuccessIndexURL() -> URL {
        directoryURL.appendingPathComponent("replay_success_index.json")
    }

    private func entryFileURLs() -> [URL] {
        guard injectedAction(for: .listEntries) != .failIO else { return [] }
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return files.filter {
            $0.pathExtension == "json" &&
                $0.lastPathComponent != replaySuccessIndexURL().lastPathComponent
        }
    }

    private func cleanupOrphanedTemporaryFiles() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        let temporaryFiles = files.filter { $0.pathExtension == "partial" }
        for temporary in temporaryFiles {
            try? fileManager.removeItem(at: temporary)
        }
        return temporaryFiles.count
    }

    private enum DecodeOutcome {
        case entry(OfflineWriteStoreEntry)
        case skipAndKeepIncompatible
        case skipAndRemoveCorrupted
    }

    private func loadEntries() async -> [OfflineWriteStoreEntry] {
        ensureDirectory()
        var entries: [OfflineWriteStoreEntry] = []
        let orphanedTemporary = cleanupOrphanedTemporaryFiles()
        var scanned = 0
        var skippedCorrupted = 0
        var skippedIncompatible = 0
        for file in entryFileURLs() {
            scanned += 1
            switch decodeEntry(file: file) {
            case .entry(let entry):
                entries.append(entry)
            case .skipAndKeepIncompatible:
                skippedIncompatible += 1
                continue
            case .skipAndRemoveCorrupted:
                skippedCorrupted += 1
                try? fileManager.removeItem(at: file)
            }
        }

        let scannedRecords = scanned + orphanedTemporary
        let corruptedTotal = skippedCorrupted + orphanedTemporary
        let corruptedRatio = scannedRecords == 0 ? 0 : Double(corruptedTotal) / Double(scannedRecords)
        let budgetExceeded = corruptedTotal > corruptionBudgetMaxCorruptedRecords ||
            corruptedRatio > corruptionBudgetMaxCorruptedRatio
        if budgetExceeded {
            entries = []
        }

        pendingRecoveryReport = OfflineStoreRecoveryReport(
            scannedRecords: scannedRecords,
            recoveredRecords: entries.count,
            skippedCorruptedRecords: skippedCorrupted,
            skippedIncompatibleRecords: skippedIncompatible,
            orphanedTemporaryRecords: orphanedTemporary,
            corruptionBudgetExceeded: budgetExceeded
        )
        return entries
    }

    private func decodeEntry(file: URL) -> DecodeOutcome {
        if injectedAction(for: .readEntry) == .failIO {
            return .skipAndRemoveCorrupted
        }
        guard
            let data = try? Data(contentsOf: file),
            let envelope = try? JSONDecoder().decode(PersistedOfflineWriteEnvelope.self, from: data)
        else {
            return .skipAndRemoveCorrupted
        }

        if envelope.schemaVersion > schemaVersion {
            return .skipAndKeepIncompatible
        }

        if let persisted = envelope.entry,
           let runtime = persisted.toRuntimeEntry() {
            return .entry(runtime)
        }

        guard
            let encryptedEntry = envelope.encryptedEntry,
            let encryption = envelope.encryption,
            let cipher
        else {
            return .skipAndRemoveCorrupted
        }

        do {
            let decrypted = try cipher.decrypt(
                encryptedEntry,
                algorithm: encryption.algorithm,
                version: encryption.version
            )
            guard
                let persisted = try? JSONDecoder().decode(PersistedOfflineWriteEntry.self, from: decrypted),
                let runtime = persisted.toRuntimeEntry()
            else {
                return .skipAndRemoveCorrupted
            }
            return .entry(runtime)
        } catch let error as OfflineWriteStoreCipherError {
            switch error {
            case .keyUnavailable, .unsupportedVersion:
                return .skipAndKeepIncompatible
            case .decryptionFailed:
                return .skipAndRemoveCorrupted
            }
        } catch {
            return .skipAndRemoveCorrupted
        }
    }

    private func write(_ entry: OfflineWriteStoreEntry) throws {
        ensureDirectory()

        let persisted = PersistedOfflineWriteEntry(from: entry)
        let envelope: PersistedOfflineWriteEnvelope

        if let cipher {
            let encoded = try JSONEncoder().encode(persisted)
            let encrypted: Data
            do {
                encrypted = try cipher.encrypt(encoded)
            } catch let error as OfflineWriteStoreCipherError {
                switch error {
                case .keyUnavailable:
                    throw OfflineWriteStoreError.encryptionKeyUnavailable
                case .unsupportedVersion(let version):
                    throw OfflineWriteStoreError.unsupportedEncryptionVersion(version)
                case .decryptionFailed:
                    throw OfflineWriteStoreError.encryptionFailure
                }
            } catch {
                throw OfflineWriteStoreError.encryptionFailure
            }
            envelope = PersistedOfflineWriteEnvelope(
                schemaVersion: schemaVersion,
                entry: nil,
                encryptedEntry: encrypted,
                encryption: PersistedOfflineWriteEncryptionMetadata(
                    algorithm: cipher.algorithm,
                    version: cipher.version
                )
            )
        } else {
            envelope = PersistedOfflineWriteEnvelope(
                schemaVersion: schemaVersion,
                entry: persisted,
                encryptedEntry: nil,
                encryption: nil
            )
        }

        let data = try JSONEncoder().encode(envelope)
        let queueID = entry.receipt.queueID
        if injectedAction(for: .beforeWriteEntry) == .failIO {
            throw injectedIOError()
        }

        let temporaryURL = partialFileURL(forQueueID: queueID)
        try data.write(to: temporaryURL, options: .atomic)

        if injectedAction(for: .afterWriteTemporaryEntry) == .failIO {
            throw injectedIOError()
        }

        switch injectedAction(for: .beforeCommitEntry) {
        case .proceed:
            break
        case .failIO:
            throw injectedIOError()
        case .partialWriteAndFail:
            let partialCount = max(1, data.count / 2)
            try Data(data.prefix(partialCount)).write(to: fileURL(forQueueID: queueID), options: [])
            throw injectedIOError()
        }

        let destinationURL = fileURL(forQueueID: queueID)
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        }
        try? fileManager.removeItem(at: temporaryURL)
    }

    private func mutate(queueID: String, transform: (OfflineWriteStoreEntry) -> OfflineWriteStoreEntry) async {
        guard let current = await loadEntry(queueID: queueID) else { return }
        try? write(transform(current))
    }

    private func loadEntry(queueID: String) async -> OfflineWriteStoreEntry? {
        let fileURL = fileURL(forQueueID: queueID)
        switch decodeEntry(file: fileURL) {
        case .entry(let entry):
            return entry
        case .skipAndKeepIncompatible:
            return nil
        case .skipAndRemoveCorrupted:
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
    }

    private func prune(now: Date) async {
        guard let ttlSeconds else { return }
        let cutoff = now.addingTimeInterval(-ttlSeconds)
        for entry in await loadEntries() where entry.receipt.enqueuedAt < cutoff {
            try? fileManager.removeItem(at: fileURL(forQueueID: entry.receipt.queueID))
        }
    }

    private func countEntries() async -> Int {
        await loadEntries().count
    }

    private func maxPosition() async -> Int {
        await loadEntries().map(\.receipt.position).max() ?? 0
    }

    private func removeOldestEntryIfNeeded() async {
        guard
            let oldest = await loadEntries()
                .min(by: { lhs, rhs in lhs.receipt.position < rhs.receipt.position })
        else {
            return
        }
        try? fileManager.removeItem(at: fileURL(forQueueID: oldest.receipt.queueID))
    }

    private func loadReplaySuccessIndexIfNeeded() async {
        guard !didLoadReplaySuccessIndex else { return }
        didLoadReplaySuccessIndex = true
        ensureDirectory()
        guard injectedAction(for: .readReplaySuccessIndex) != .failIO else {
            replaySuccessIndex = [:]
            return
        }
        guard
            let data = try? Data(contentsOf: replaySuccessIndexURL()),
            let persisted = try? JSONDecoder().decode([String: Date].self, from: data)
        else {
            replaySuccessIndex = [:]
            return
        }
        replaySuccessIndex = persisted
    }

    private func writeReplaySuccessIndex() {
        ensureDirectory()
        guard injectedAction(for: .writeReplaySuccessIndex) != .failIO else { return }
        guard let data = try? JSONEncoder().encode(replaySuccessIndex) else { return }
        try? data.write(to: replaySuccessIndexURL(), options: .atomic)
    }

    private func injectedAction(for point: DiskOfflineWriteStoreFaultPoint) -> DiskOfflineWriteStoreFaultAction {
        faultInjector?(point) ?? .proceed
    }

    private func injectedIOError() -> Error {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSLocalizedDescriptionKey: "fault_injected_io_error"
        ])
    }
}
