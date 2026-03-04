import Foundation

public actor DiskResponseCache: ResponseCache {
    public enum EvictionPolicy: Sendable {
        case leastRecentlyUsed
    }

    private struct Metadata: Codable {
        let key: String
        let statusCode: Int
        let headers: [String: String]
        let etag: String?
        let storedAtNanoseconds: UInt64
        let lastAccessedAtNanoseconds: UInt64
        let bodyBytes: Int
        let varyRequestHeaders: [String: String]
    }

    private let directoryURL: URL
    private let fileManager: FileManager
    private let maxBytes: Int?
    private let evictionPolicy: EvictionPolicy

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        maxBytes: Int? = nil,
        evictionPolicy: EvictionPolicy = .leastRecentlyUsed
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.maxBytes = maxBytes.map { max(1, $0) }
        self.evictionPolicy = evictionPolicy
    }

    public func entry(forKey key: String) async -> CachedResponse? {
        ensureDirectory()
        let paths = fileURLs(forKey: key)
        guard
            let metadataData = try? Data(contentsOf: paths.metadataURL),
            let body = try? Data(contentsOf: paths.bodyURL),
            let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData)
        else {
            return nil
        }

        let touched = Metadata(
            key: metadata.key,
            statusCode: metadata.statusCode,
            headers: metadata.headers,
            etag: metadata.etag,
            storedAtNanoseconds: metadata.storedAtNanoseconds,
            lastAccessedAtNanoseconds: DispatchTime.now().uptimeNanoseconds,
            bodyBytes: metadata.bodyBytes,
            varyRequestHeaders: metadata.varyRequestHeaders
        )
        if let touchedData = try? JSONEncoder().encode(touched) {
            try? touchedData.write(to: paths.metadataURL, options: .atomic)
        }

        return CachedResponse(
            body: body,
            statusCode: metadata.statusCode,
            headers: metadata.headers,
            etag: metadata.etag,
            storedAtNanoseconds: metadata.storedAtNanoseconds,
            lastAccessedAtNanoseconds: touched.lastAccessedAtNanoseconds,
            varyRequestHeaders: metadata.varyRequestHeaders
        )
    }

    public func set(_ response: CachedResponse, forKey key: String) async {
        ensureDirectory()
        let paths = fileURLs(forKey: key)
        let metadata = Metadata(
            key: key,
            statusCode: response.statusCode,
            headers: response.headers,
            etag: response.etag,
            storedAtNanoseconds: response.storedAtNanoseconds,
            lastAccessedAtNanoseconds: response.lastAccessedAtNanoseconds,
            bodyBytes: response.body.count,
            varyRequestHeaders: response.varyRequestHeaders
        )

        do {
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: paths.metadataURL, options: .atomic)
            try response.body.write(to: paths.bodyURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: paths.metadataURL)
            try? fileManager.removeItem(at: paths.bodyURL)
        }

        await enforceCapacityIfNeeded()
    }

    public func remove(key: String) async {
        let paths = fileURLs(forKey: key)
        try? fileManager.removeItem(at: paths.metadataURL)
        try? fileManager.removeItem(at: paths.bodyURL)
    }

    public func removeAll() async {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            try? fileManager.removeItem(at: file)
        }
    }

    public func removeAll(where shouldRemove: @escaping @Sendable (String) -> Bool) async {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let metadataFiles = files.filter { $0.pathExtension == "json" }
        for metadataURL in metadataFiles {
            guard
                let data = try? Data(contentsOf: metadataURL),
                let metadata = try? JSONDecoder().decode(Metadata.self, from: data),
                shouldRemove(metadata.key)
            else {
                continue
            }

            let bodyURL = metadataURL.deletingPathExtension().appendingPathExtension("bin")
            try? fileManager.removeItem(at: metadataURL)
            try? fileManager.removeItem(at: bodyURL)
        }
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    private func enforceCapacityIfNeeded() async {
        guard let maxBytes else { return }
        let entries = allMetadataEntries()
        var totalBytes = entries.reduce(0) { $0 + $1.metadata.bodyBytes }
        guard totalBytes > maxBytes else { return }

        let sorted: [(metadataURL: URL, metadata: Metadata)] = {
            switch evictionPolicy {
            case .leastRecentlyUsed:
                return entries.sorted { lhs, rhs in
                    if lhs.metadata.lastAccessedAtNanoseconds == rhs.metadata.lastAccessedAtNanoseconds {
                        return lhs.metadata.storedAtNanoseconds < rhs.metadata.storedAtNanoseconds
                    }
                    return lhs.metadata.lastAccessedAtNanoseconds < rhs.metadata.lastAccessedAtNanoseconds
                }
            }
        }()

        for entry in sorted {
            if totalBytes <= maxBytes { break }
            let bodyURL = entry.metadataURL.deletingPathExtension().appendingPathExtension("bin")
            try? fileManager.removeItem(at: entry.metadataURL)
            try? fileManager.removeItem(at: bodyURL)
            totalBytes -= entry.metadata.bodyBytes
        }
    }

    private func allMetadataEntries() -> [(metadataURL: URL, metadata: Metadata)] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        var entries: [(URL, Metadata)] = []
        for metadataURL in files where metadataURL.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: metadataURL),
                let metadata = try? JSONDecoder().decode(Metadata.self, from: data)
            else {
                continue
            }
            entries.append((metadataURL, metadata))
        }
        return entries
    }

    private func fileURLs(forKey key: String) -> (metadataURL: URL, bodyURL: URL) {
        let hashed = SHA256Util.hex(Data(key.utf8))
        let base = directoryURL.appendingPathComponent(hashed)
        return (
            metadataURL: base.appendingPathExtension("json"),
            bodyURL: base.appendingPathExtension("bin")
        )
    }
}
