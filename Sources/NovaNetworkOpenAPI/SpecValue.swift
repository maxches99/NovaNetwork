import Foundation

/// An ordered key/value map read from a specification document.
///
/// Order is preserved so generated output follows the order of the source document rather than the
/// iteration order of a `Dictionary`, which would differ between runs and make generated files
/// churn for no reason.
public struct SpecObject: Sendable, Equatable {
    /// Keys in document order.
    public private(set) var keys: [String] = []
    private var values: [String: SpecValue] = [:]

    /// Creates an empty object.
    public init() {}

    /// Creates an object from key/value pairs in order. Later duplicates replace earlier values.
    public init(_ pairs: [(String, SpecValue)]) {
        for (key, value) in pairs {
            self[key] = value
        }
    }

    /// Reads or writes a value, appending new keys at the end.
    public subscript(key: String) -> SpecValue? {
        get { values[key] }
        set {
            guard let newValue else {
                keys.removeAll { $0 == key }
                values[key] = nil
                return
            }
            if values[key] == nil {
                keys.append(key)
            }
            values[key] = newValue
        }
    }

    /// The key/value pairs in document order.
    public var pairs: [(key: String, value: SpecValue)] {
        keys.compactMap { key in values[key].map { (key, $0) } }
    }

    /// Whether the object has no entries.
    public var isEmpty: Bool { keys.isEmpty }
}

/// A value from a JSON or YAML specification document.
///
/// The reader works against this rather than `Decodable` because OpenAPI's shape varies by version
/// and by vendor extension, and because a located, human-readable error beats a `DecodingError`
/// when someone's spec has a typo.
public indirect enum SpecValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([SpecValue])
    case object(SpecObject)

    /// The value for a key, or `nil` for non-objects and absent keys.
    public subscript(key: String) -> SpecValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    /// The string contents, or `nil` for other cases.
    public var stringValue: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    /// The boolean contents, or `nil` for other cases.
    public var boolValue: Bool? {
        guard case let .bool(value) = self else { return nil }
        return value
    }

    /// The numeric contents as an integer, when the value is a whole number.
    public var intValue: Int? {
        guard case let .number(value) = self, value == value.rounded(), value.magnitude < Double(Int.max) else {
            return nil
        }
        return Int(value)
    }

    /// The numeric contents, or `nil` for other cases.
    public var doubleValue: Double? {
        guard case let .number(value) = self else { return nil }
        return value
    }

    /// The array elements, or `nil` for other cases.
    public var arrayValue: [SpecValue]? {
        guard case let .array(values) = self else { return nil }
        return values
    }

    /// The object contents, or `nil` for other cases.
    public var objectValue: SpecObject? {
        guard case let .object(object) = self else { return nil }
        return object
    }

    /// Whether the value is explicitly null.
    public var isNull: Bool { self == .null }
}
