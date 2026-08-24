import Foundation

// MARK: - Recursion

extension OpenAPIReader {
    /// Boxes the properties that would otherwise make a struct contain itself.
    ///
    /// Swift rejects a value type that stores itself, and an `Optional` does not help: it still
    /// stores the wrapped value inline. Arrays and dictionaries do break the cycle, since they hold
    /// their elements on the heap, so only direct and optional containment needs boxing.
    mutating func breakRecursiveTypes() {
        var properties: [String: [String]] = [:]
        for type in types {
            guard case let .object(name, members, _) = type else { continue }
            properties[name] = members.compactMap { member in
                directlyContainedType(member.type).map { _ in member.wireName }
            }
        }

        var visiting: Set<String> = []
        var finished: Set<String> = []
        var boxed: Set<String> = []

        func visit(_ name: String) {
            guard !finished.contains(name) else { return }
            visiting.insert(name)

            if let index = types.firstIndex(where: { $0.name == name }), case let .object(_, members, _) = types[index] {
                for member in members {
                    guard let contained = directlyContainedType(member.type) else { continue }
                    if visiting.contains(contained) {
                        boxed.insert("\(name).\(member.wireName)")
                    } else {
                        visit(contained)
                    }
                }
            }

            visiting.remove(name)
            finished.insert(name)
        }

        for name in types.map(\.name) {
            visit(name)
        }

        guard !boxed.isEmpty else { return }
        usesIndirectBox = true

        for (index, type) in types.enumerated() {
            guard case let .object(name, members, documentation) = type else { continue }
            var updated = members
            for (offset, member) in members.enumerated() where boxed.contains("\(name).\(member.wireName)") {
                updated[offset] = GeneratedProperty(
                    swiftName: member.swiftName,
                    wireName: member.wireName,
                    type: boxedType(member.type),
                    documentation: member.documentation
                )
                warnings.append(
                    GenerationWarning(
                        location: "#/components/schemas/\(name)/properties/\(member.wireName)",
                        message: "'\(member.wireName)' closes a reference cycle, so it is generated as Indirect<…>; read it through its 'wrapped' property."
                    )
                )
            }
            types[index] = .object(name: name, properties: updated, documentation: documentation)
        }
    }

    /// The named type a property stores inline, or `nil` when an array or dictionary breaks the cycle.
    func directlyContainedType(_ type: SwiftTypeReference) -> String? {
        switch type {
        case let .named(name): name
        case let .optional(wrapped): directlyContainedType(wrapped)
        case .array, .dictionary, .indirect: nil
        }
    }

    /// The same type with its named core boxed.
    func boxedType(_ type: SwiftTypeReference) -> SwiftTypeReference {
        switch type {
        case .named: .indirect(type)
        case let .optional(wrapped): .optional(boxedType(wrapped))
        default: type
        }
    }
}
