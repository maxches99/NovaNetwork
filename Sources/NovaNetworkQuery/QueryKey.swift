import Foundation

/// The identity of a cached query.
///
/// Keys are hierarchical so a mutation can invalidate a family of them at once: writing a user
/// invalidates `["users", "1"]`, and reloading the list invalidates everything under `["users"]`.
///
/// ```swift
/// let all: QueryKey = "users"
/// let one = QueryKey("users", 1)
/// one.hasPrefix(all)   // true
/// ```
public struct QueryKey: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    /// The components, outermost first.
    public let components: [String]

    /// Creates a key from components.
    public init(_ components: [String]) {
        self.components = components
    }

    /// Creates a key from anything printable, so identifiers do not have to be stringified at each
    /// call site.
    public init(_ components: any CustomStringConvertible...) {
        self.components = components.map(String.init(describing:))
    }

    /// Creates a single-component key from a string literal.
    public init(stringLiteral value: String) {
        components = [value]
    }

    /// Creates a key from an array literal of components.
    public init(arrayLiteral elements: String...) {
        components = elements
    }

    /// Whether this key sits under `prefix`, which is what invalidating a family relies on.
    ///
    /// A key is its own prefix, so invalidating `["users", "1"]` also invalidates that exact entry.
    public func hasPrefix(_ prefix: QueryKey) -> Bool {
        guard prefix.components.count <= components.count else { return false }
        return Array(components.prefix(prefix.components.count)) == prefix.components
    }

    /// Returns a key with `component` appended.
    public func appending(_ component: any CustomStringConvertible) -> QueryKey {
        QueryKey(components + [String(describing: component)])
    }
}

extension QueryKey: CustomStringConvertible {
    /// The components joined with slashes, which is how they read in a log or a debugger.
    public var description: String {
        components.joined(separator: "/")
    }
}
