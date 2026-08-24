import NovaNetworkCore
import Foundation

/// One part of a `multipart/form-data` request body.
public struct MultipartFormDataPart: Sendable {
    enum Content: Sendable {
        case data(Data)
        case file(URL)
    }

    /// The part's `Content-Disposition` field name.
    public let name: String
    /// The part's `Content-Disposition` filename, if any.
    public let filename: String?
    /// The part's `Content-Type` header value, if any.
    public let contentType: String?
    let content: Content

    private init(name: String, filename: String?, contentType: String?, content: Content) {
        self.name = name
        self.filename = filename
        self.contentType = contentType
        self.content = content
    }

    /// A plain text field with no filename or content type.
    public static func text(name: String, value: String) -> MultipartFormDataPart {
        MultipartFormDataPart(name: name, filename: nil, contentType: nil, content: .data(Data(value.utf8)))
    }

    /// A small in-memory field, such as a JSON attachment.
    public static func data(
        name: String,
        filename: String? = nil,
        contentType: String? = nil,
        data: Data
    ) -> MultipartFormDataPart {
        MultipartFormDataPart(name: name, filename: filename, contentType: contentType, content: .data(data))
    }

    /// A file field streamed from disk; its contents are never fully loaded into memory.
    public static func file(
        name: String,
        filename: String,
        contentType: String? = nil,
        fileURL: URL
    ) -> MultipartFormDataPart {
        MultipartFormDataPart(name: name, filename: filename, contentType: contentType, content: .file(fileURL))
    }
}

/// Errors raised while encoding a ``MultipartFormDataPart`` array.
public enum MultipartFormDataError: Error, Sendable, Equatable {
    /// A `.file` part's source could not be opened for reading or its size could not be read.
    case sourceFileUnreadable(URL)
    /// The destination file could not be created or written to.
    case destinationUnwritable(URL)
}

/// Encodes a `multipart/form-data` body, streaming file parts to (or from) disk in fixed-size
/// chunks so their contents are never fully buffered in memory regardless of file size.
public struct MultipartFormDataEncoder: Sendable {
    /// The multipart boundary token used to separate parts.
    public let boundary: String
    private let parts: [MultipartFormDataPart]

    /// Creates an encoder for the supplied parts.
    ///
    /// - Parameter boundary: A custom boundary token, or `nil` to generate a random one.
    public init(parts: [MultipartFormDataPart], boundary: String? = nil) {
        self.parts = parts
        self.boundary = boundary ?? "NovaNetworkBoundary-\(UUID().uuidString)"
    }

    /// The `Content-Type` header value for a request carrying this encoded body.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Computes the exact encoded byte length without writing the body.
    ///
    /// File part sizes are read from filesystem metadata; file contents are not read.
    public func contentLength() throws -> Int64 {
        var total: Int64 = 0
        for part in parts {
            total += Int64(Self.boundaryPrefix(boundary).utf8.count)
            total += Int64(Self.headerData(for: part).count)
            switch part.content {
            case .data(let data):
                total += Int64(data.count)
            case .file(let fileURL):
                total += try Self.fileSize(at: fileURL)
            }
            total += 2 // trailing CRLF after each part's content
        }
        total += Int64(Self.finalBoundary(boundary).utf8.count)
        return total
    }

    /// Streams the encoded body to `destinationURL`, creating or replacing the file.
    ///
    /// File parts are copied in fixed-size chunks read directly from disk; their contents are
    /// never loaded into memory all at once, regardless of file size.
    ///
    /// - Returns: The total number of bytes written.
    @discardableResult
    public func write(to destinationURL: URL) throws -> Int64 {
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw MultipartFormDataError.destinationUnwritable(destinationURL)
        }
        guard let output = FileHandle(forWritingAtPath: destinationURL.path) else {
            throw MultipartFormDataError.destinationUnwritable(destinationURL)
        }
        defer { try? output.close() }

        var totalBytes: Int64 = 0
        for part in parts {
            try Self.writeChecked(Data(Self.boundaryPrefix(boundary).utf8), to: output, destinationURL: destinationURL)
            totalBytes += Int64(Self.boundaryPrefix(boundary).utf8.count)

            let header = Self.headerData(for: part)
            try Self.writeChecked(header, to: output, destinationURL: destinationURL)
            totalBytes += Int64(header.count)

            switch part.content {
            case .data(let data):
                try Self.writeChecked(data, to: output, destinationURL: destinationURL)
                totalBytes += Int64(data.count)
            case .file(let fileURL):
                totalBytes += try Self.streamFile(at: fileURL, into: output, destinationURL: destinationURL)
            }

            try Self.writeChecked(Data("\r\n".utf8), to: output, destinationURL: destinationURL)
            totalBytes += 2
        }

        let final = Data(Self.finalBoundary(boundary).utf8)
        try Self.writeChecked(final, to: output, destinationURL: destinationURL)
        totalBytes += Int64(final.count)
        return totalBytes
    }

    private static func boundaryPrefix(_ boundary: String) -> String { "--\(boundary)\r\n" }
    private static func finalBoundary(_ boundary: String) -> String { "--\(boundary)--\r\n" }

    private static func headerData(for part: MultipartFormDataPart) -> Data {
        var header = "Content-Disposition: form-data; name=\"\(escapeHeaderValue(part.name))\""
        if let filename = part.filename {
            header += "; filename=\"\(escapeHeaderValue(filename))\""
        }
        header += "\r\n"
        if let contentType = part.contentType {
            header += "Content-Type: \(sanitizeHeaderLine(contentType))\r\n"
        }
        header += "\r\n"
        return Data(header.utf8)
    }

    /// Percent-escapes quotes and strips CR/LF from a quoted `Content-Disposition` parameter,
    /// preventing a caller-supplied name or filename from injecting extra multipart headers.
    private static func escapeHeaderValue(_ value: String) -> String {
        sanitizeHeaderLine(value).replacingOccurrences(of: "\"", with: "%22")
    }

    /// Strips CR/LF from a single-line header value.
    private static func sanitizeHeaderLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
    }

    private static func fileSize(at fileURL: URL) throws -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            throw MultipartFormDataError.sourceFileUnreadable(fileURL)
        }
        return size
    }

    private static func streamFile(at fileURL: URL, into output: FileHandle, destinationURL: URL) throws -> Int64 {
        guard let input = FileHandle(forReadingAtPath: fileURL.path) else {
            throw MultipartFormDataError.sourceFileUnreadable(fileURL)
        }
        defer { try? input.close() }

        var totalBytes: Int64 = 0
        while true {
            let chunk = input.readData(ofLength: 65_536)
            if chunk.isEmpty { break }
            try writeChecked(chunk, to: output, destinationURL: destinationURL)
            totalBytes += Int64(chunk.count)
        }
        return totalBytes
    }

    private static func writeChecked(_ data: Data, to handle: FileHandle, destinationURL: URL) throws {
        if #available(iOS 13.4, macOS 10.15.4, watchOS 6.2, tvOS 13.4, *) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                throw MultipartFormDataError.destinationUnwritable(destinationURL)
            }
        } else {
            handle.write(data)
        }
    }
}
