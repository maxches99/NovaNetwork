import Foundation

public actor MemoryResponseCache: ResponseCache {
    public typealias Entry = CachedResponse

    private var storage: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries: Int?

    public init(maxEntries: Int?) {
        self.maxEntries = maxEntries.map { max(1, $0) }
    }

    public func entry(forKey key: String) -> Entry? {
        storage[key]
    }

    public func set(_ response: Entry, forKey key: String) {
        if storage[key] == nil {
            insertionOrder.append(key)
        }

        storage[key] = response
        enforceCapacityIfNeeded()
    }

    public func remove(key: String) {
        storage[key] = nil
        insertionOrder.removeAll { $0 == key }
    }

    public func removeAll() {
        storage.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    public func removeAll(where shouldRemove: @escaping @Sendable (String) -> Bool) {
        let keys = storage.keys.filter(shouldRemove)
        for key in keys {
            storage[key] = nil
        }
        if !keys.isEmpty {
            let keySet = Set(keys)
            insertionOrder.removeAll { keySet.contains($0) }
        }
    }

    private func enforceCapacityIfNeeded() {
        guard let maxEntries else { return }
        while storage.count > maxEntries, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            storage[oldest] = nil
        }
    }
}
