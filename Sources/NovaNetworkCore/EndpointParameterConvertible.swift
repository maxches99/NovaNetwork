import Foundation

/// A value that can be serialized into a path segment, query item, or header field.
///
/// Conformances describe how one Swift value becomes zero, one, or many wire strings. The three
/// shapes that matter are:
///
/// - a scalar contributes exactly one string;
/// - `nil` contributes none, which is how optional parameters are omitted rather than serialized
///   as the text `"nil"`;
/// - a collection contributes one string per element, which the query style then joins or repeats.
///
/// The library conforms the common scalar types, `Optional`, and `Array`. Enums with a raw value
/// only need to declare the conformance:
///
/// ```swift
/// enum SortOrder: String, EndpointParameterConvertible {
///     case ascending, descending
/// }
/// ```
public protocol EndpointParameterConvertible: Sendable {
    /// The wire strings this value contributes to a request.
    ///
    /// An empty array means the parameter is omitted entirely.
    var endpointParameterStrings: [String] { get }
}

// MARK: - Scalars

public extension EndpointParameterConvertible where Self: LosslessStringConvertible {
    /// Serializes the value through its `String` description.
    var endpointParameterStrings: [String] { [String(self)] }
}

extension String: EndpointParameterConvertible {
    /// Serializes the string as itself.
    public var endpointParameterStrings: [String] { [self] }
}

extension Substring: EndpointParameterConvertible {
    /// Serializes the substring as a `String`.
    public var endpointParameterStrings: [String] { [String(self)] }
}

extension Bool: EndpointParameterConvertible {
    /// Serializes as `true` or `false`, the spelling every HTTP API expects.
    public var endpointParameterStrings: [String] { [self ? "true" : "false"] }
}

extension Int: EndpointParameterConvertible {}
extension Int8: EndpointParameterConvertible {}
extension Int16: EndpointParameterConvertible {}
extension Int32: EndpointParameterConvertible {}
extension Int64: EndpointParameterConvertible {}
extension UInt: EndpointParameterConvertible {}
extension UInt8: EndpointParameterConvertible {}
extension UInt16: EndpointParameterConvertible {}
extension UInt32: EndpointParameterConvertible {}
extension UInt64: EndpointParameterConvertible {}
extension Double: EndpointParameterConvertible {}
extension Float: EndpointParameterConvertible {}

extension UUID: EndpointParameterConvertible {
    /// Serializes as the canonical uppercase UUID string.
    public var endpointParameterStrings: [String] { [uuidString] }
}

extension URL: EndpointParameterConvertible {
    /// Serializes as the absolute URL string.
    public var endpointParameterStrings: [String] { [absoluteString] }
}

extension Date: EndpointParameterConvertible {
    /// Serializes as an RFC 3339 / ISO 8601 timestamp in UTC, for example `2026-08-24T09:41:00Z`.
    ///
    /// This matches OpenAPI's `format: date-time` and the `JSONDecoder.DateDecodingStrategy.iso8601`
    /// strategy used by generated decoders, so a date sent as a parameter and a date decoded from a
    /// response body agree on their representation.
    public var endpointParameterStrings: [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return [formatter.string(from: self)]
    }
}

// MARK: - Raw representable

public extension RawRepresentable where Self: EndpointParameterConvertible, RawValue: EndpointParameterConvertible {
    /// Serializes through the raw value, so `enum Sort: String` needs no further implementation.
    var endpointParameterStrings: [String] { rawValue.endpointParameterStrings }
}

// MARK: - Containers

extension Optional: EndpointParameterConvertible where Wrapped: EndpointParameterConvertible {
    /// Serializes the wrapped value, or contributes nothing when `nil`.
    public var endpointParameterStrings: [String] {
        switch self {
        case .none: []
        case let .some(wrapped): wrapped.endpointParameterStrings
        }
    }
}

extension Array: EndpointParameterConvertible where Element: EndpointParameterConvertible {
    /// Serializes every element in order; the query style decides whether they repeat or join.
    public var endpointParameterStrings: [String] {
        flatMap(\.endpointParameterStrings)
    }
}

// MARK: - Query style

/// How a multi-valued parameter is written into a query string.
///
/// The cases mirror OpenAPI's `style` and `explode` combinations for `form` parameters.
public enum EndpointQueryStyle: String, Sendable, Hashable, CaseIterable {
    /// One query item per value: `?tag=swift&tag=http`. The default, and OpenAPI's `explode: true`.
    case repeated
    /// A single comma-joined item: `?tag=swift,http`. OpenAPI's `explode: false`.
    case commaSeparated
    /// A single space-joined item: `?tag=swift%20http`. OpenAPI's `spaceDelimited`.
    case spaceDelimited
    /// A single pipe-joined item: `?tag=swift|http`. OpenAPI's `pipeDelimited`.
    case pipeDelimited

    /// The separator used by the joining styles, or `nil` for ``repeated``.
    var separator: String? {
        switch self {
        case .repeated: nil
        case .commaSeparated: ","
        case .spaceDelimited: " "
        case .pipeDelimited: "|"
        }
    }

    /// Converts serialized parameter strings into query items under `name`.
    func queryItems(name: String, values: [String]) -> [URLQueryItem] {
        guard !values.isEmpty else { return [] }
        guard let separator else {
            return values.map { URLQueryItem(name: name, value: $0) }
        }
        return [URLQueryItem(name: name, value: values.joined(separator: separator))]
    }
}
