import Foundation

public actor DiskResponseCache: ResponseCache {
    private struct Metadata: Codable {
        let key: String
        let statusCode: Int
        let headers: [String: String]
        let etag: String?
        let storedAtNanoseconds: UInt64
    }

    private let directoryURL: URL
    private let fileManager: FileManager

    public init(
        directoryURL: URL,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
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

        return CachedResponse(
            body: body,
            statusCode: metadata.statusCode,
            headers: metadata.headers,
            etag: metadata.etag,
            storedAtNanoseconds: metadata.storedAtNanoseconds
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
            storedAtNanoseconds: response.storedAtNanoseconds
        )

        do {
            let metadataData = try JSONEncoder().encode(metadata)
            try metadataData.write(to: paths.metadataURL, options: .atomic)
            try response.body.write(to: paths.bodyURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: paths.metadataURL)
            try? fileManager.removeItem(at: paths.bodyURL)
        }
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

    private func fileURLs(forKey key: String) -> (metadataURL: URL, bodyURL: URL) {
        let hashed = SHA256Util.hex(Data(key.utf8))
        let base = directoryURL.appendingPathComponent(hashed)
        return (
            metadataURL: base.appendingPathExtension("json"),
            bodyURL: base.appendingPathExtension("bin")
        )
    }
}
