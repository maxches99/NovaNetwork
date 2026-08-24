import Foundation

/// Reads a parsed specification document into the model the emitter renders.
///
/// The reader is deliberately forgiving about *shape* — OpenAPI 3.0 and 3.1 disagree on how
/// nullability is spelled, and vendors extend documents freely — and deliberately strict about
/// *silence*: anything it cannot represent becomes a warning naming the location, never a quiet
/// substitution.
public struct OpenAPIReader {
    /// The name of the JSON fallback type emitted when a schema has no single Swift shape.
    public static let anyJSONTypeName = "GeneratedAnyJSON"
    /// The name of the box emitted to break recursive model types.
    public static let indirectBoxTypeName = "Indirect"

    // Internal rather than private: the operation and recursion passes live in
    // OpenAPIReader+Operations.swift and OpenAPIReader+Recursion.swift.
    let root: SpecValue
    var types: [GeneratedType] = []
    var takenTypeNames: Set<String> = []
    var warnings: [GenerationWarning] = []
    var expansionStack: [String] = []
    var usesAnyJSON = false
    var usesIndirectBox = false

    /// Creates a reader over a parsed document.
    public init(document: SpecValue) {
        root = document
    }

    /// Reads the document.
    ///
    /// - Returns: The model plus every warning raised while reading it.
    /// - Throws: ``GenerationError`` when the document is not usable at all.
    public static func read(_ document: SpecValue) throws -> (document: OpenAPIDocument, warnings: [GenerationWarning]) {
        var reader = OpenAPIReader(document: document)
        let result = try reader.read()
        return (result, reader.warnings)
    }

    private mutating func read() throws -> OpenAPIDocument {
        guard root.objectValue != nil else {
            throw GenerationError(message: "The document root is not a mapping.", location: "#")
        }
        guard root["openapi"]?.stringValue != nil else {
            throw GenerationError(
                message: "Missing 'openapi' version field. Swagger 2.0 documents are not supported; convert to OpenAPI 3 first.",
                location: "#"
            )
        }

        let title = root["info"]?["title"]?.stringValue ?? "Generated"
        let version = root["info"]?["version"]?.stringValue ?? "unversioned"

        readComponentSchemas()
        let operations = readOperations()
        breakRecursiveTypes()

        if usesAnyJSON {
            types.append(anyJSONType())
        }
        if usesIndirectBox {
            types.append(.indirectBox(name: Self.indirectBoxTypeName))
        }

        return OpenAPIDocument(
            title: title,
            version: version,
            serverURL: readServerURL(),
            types: types,
            operations: operations
        )
    }

    // MARK: - Servers

    private mutating func readServerURL() -> String? {
        guard let server = root["servers"]?.arrayValue?.first, let url = server["url"]?.stringValue else {
            warnings.append(
                GenerationWarning(
                    location: "#/servers",
                    message: "No server URL in the document. Generated endpoints take a baseURL as an initializer parameter."
                )
            )
            return nil
        }

        guard url.contains("{") else { return url }

        var resolved = url
        for (name, variable) in server["variables"]?.objectValue?.pairs ?? [] {
            guard let fallback = variable["default"]?.stringValue else { continue }
            resolved = resolved.replacingOccurrences(of: "{\(name)}", with: fallback)
        }

        if resolved.contains("{") {
            warnings.append(
                GenerationWarning(
                    location: "#/servers/0/url",
                    message: "Server URL '\(url)' has variables without defaults; using it verbatim."
                )
            )
        }
        return resolved
    }

    // MARK: - Schemas

    private mutating func readComponentSchemas() {
        for (name, schema) in root["components"]?["schemas"]?.objectValue?.pairs ?? [] {
            _ = defineType(
                for: schema,
                preferredName: SwiftNaming.typeName(name),
                location: "#/components/schemas/\(name)"
            )
        }
    }

    /// Resolves a schema to a Swift type, defining new model types as needed.
    mutating func typeReference(
        for schema: SpecValue,
        preferredName: String,
        location: String
    ) -> SwiftTypeReference {
        if let reference = schema["$ref"]?.stringValue {
            return referencedType(reference, location: location)
        }

        if let composed = composedTypeReference(for: schema, preferredName: preferredName, location: location) {
            return composed
        }

        let nullable = isNullable(schema)
        let type = schemaType(schema)
        let looksLikeObject = type == "object"
            || (type == nil && (schema["properties"] != nil || schema["additionalProperties"] != nil))

        if looksLikeObject {
            let resolved = defineType(for: schema, preferredName: preferredName, location: location)
            return nullable ? resolved.madeOptional : resolved
        }

        switch type {
        case "array":
            guard let items = schema["items"] else {
                warnings.append(GenerationWarning(location: location, message: "Array schema has no 'items'; using \(Self.anyJSONTypeName)."))
                usesAnyJSON = true
                return .array(.named(Self.anyJSONTypeName))
            }
            let element = typeReference(for: items, preferredName: singular(preferredName), location: location + "/items")
            return nullable ? SwiftTypeReference.array(element).madeOptional : .array(element)
        case .some(let scalar):
            if schema["enum"] != nil, scalar == "string" {
                let resolved = defineType(for: schema, preferredName: preferredName, location: location)
                return nullable ? resolved.madeOptional : resolved
            }
            let resolved = SwiftTypeReference.named(primitiveName(type: scalar, format: schema["format"]?.stringValue))
            return nullable ? resolved.madeOptional : resolved
        case nil:
            usesAnyJSON = true
            let resolved = SwiftTypeReference.named(Self.anyJSONTypeName)
            return nullable ? resolved.madeOptional : resolved
        }
    }

