import Foundation

/// A recorded HTTP body.
///
/// Text that decodes as UTF-8 is stored as text so a cassette reads like the payload it captured;
/// anything else is stored base64. The distinction is a storage detail — ``data`` always returns the
/// exact bytes that were recorded.
public struct RecordedBody: Sendable, Equatable {
    /// The recorded bytes.
    public let data: Data

    /// Wraps bytes for recording.
    public init(data: Data) {
        self.data = data
    }

    /// The bytes decoded as UTF-8, when they are valid UTF-8.
    public var text: String? {
        String(data: data, encoding: .utf8)
    }
}

extension RecordedBody: Codable {
    private enum CodingKeys: String, CodingKey {
        case text
        case base64
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            data = Data(text.utf8)
            return
        }
        guard let base64 = try container.decodeIfPresent(String.self, forKey: .base64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .text,
                in: container,
                debugDescription: "A recorded body needs either 'text' or 'base64'."
            )
        }
        guard let decoded = Data(base64Encoded: base64) else {
            throw DecodingError.dataCorruptedError(
                forKey: .base64,
                in: container,
                debugDescription: "'base64' is not valid base64."
            )
        }
        data = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if let text {
            try container.encode(text, forKey: .text)
        } else {
            try container.encode(data.base64EncodedString(), forKey: .base64)
        }
    }
}

/// The request half of a recorded exchange.
public struct RecordedRequest: Sendable, Equatable, Codable {
    /// HTTP method, as written on the wire.
    public let method: String
    /// Absolute URL including query items.
    public let url: String
    /// Request headers after redaction.
    public let headers: [String: String]
    /// Request body after redaction, when there was one.
    public let body: RecordedBody?

    /// Creates a recorded request.
    public init(method: String, url: String, headers: [String: String] = [:], body: RecordedBody? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// The response half of a recorded exchange.
public struct RecordedResponse: Sendable, Equatable, Codable {
    /// HTTP status code.
    public let status: Int
    /// Response headers after redaction.
    public let headers: [String: String]
    /// Response body after redaction, when there was one.
    public let body: RecordedBody?

    /// Creates a recorded response.
    public init(status: Int, headers: [String: String] = [:], body: RecordedBody? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// One recorded request and the response it produced.
public struct RecordedInteraction: Sendable, Equatable, Codable {
    /// The request as sent, after redaction.
    public let request: RecordedRequest
    /// The response as received, after redaction.
    public let response: RecordedResponse

    /// Creates an interaction.
    public init(request: RecordedRequest, response: RecordedResponse) {
        self.request = request
        self.response = response
    }
}

/// An ordered recording of HTTP exchanges, persisted as reviewable JSON.
///
/// A cassette is a fixture with the fidelity of the real server: the header casing, the null field,
/// and the error envelope are whatever the service actually sent. It is meant to be committed and
/// read in review, which is why the format is pretty-printed, key-sorted, and free of timestamps —
/// re-saving an unchanged recording produces identical bytes.
public struct Cassette: Sendable, Equatable, Codable {
    /// The format version this build writes and can read.
    public static let currentFormatVersion = 1

    /// The format version of this cassette.
    public var formatVersion: Int
    /// Recorded exchanges, in the order they happened.
    public var interactions: [RecordedInteraction]

    private enum CodingKeys: String, CodingKey {
        case formatVersion = "version"
        case interactions
    }

    /// Creates a cassette, empty by default.
    public init(interactions: [RecordedInteraction] = []) {
        formatVersion = Self.currentFormatVersion
        self.interactions = interactions
    }

    /// Reads a cassette from disk.
    ///
    /// - Throws: ``CassetteError/fileNotFound(path:)`` when the file is absent,
    ///   ``CassetteError/malformedFile(path:reason:)`` when it cannot be decoded, and
    ///   ``CassetteError/unsupportedFormatVersion(found:supported:path:)`` when it was written by a
    ///   newer format.
    public static func load(from url: URL) throws -> Cassette {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CassetteError.fileNotFound(path: url.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CassetteError.malformedFile(path: url.path, reason: error.localizedDescription)
        }

        let cassette: Cassette
        do {
            cassette = try JSONDecoder().decode(Cassette.self, from: data)
        } catch {
            throw CassetteError.malformedFile(path: url.path, reason: "\(error)")
        }

        guard cassette.formatVersion <= Self.currentFormatVersion else {
            throw CassetteError.unsupportedFormatVersion(
                found: cassette.formatVersion,
                supported: Self.currentFormatVersion,
                path: url.path
            )
        }
        return cassette
    }

    /// Serializes the cassette deterministically.
    ///
    /// Pretty-printed with sorted keys and unescaped slashes, so the file reads like the payloads it
    /// holds and two saves of the same recording produce identical bytes.
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// Writes the cassette atomically, creating intermediate directories as needed.
    public func write(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try serialized().write(to: url, options: .atomic)
    }
}
