import NovaNetworkCore
import Foundation

/// Server-specific contract used by managed uploads to create, inspect, and append resources.
public protocol ResumableUploadStrategy: Sendable {
    /// Creates a server-side upload resource and returns its absolute URL.
    func createUpload(for request: APIRequest, totalBytes: Int64) async throws -> URL

    /// Returns the server-confirmed byte offset for an existing upload resource.
    func offset(for uploadURL: URL, request: APIRequest) async throws -> Int64

    /// Appends a chunk at an exact offset and returns the newly confirmed server offset.
    func append(
        _ chunk: Data,
        to uploadURL: URL,
        at offset: Int64,
        request: APIRequest
    ) async throws -> Int64
}

/// TUS 1.0 offset-based resumable upload strategy backed by URLSession.
///
/// The strategy forwards live request headers for authentication but returns only the upload URL
/// and byte offset to persistence. Callers should use TLS and a TUS server whose upload URLs are
/// safe to retain in the app's private journal.
public struct TUSResumableUploadStrategy: ResumableUploadStrategy {
    private let session: URLSession

    /// Creates a TUS strategy backed by a URL session.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Creates a TUS resource using `POST`, `Tus-Resumable`, and `Upload-Length`.
    public func createUpload(for request: APIRequest, totalBytes: Int64) async throws -> URL {
        guard totalBytes >= 0 else { throw ManagedTransferError.invalidUploadOffset }
        var urlRequest = request.urlRequest()
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = nil
        urlRequest.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        urlRequest.setValue(String(totalBytes), forHTTPHeaderField: "Upload-Length")
        let (data, response) = try await session.data(for: urlRequest)
        let metadata = try Self.validate(response: response, data: data, accepted: [201])
        guard
            let location = Self.header("Location", in: metadata.headers),
            let resolved = URL(string: location, relativeTo: response.url)?.absoluteURL
        else {
            throw ManagedTransferError.resumableUploadUnsupported
        }
        return resolved
    }

    /// Queries a TUS resource using `HEAD` and parses `Upload-Offset`.
    public func offset(for uploadURL: URL, request: APIRequest) async throws -> Int64 {
        var urlRequest = Self.request(for: uploadURL, inheriting: request)
        urlRequest.httpMethod = "HEAD"
        urlRequest.httpBody = nil
        urlRequest.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        let (data, response) = try await session.data(for: urlRequest)
        let metadata = try Self.validate(response: response, data: data, accepted: [200, 204])
        return try Self.uploadOffset(in: metadata.headers)
    }

    /// Appends a TUS chunk using `PATCH` and validates the acknowledged offset.
    public func append(
        _ chunk: Data,
        to uploadURL: URL,
        at offset: Int64,
        request: APIRequest
    ) async throws -> Int64 {
        guard offset >= 0 else { throw ManagedTransferError.invalidUploadOffset }
        var urlRequest = Self.request(for: uploadURL, inheriting: request)
        urlRequest.httpMethod = "PATCH"
        urlRequest.httpBody = chunk
        urlRequest.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        urlRequest.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        urlRequest.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.data(for: urlRequest)
        let metadata = try Self.validate(response: response, data: data, accepted: [204])
        let confirmed = try Self.uploadOffset(in: metadata.headers)
        guard confirmed == offset + Int64(chunk.count) else {
            throw ManagedTransferError.invalidUploadOffset
        }
        return confirmed
    }
}

private extension TUSResumableUploadStrategy {
    struct Metadata {
        let headers: [String: String]
    }

    static func request(for url: URL, inheriting request: APIRequest) -> URLRequest {
        var result = URLRequest(url: url, timeoutInterval: request.timeout)
        for (name, value) in request.headers {
            result.setValue(value, forHTTPHeaderField: name)
        }
        return result
    }

    static func validate(
        response: URLResponse,
        data: Data,
        accepted: Set<Int>
    ) throws -> Metadata {
        guard let http = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, item in
            guard let name = item.key as? String else { return }
            result[name] = String(describing: item.value)
        }
        guard accepted.contains(http.statusCode) else {
            if http.statusCode == 412 || http.statusCode == 415 {
                throw ManagedTransferError.resumableUploadUnsupported
            }
            throw NetworkError.httpStatus(code: http.statusCode, headers: headers, body: data)
        }
        guard header("Tus-Resumable", in: headers) == "1.0.0" else {
            throw ManagedTransferError.resumableUploadUnsupported
        }
        return Metadata(headers: headers)
    }

    static func uploadOffset(in headers: [String: String]) throws -> Int64 {
        guard
            let rawValue = header("Upload-Offset", in: headers),
            let value = Int64(rawValue),
            value >= 0
        else {
            throw ManagedTransferError.invalidUploadOffset
        }
        return value
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
