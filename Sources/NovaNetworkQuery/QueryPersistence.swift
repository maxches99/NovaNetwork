import Foundation

/// One query's value as it sits in a ``QueryPersistenceStore``.
public struct PersistedQueryRecord: Codable, Sendable, Equatable {
    /// The key's components, stored so a store that hashes keys can rule out a collision.
    public let key: [String]
    /// The fully qualified name of the value's type, as `String(reflecting:)` prints it.
    public let typeName: String
    /// The ``QueryPersistence/version`` the record was written under.
    public let version: Int
    /// When the value was fetched or set; a restored value is this old.
    public let savedAt: Date
    /// The value, JSON-encoded.
    public let payload: Data

    /// Creates a record.
    public init(key: [String], typeName: String, version: Int, savedAt: Date, payload: Data) {
        self.key = key
        self.typeName = typeName
        self.version = version
        self.savedAt = savedAt
        self.payload = payload
    }
}

/// Where a ``QueryClient`` keeps values between launches.
///
/// Implement it to put the cache somewhere else — an encrypted file, a shared container, a database.
/// Calls from one client arrive one at a time, in the order the client made them.
public protocol QueryPersistenceStore: Sendable {
    /// The record for a key, or `nil` when there is none.
    func record(for key: QueryKey) async throws -> PersistedQueryRecord?
    /// Stores a record, replacing any record for the same key.
    func save(_ record: PersistedQueryRecord, for key: QueryKey) async throws
    /// Removes the record for a key, if there is one.
    func remove(_ key: QueryKey) async throws
    /// Removes every record.
    func removeAll() async throws
}

/// What happened when the query layer read from or wrote to its store.
public enum QueryPersistenceEvent: Sendable, Equatable {
    /// Why a stored record was not used.
    public enum DiscardReason: String, Sendable, Equatable {
        /// Written under another ``QueryPersistence/version``.
        case versionMismatch = "version_mismatch"
        /// Written for another value type.
        case typeMismatch = "type_mismatch"
        /// Older than ``QueryPersistence/maximumAge``.
        case expired
        /// The store could not be read, or the payload could not be decoded.
        case unreadable
    }

    /// A stored value was put back in the cache, `age` seconds after it was saved.
    case restored(key: QueryKey, age: TimeInterval)
    /// A stored record was thrown away instead of used.
    case discarded(key: QueryKey, reason: DiscardReason)
    /// The store refused a write. The in-memory value is unaffected.
    case writeFailed(key: QueryKey)
}

/// How a ``QueryClient`` keeps values across launches.
///
/// Only queries read through ``QueryClient/persistedValue(for:staleTime:fetch:)`` are written: a
/// cache on disk outlives the session that filled it, so persisting is a decision per query.
///
/// ```swift
/// let queries = QueryClient(
///     persistence: QueryPersistence(store: try FileQueryPersistenceStore.inCachesDirectory())
/// )
/// let feed: Feed = try await queries.persistedValue(for: "feed") { try await api.feed() }
///
/// // On sign-out:
/// await queries.removeAll()   // also empties the store
/// ```
public struct QueryPersistence: Sendable {
    /// Where records live.
    public let store: any QueryPersistenceStore
    /// The schema version. Records written under another version are discarded, so bumping it
    /// after a model change invalidates every stored value at once.
    public let version: Int
    /// Records older than this are discarded rather than shown.
    public let maximumAge: TimeInterval
    /// Receives restore, discard, and write-failure events.
    public let onEvent: (@Sendable (QueryPersistenceEvent) -> Void)?

    /// Creates a persistence configuration.
    ///
    /// - Parameters:
    ///   - store: Where records live.
    ///   - version: The schema version. Defaults to `1`.
    ///   - maximumAge: The oldest record worth showing. Defaults to seven days.
    ///   - onEvent: Receives restore, discard, and write-failure events.
    public init(
        store: any QueryPersistenceStore,
        version: Int = 1,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60,
        onEvent: (@Sendable (QueryPersistenceEvent) -> Void)? = nil
    ) {
        self.store = store
        self.version = version
        self.maximumAge = max(0, maximumAge)
        self.onEvent = onEvent
    }
}

/// Keeps records in memory, for previews, tests, and a store shared by two clients in one process.
public actor InMemoryQueryPersistenceStore: QueryPersistenceStore {
    private var records: [QueryKey: PersistedQueryRecord] = [:]

    /// Creates an empty store.
    public init() {}

    /// The record for a key, or `nil` when there is none.
    public func record(for key: QueryKey) -> PersistedQueryRecord? {
        records[key]
    }

    /// Stores a record, replacing any record for the same key.
    public func save(_ record: PersistedQueryRecord, for key: QueryKey) {
        records[key] = record
    }

    /// Removes the record for a key.
    public func remove(_ key: QueryKey) {
        records.removeValue(forKey: key)
    }

    /// Removes every record.
    public func removeAll() {
        records.removeAll()
    }

    /// How many records the store holds.
    public var count: Int {
        records.count
    }
}

/// Keeps one JSON file per key under a directory.
///
/// Files are written atomically, so a crash mid-write leaves the previous value rather than half of
/// a new one. File names are a hash of the key; the key itself is stored in the file, and a file
/// holding another key is treated as absent.
public struct FileQueryPersistenceStore: QueryPersistenceStore {
    /// The directory holding the files.
    public let directory: URL

    /// Creates a store, creating the directory if it does not exist.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A store in `Caches/<name>`, which the system may clear under storage pressure — the right
    /// place for a cache that can always be refetched.
    public static func inCachesDirectory(named name: String = "NovaNetworkQuery") throws -> FileQueryPersistenceStore {
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try FileQueryPersistenceStore(directory: caches.appendingPathComponent(name, isDirectory: true))
    }

    /// The record for a key, or `nil` when there is none or the file belongs to another key.
    public func record(for key: QueryKey) throws -> PersistedQueryRecord? {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record = try JSONDecoder().decode(PersistedQueryRecord.self, from: Data(contentsOf: url))
        return record.key == key.components ? record : nil
    }

    /// Writes a record atomically.
    public func save(_ record: PersistedQueryRecord, for key: QueryKey) throws {
        try JSONEncoder().encode(record).write(to: fileURL(for: key), options: .atomic)
    }

    /// Deletes the file for a key, if there is one.
    public func remove(_ key: QueryKey) throws {
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Deletes every file in the directory.
    public func removeAll() throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func fileURL(for key: QueryKey) -> URL {
        directory.appendingPathComponent(Self.fileName(for: key))
    }

    /// FNV-1a over the key's components. This module depends on Foundation alone, which has no
    /// portable SHA-256; a collision is harmless because the record carries its key.
    static func fileName(for key: QueryKey) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.components.joined(separator: "\u{1F}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex + ".json"
    }
}
