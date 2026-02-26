import Foundation

actor MemoryResponseCache {
    struct Entry: Sendable {
        let data: Data
        let storedAtNanoseconds: UInt64
    }

    private var storage: [String: Entry] = [:]
    private var insertionOrder: [String] = []
    private let maxEntries: Int?

    init(maxEntries: Int?) {
        self.maxEntries = maxEntries.map { max(1, $0) }
    }

    func entry(forKey key: String) -> Entry? {
        storage[key]
    }

    func set(_ data: Data, forKey key: String) {
        if storage[key] == nil {
            insertionOrder.append(key)
        }

        storage[key] = Entry(data: data, storedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
        enforceCapacityIfNeeded()
    }

    func remove(key: String) {
        storage[key] = nil
        insertionOrder.removeAll { $0 == key }
    }

    func removeAll() {
        storage.removeAll(keepingCapacity: false)
        insertionOrder.removeAll(keepingCapacity: false)
    }

    func removeAll(where shouldRemove: @Sendable (String) -> Bool) {
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