    /// Handles `allOf`, `oneOf`, and `anyOf`, returning `nil` when the schema uses none of them.
    private mutating func composedTypeReference(
        for schema: SpecValue,
        preferredName: String,
        location: String
    ) -> SwiftTypeReference? {
        if let allOf = schema["allOf"]?.arrayValue {
            return mergedType(allOf, preferredName: preferredName, location: location + "/allOf")
        }

        for keyword in ["oneOf", "anyOf"] {
            guard let branches = schema[keyword]?.arrayValue else { continue }
            let concrete = branches.filter { schemaType($0) != "null" && !$0.isNull }

            // `anyOf: [{type: string}, {type: "null"}]` is how OpenAPI 3.1 spells a nullable value.
            if concrete.count == 1 {
                let resolved = typeReference(for: concrete[0], preferredName: preferredName, location: location + "/\(keyword)/0")
                return branches.count > concrete.count ? resolved.madeOptional : resolved
            }

            warnings.append(
                GenerationWarning(
                    location: location + "/\(keyword)",
                    message: "\(keyword) with \(concrete.count) branches has no single Swift type; using \(Self.anyJSONTypeName)."
                )
            )
            usesAnyJSON = true
            return .named(Self.anyJSONTypeName)
        }

        return nil
    }

    /// Merges `allOf` branches into one struct, following `$ref`s and refusing to loop forever.
    private mutating func mergedType(
        _ branches: [SpecValue],
        preferredName: String,
        location: String
    ) -> SwiftTypeReference {
        var properties = SpecObject()
        var required: [SpecValue] = []

        for (offset, branch) in branches.enumerated() {
            collectMergeContent(
                from: branch,
                location: "\(location)/\(offset)",
                properties: &properties,
                required: &required
            )
        }

        var merged = SpecObject()
        merged["type"] = .string("object")
        merged["properties"] = .object(properties)
        merged["required"] = .array(required)
        return defineType(for: .object(merged), preferredName: preferredName, location: location)
    }

    /// Copies one `allOf` branch's properties into the merge, following references and nested
    /// compositions so a branch that is itself an `allOf` is not silently dropped.
    private mutating func collectMergeContent(
        from schema: SpecValue,
        location: String,
        properties: inout SpecObject,
        required: inout [SpecValue]
    ) {
        var resolved = schema
        var pushedReference: String?

        if let reference = schema["$ref"]?.stringValue {
            guard !expansionStack.contains(reference) else {
                warnings.append(
                    GenerationWarning(
                        location: location,
                        message: "Reference cycle through '\(reference)'; the repeated branch is skipped."
                    )
                )
                return
            }
            guard let target = resolveReference(reference) else {
                warnings.append(
                    GenerationWarning(location: location, message: "Unresolved reference '\(reference)'; the branch is skipped.")
                )
                return
            }
            expansionStack.append(reference)
            pushedReference = reference
            resolved = target
        }

        if let nested = resolved["allOf"]?.arrayValue {
            for (offset, branch) in nested.enumerated() {
                collectMergeContent(
                    from: branch,
                    location: "\(location)/allOf/\(offset)",
                    properties: &properties,
                    required: &required
                )
            }
        }

        for (name, property) in resolved["properties"]?.objectValue?.pairs ?? [] {
            properties[name] = property
        }
        required += resolved["required"]?.arrayValue ?? []

        if pushedReference != nil {
            expansionStack.removeLast()
        }
    }

