import Foundation

/// Decodes response bytes into a typed value, with the freedom to pick a decoding strategy per
/// response — for example, based on its `Content-Type` header.
///
/// This exists alongside, not instead of, `NetworkClient`'s `Decodable`/`JSONDecoder`-based
/// `load` overloads and `Endpoint.decode(_:using:)`: those remain the default, unconstrained
/// path for a single decoder and JSON body. Use ``ResponseDecoding`` when a client needs to pick
/// between multiple decoding strategies at runtime, most commonly by response content type.
public protocol ResponseDecoding: Sendable {
    /// Decodes `response`'s body into `type`.
    ///
    /// - Throws: A decoding-specific error, which callers map to
    ///   ``NetworkError/decoding(underlying:)``.
    func decode<T: Decodable & Sendable>(_ type: T.Type, from response: NetworkResponse) throws -> T
}

/// Decodes every response as JSON via a fixed `JSONDecoder`.
///
/// This is the default strategy, matching `NetworkClient`'s existing `Decodable`/`JSONDecoder`
/// behavior when no other ``ResponseDecoding`` is configured.
public struct JSONResponseDecoding: ResponseDecoding {
    /// The decoder applied to every response body.
    public let decoder: JSONDecoder

    /// Creates a JSON response decoding strategy.
    public init(decoder: JSONDecoder = JSONDecoder()) {
        self.decoder = decoder
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from response: NetworkResponse) throws -> T {
        try decoder.decode(T.self, from: response.body)
    }
}

/// Selects a ``ResponseDecoding`` strategy by the response's `Content-Type` header, falling back
/// to a default strategy when the header is absent or has no registered match.
///
/// Media type matching ignores parameters (for example `application/json; charset=utf-8`
/// matches a registration for `"application/json"`) and is case-insensitive.
public struct ContentTypeNegotiatingResponseDecoding: ResponseDecoding {
    /// Decoding strategies keyed by normalized (lowercased, parameter-free) media type.
    public var decodersByMediaType: [String: any ResponseDecoding]
    /// The strategy used when the response's media type has no registered match.
    public var fallback: any ResponseDecoding

    /// Creates a content-type negotiating decoding strategy.
    ///
    /// - Parameters:
    ///   - decodersByMediaType: Strategies keyed by media type, for example `"application/json"`
    ///     or `"application/xml"`. Keys are normalized on insertion, so case and whitespace do
    ///     not matter.
    ///   - fallback: The strategy used when the response's media type is absent or unregistered.
    ///     Defaults to ``JSONResponseDecoding``.
    public init(
        decodersByMediaType: [String: any ResponseDecoding] = [:],
        fallback: any ResponseDecoding = JSONResponseDecoding()
    ) {
        self.decodersByMediaType = Dictionary(
            uniqueKeysWithValues: decodersByMediaType.map { (Self.normalizedMediaType($0.key), $0.value) }
        )
        self.fallback = fallback
    }

    public func decode<T: Decodable & Sendable>(_ type: T.Type, from response: NetworkResponse) throws -> T {
        let decoding = Self.mediaType(fromContentTypeHeader: response.headers)
            .flatMap { decodersByMediaType[$0] } ?? fallback
        return try decoding.decode(T.self, from: response)
    }

    /// Extracts and normalizes the media type from a `Content-Type` header value, ignoring
    /// parameters such as `charset`.
    static func mediaType(fromContentTypeHeader headers: [String: String]) -> String? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value else {
            return nil
        }
        let mediaTypePart = value.split(separator: ";", maxSplits: 1).first.map(String.init) ?? value
        return normalizedMediaType(mediaTypePart)
    }

    static func normalizedMediaType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
