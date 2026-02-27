import Foundation

public actor DiskOfflineWriteStore: OfflineWriteStore {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let maxEntries: Int?
    private let ttlSeconds: TimeInterval?
    private let overflowPolicy: OfflineWriteStoreOverflowPolicy
    private let schemaVersion: Int

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maxEntries: Int? = nil,
        ttlSeconds: TimeInterval? = nil,
        overflowPolicy: OfflineWriteStoreOverflowPolicy = .evictOldest,
        schemaVersion: Int = 1
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxEntries = maxEntries.map { max(1, $0) }
        self.ttlSeconds = ttlSeconds.map { max(0, $0) }
        self.overflowPolicy = overflowPolicy
        self.schemaVersion = max(1, schemaVersion)
    }

    @discardableResult
    public func enqueue(request: APIRequest, requestKey: String, now: Date = Date()) async throws -> QueuedWriteReceipt {
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
            updatedAt: now
        )
        write(entry)
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
                case .replaying, .deadLetter:
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
                updatedAt: now
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
                updatedAt: now
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
                updatedAt: now
            )
        }
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
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(forQueueID queueID: String) -> URL {
        directoryURL.appendingPathComponent("\(queueID).json")
    }

    private func entryFileURLs() -> [URL] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return files.filter { $0.pathExtension == "json" }
    }

    private func loadEntries() async -> [OfflineWriteStoreEntry] {
        ensureDirectory()
        var entries: [OfflineWriteStoreEntry] = []
        for file in entryFileURLs() {
            guard
                let data = try? Data(contentsOf: file),
                let envelope = try? JSONDecoder().decode(PersistedOfflineWriteEnvelope.self, from: data),
                envelope.schemaVersion == schemaVersion,
                let entry = envelope.entry.toRuntimeEntry()
            else {
                // Corrupted or unknown schema entries are skipped and removed.
                try? fileManager.removeItem(at: file)
                continue
            }

            entries.append(entry)
        }
        return entries
    }

    private func write(_ entry: OfflineWriteStoreEntry) {
        ensureDirectory()
        let envelope = PersistedOfflineWriteEnvelope(
            schemaVersion: schemaVersion,
            entry: PersistedOfflineWriteEntry(from: entry)
        )
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: fileURL(forQueueID: entry.receipt.queueID), options: .atomic)
    }

    private func mutate(queueID: String, transform: (OfflineWriteStoreEntry) -> OfflineWriteStoreEntry) async {
        guard let current = await loadEntry(queueID: queueID) else { return }
        write(transform(current))
    }

    private func loadEntry(queueID: String) async -> OfflineWriteStoreEntry? {
        let fileURL = fileURL(forQueueID: queueID)
        guard
            let data = try? Data(contentsOf: fileURL),
            let envelope = try? JSONDecoder().decode(PersistedOfflineWriteEnvelope.self, from: data),
            envelope.schemaVersion == schemaVersion,
            let entry = envelope.entry.toRuntimeEntry()
        else {
            try? fileManager.removeItem(at: fileURL)
            return nil
        }
        return entry
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
}