    /// Defines and records a model type for an object or enum schema.
    private mutating func defineType(
        for schema: SpecValue,
        preferredName: String,
        location: String
    ) -> SwiftTypeReference {
        if let reference = schema["$ref"]?.stringValue {
            return referencedType(reference, location: location)
        }
        if schema["allOf"] != nil || schema["oneOf"] != nil || schema["anyOf"] != nil {
            return composedTypeReference(for: schema, preferredName: preferredName, location: location)
                ?? .named(Self.anyJSONTypeName)
        }
        if let existing = types.first(where: { $0.name == preferredName }) {
            return .named(existing.name)
        }

        let typeDocumentation = documentation(of: schema)
        let name = SwiftNaming.disambiguated(preferredName, taken: &takenTypeNames)

        if let values = schema["enum"]?.arrayValue, schemaType(schema) == "string" {
            let cases = values.compactMap(\.stringValue).map {
                GeneratedEnumCase(swiftName: SwiftNaming.enumCaseName($0), wireValue: $0)
            }
            types.append(.stringEnum(name: name, cases: cases, documentation: typeDocumentation))
            return .named(name)
        }

        let propertyPairs = schema["properties"]?.objectValue?.pairs ?? []

        if propertyPairs.isEmpty, let additional = schema["additionalProperties"], additional.objectValue != nil {
            let value = typeReference(for: additional, preferredName: name + "Value", location: location + "/additionalProperties")
            types.append(.alias(name: name, target: .dictionary(value), documentation: typeDocumentation))
            return .named(name)
        }
        if propertyPairs.isEmpty, schemaType(schema) != "object" {
            let target = SwiftTypeReference.named(
                primitiveName(type: schemaType(schema), format: schema["format"]?.stringValue)
            )
            types.append(.alias(name: name, target: target, documentation: typeDocumentation))
            return .named(name)
        }
        if schema["additionalProperties"]?.objectValue != nil, !propertyPairs.isEmpty {
            warnings.append(
                GenerationWarning(
                    location: location,
                    message: "'additionalProperties' alongside declared properties is not represented; extra keys are dropped when decoding."
                )
            )
        }

        // Reserve the name before reading properties so a self-referencing schema resolves to it.
        types.append(.object(name: name, properties: [], documentation: typeDocumentation))

        let requiredNames = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        var properties: [GeneratedProperty] = []

        for (wireName, propertySchema) in propertyPairs {
            var type = typeReference(
                for: propertySchema,
                preferredName: name + SwiftNaming.typeName(wireName),
                location: location + "/properties/\(wireName)"
            )
            if !requiredNames.contains(wireName) {
                type = type.madeOptional
            }
            properties.append(
                GeneratedProperty(
                    swiftName: SwiftNaming.propertyName(wireName),
                    wireName: wireName,
                    type: type,
                    documentation: documentation(of: propertySchema)
                )
            )
        }

        if let index = types.firstIndex(where: { $0.name == name }) {
            types[index] = .object(name: name, properties: properties, documentation: typeDocumentation)
        }
        return .named(name)
    }

    private mutating func referencedType(_ reference: String, location: String) -> SwiftTypeReference {
        let prefix = "#/components/schemas/"
        guard reference.hasPrefix(prefix) else {
            warnings.append(
                GenerationWarning(
                    location: location,
                    message: "Reference '\(reference)' does not point at #/components/schemas; using \(Self.anyJSONTypeName)."
                )
            )
            usesAnyJSON = true
            return .named(Self.anyJSONTypeName)
        }
        return .named(SwiftNaming.typeName(String(reference.dropFirst(prefix.count))))
    }

    /// Follows a local JSON pointer.
    func resolveReference(_ reference: String) -> SpecValue? {
        guard reference.hasPrefix("#/") else { return nil }
        var value = root
        for component in reference.dropFirst(2).split(separator: "/") {
            let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = value[key] else { return nil }
            value = next
        }
        return value
    }

    // MARK: - Helpers

    func schemaType(_ schema: SpecValue) -> String? {
        if let single = schema["type"]?.stringValue { return single }
        guard let list = schema["type"]?.arrayValue else { return nil }
        return list.compactMap(\.stringValue).first { $0 != "null" }
    }

    private func isNullable(_ schema: SpecValue) -> Bool {
        if schema["nullable"]?.boolValue == true { return true }
        guard let list = schema["type"]?.arrayValue else { return false }
        return list.contains(.string("null"))
    }

    private func primitiveName(type: String?, format: String?) -> String {
        switch (type, format) {
        case ("string", "date-time"), ("string", "date"): "Date"
        case ("string", "uuid"): "UUID"
        case ("string", "binary"), ("string", "byte"): "Data"
        case ("string", _): "String"
        case ("integer", "int64"): "Int64"
        case ("integer", _): "Int"
        case ("number", "float"): "Float"
        case ("number", _): "Double"
        case ("boolean", _): "Bool"
        default: Self.anyJSONTypeName
        }
    }

    private func documentation(of schema: SpecValue) -> String? {
        let text = schema["description"]?.stringValue ?? schema["title"]?.stringValue
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    /// Strips a trailing `s` so `[Pet]` inside `Pets` suggests `Pet` for an inline item schema.
    private func singular(_ name: String) -> String {
        name.count > 1 && name.hasSuffix("s") ? String(name.dropLast()) : name + "Item"
    }

    private func anyJSONType() -> GeneratedType {
        .anyJSON(name: Self.anyJSONTypeName)
    }
}
