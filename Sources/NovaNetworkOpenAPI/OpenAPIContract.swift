import Foundation

/// How much a contract violation matters.
public enum ContractViolationSeverity: String, Sendable, Equatable {
    /// The response would fail a decode, or decode into wrong data.
    case breaking
    /// The response carries something the spec does not mention. Nothing fails yet.
    case drift
}

/// One way a response differs from its specification.
public struct ContractViolation: Sendable, Equatable, CustomStringConvertible {
    /// What is wrong.
    public enum Kind: Sendable, Equatable {
        /// No operation in the spec has this method and path.
        case undocumentedOperation
        /// The operation does not describe this status code, and has no `default`.
        case undocumentedStatusCode(Int)
        /// The body is not valid JSON.
        case invalidJSON
        /// A value has another type than the schema says.
        case typeMismatch(expected: String, actual: String)
        /// An object lacks a property the schema lists as `required`.
        case missingRequiredField(String)
        /// A value is `null` where the schema does not allow it.
        case nullNotAllowed
        /// A string is not one of the schema's `enum` values.
        case unexpectedEnumValue(String)
        /// No member of a `oneOf` or `anyOf` matches.
        case noMatchingSchema
        /// An object has a property the schema does not describe.
        case undocumentedField(String)
    }

    /// What is wrong.
    public let kind: Kind
    /// Where in the body, as a JSON pointer; the empty string is the whole body.
    public let pointer: String
    /// How much it matters.
    public let severity: ContractViolationSeverity

    /// Creates a violation.
    public init(kind: Kind, pointer: String, severity: ContractViolationSeverity) {
        self.kind = kind
        self.pointer = pointer
        self.severity = severity
    }

    /// The violation as a log line: severity, pointer, and what is wrong.
    public var description: String {
        let location = pointer.isEmpty ? "body" : pointer
        let detail: String
        switch kind {
        case .undocumentedOperation: detail = "operation is not in the spec"
        case .undocumentedStatusCode(let code): detail = "status \(code) is not in the spec"
        case .invalidJSON: detail = "body is not valid JSON"
        case let .typeMismatch(expected, actual): detail = "expected \(expected), got \(actual)"
        case .missingRequiredField(let name): detail = "required field '\(name)' is missing"
        case .nullNotAllowed: detail = "null is not allowed"
        case .unexpectedEnumValue(let value): detail = "'\(value)' is not one of the enum values"
        case .noMatchingSchema: detail = "matches none of the oneOf/anyOf schemas"
        case .undocumentedField(let name): detail = "field '\(name)' is not in the spec"
        }
        return "\(severity.rawValue): \(location): \(detail)"
    }
}

/// Every way one response differs from its specification.
public struct ContractReport: Sendable, Equatable {
    /// The request method, uppercased.
    public let method: String
    /// The URL path that was requested.
    public let path: String
    /// The spec's path template the request matched, when it matched one.
    public let operationPath: String?
    /// The response's status code.
    public let statusCode: Int
    /// What differs.
    public let violations: [ContractViolation]

    /// Creates a report.
    public init(method: String, path: String, operationPath: String?, statusCode: Int, violations: [ContractViolation]) {
        self.method = method
        self.path = path
        self.operationPath = operationPath
        self.statusCode = statusCode
        self.violations = violations
    }

    /// Whether anything would fail a decode or mean wrong data.
    public var hasBreakingViolations: Bool {
        violations.contains { $0.severity == .breaking }
    }
}

/// What an OpenAPI document says responses look like, for checking real ones against it.
///
/// Built from the same document `nova-openapi` generates code from, so the spec the code was typed
/// against is the spec the traffic is checked against.
///
/// ```swift
/// let contract = try OpenAPIContract(specText: String(contentsOf: specURL))
/// let report = contract.validate(method: "GET", url: url, statusCode: 200, headers: headers, body: data)
/// for violation in report.violations { print(violation) }
/// ```
///
/// It checks shape, not values: types, `required`, null, `enum`, `items`, `properties`,
/// `additionalProperties`, `$ref`, `allOf`, `oneOf`, and `anyOf`. Bounds, patterns, and formats are
/// out of scope.
public struct OpenAPIContract: Sendable {
    private struct Operation: Sendable {
        let method: String
        let template: String
        let segments: [String]
        let responses: SpecValue?
    }

    private let root: SpecValue
    private let basePath: [String]
    private let operations: [Operation]

    /// Builds a contract from a parsed document.
    ///
    /// - Throws: ``GenerationError`` when the document has no `paths`.
    public init(document: SpecValue) throws {
        guard let paths = document["paths"]?.objectValue else {
            throw GenerationError(message: "the document has no paths", location: "#/paths")
        }
        root = document
        basePath = Self.basePath(of: document["servers"]?.arrayValue?.first?["url"]?.stringValue)

        var operations: [Operation] = []
        for (template, item) in paths.pairs {
            for method in ["get", "put", "post", "delete", "options", "head", "patch"] {
                guard let operation = item[method] else { continue }
                operations.append(
                    Operation(
                        method: method.uppercased(),
                        template: template,
                        segments: Self.segments(of: template),
                        responses: operation["responses"]
                    )
                )
            }
        }
        self.operations = operations
    }

    /// Builds a contract from a JSON or YAML document.
    ///
    /// - Throws: ``SpecParseError`` when the text cannot be parsed, ``GenerationError`` when it has
    ///   no `paths`.
    public init(specText: String) throws {
        try self.init(document: SpecParser.parse(specText))
    }

    /// Checks one response against the spec.
    ///
    /// - Parameters:
    ///   - method: The request method.
    ///   - url: The requested URL. Its path, less the first server's base path, picks the operation.
    ///   - statusCode: The response status, which picks the response schema.
    ///   - headers: The response headers. A `Content-Type` that is not JSON skips the body.
    ///   - body: The response body.
    /// - Returns: Every violation found; an empty list means the response matches.
    public func validate(
        method: String,
        url: URL,
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data
    ) -> ContractReport {
        let method = method.uppercased()
        let path = url.path
        func report(_ operationPath: String?, _ violations: [ContractViolation]) -> ContractReport {
            ContractReport(method: method, path: path, operationPath: operationPath, statusCode: statusCode, violations: violations)
        }

        guard let operation = operation(method: method, path: path) else {
            return report(nil, [ContractViolation(kind: .undocumentedOperation, pointer: "", severity: .drift)])
        }
        guard let response = response(for: statusCode, in: operation.responses) else {
            return report(
                operation.template,
                [ContractViolation(kind: .undocumentedStatusCode(statusCode), pointer: "", severity: .drift)]
            )
        }
        if let contentType = headerValue("Content-Type", in: headers), !Self.isJSON(contentType) {
            return report(operation.template, [])
        }
        guard let schema = jsonSchema(of: response) else {
            return report(operation.template, [])
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return report(operation.template, [ContractViolation(kind: .invalidJSON, pointer: "", severity: .breaking)])
        }

        var violations: [ContractViolation] = []
        check(value, against: schema, at: "", into: &violations)
        return report(operation.template, violations)
    }

    // MARK: - Matching

    private func operation(method: String, path: String) -> Operation? {
        var segments = Self.segments(of: path)
        if segments.starts(with: basePath) {
            segments.removeFirst(basePath.count)
        }

        var best: (operation: Operation, literals: Int)?
        for operation in operations where operation.method == method && operation.segments.count == segments.count {
            var literals = 0
            var matches = true
            for (pattern, segment) in zip(operation.segments, segments) {
                if pattern.hasPrefix("{") && pattern.hasSuffix("}") {
                    continue
                }
                guard pattern == segment else {
                    matches = false
                    break
                }
                literals += 1
            }
            if matches, literals > (best?.literals ?? -1) {
                best = (operation, literals)
            }
        }
        return best?.operation
    }

    private func response(for statusCode: Int, in responses: SpecValue?) -> SpecValue? {
        guard let responses else { return nil }
        let candidates = [String(statusCode), "\(statusCode / 100)XX", "\(statusCode / 100)xx", "default"]
        for key in candidates {
            if let response = responses[key] {
                return dereferenced(response)
            }
        }
        return nil
    }

    private func jsonSchema(of response: SpecValue) -> SpecValue? {
        guard let content = response["content"]?.objectValue else { return nil }
        let json = content.pairs.first { Self.isJSON($0.key) } ?? content.pairs.first
        return json?.value["schema"]
    }

    // MARK: - Checking

    private func check(_ value: JSONValue, against schema: SpecValue, at pointer: String, into violations: inout [ContractViolation]) {
        let schema = dereferenced(schema) ?? schema

        if case .null = value {
            if !allowsNull(schema) {
                violations.append(ContractViolation(kind: .nullNotAllowed, pointer: pointer, severity: .breaking))
            }
            return
        }

        if let members = schema["allOf"]?.arrayValue {
            for member in members {
                check(value, against: member, at: pointer, ignoringUndocumentedFields: true, into: &violations)
            }
            reportUndocumentedFields(in: value, documentedBy: schema, at: pointer, into: &violations)
        }

        for combinator in ["oneOf", "anyOf"] {
            guard let members = schema[combinator]?.arrayValue else { continue }
            let matches = members.contains { member in
                var candidate: [ContractViolation] = []
                check(value, against: member, at: pointer, into: &candidate)
                return !candidate.contains { $0.severity == .breaking }
            }
            if !matches {
                violations.append(ContractViolation(kind: .noMatchingSchema, pointer: pointer, severity: .breaking))
            }
        }

        if let type = declaredType(of: schema), !value.conforms(to: type) {
            violations.append(
                ContractViolation(kind: .typeMismatch(expected: type, actual: value.typeName), pointer: pointer, severity: .breaking)
            )
            return
        }

        if let allowed = schema["enum"]?.arrayValue, case .string(let string) = value,
           !allowed.contains(.string(string)) {
            violations.append(ContractViolation(kind: .unexpectedEnumValue(string), pointer: pointer, severity: .breaking))
        }

        switch value {
        case .array(let elements):
            guard let items = schema["items"] else { return }
            for (index, element) in elements.enumerated() {
                check(element, against: items, at: "\(pointer)/\(index)", into: &violations)
            }
        case .object(let fields):
            checkObject(fields, against: schema, at: pointer, into: &violations)
            if schema["allOf"] == nil {
                reportUndocumentedFields(in: value, documentedBy: schema, at: pointer, into: &violations)
            }
        default:
            return
        }
    }

    /// Checks one `allOf` member, leaving undocumented-field judgement to the merged schema.
    private func check(
        _ value: JSONValue,
        against schema: SpecValue,
        at pointer: String,
        ignoringUndocumentedFields: Bool,
        into violations: inout [ContractViolation]
    ) {
        var found: [ContractViolation] = []
        check(value, against: schema, at: pointer, into: &found)
        violations += found.filter { violation in
            guard ignoringUndocumentedFields, violation.pointer == pointer else { return true }
            if case .undocumentedField = violation.kind { return false }
            return true
        }
    }

    private func checkObject(
        _ fields: [String: JSONValue],
        against schema: SpecValue,
        at pointer: String,
        into violations: inout [ContractViolation]
    ) {
        for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[required] == nil {
            violations.append(ContractViolation(kind: .missingRequiredField(required), pointer: pointer, severity: .breaking))
        }
        let properties = schema["properties"]?.objectValue
        for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
            let fieldPointer = "\(pointer)/\(Self.escape(name))"
            if let property = properties?[name] {
                check(field, against: property, at: fieldPointer, into: &violations)
            } else if let additional = schema["additionalProperties"], additional.objectValue != nil {
                check(field, against: additional, at: fieldPointer, into: &violations)
            }
        }
    }

    private func reportUndocumentedFields(
        in value: JSONValue,
        documentedBy schema: SpecValue,
        at pointer: String,
        into violations: inout [ContractViolation]
    ) {
        guard case .object(let fields) = value else { return }
        var documented = Set<String>()
        var additional: SpecValue?
        collectDocumentation(of: schema, into: &documented, additional: &additional)
        if let additional, additional.boolValue != false { return }

        let severity: ContractViolationSeverity = additional?.boolValue == false ? .breaking : .drift
        for name in fields.keys.sorted() where !documented.contains(name) {
            violations.append(ContractViolation(kind: .undocumentedField(name), pointer: pointer, severity: severity))
        }
    }

    /// The property names a schema describes, through `$ref` and every `allOf` member.
    private func collectDocumentation(of schema: SpecValue, into names: inout Set<String>, additional: inout SpecValue?) {
        let schema = dereferenced(schema) ?? schema
        // A schema that composes alternatives does not say which properties to expect.
        if schema["oneOf"] != nil || schema["anyOf"] != nil {
            additional = .bool(true)
        }
        names.formUnion(schema["properties"]?.objectValue?.keys ?? [])
        if let extra = schema["additionalProperties"], additional?.boolValue != true {
            additional = extra
        }
        for member in schema["allOf"]?.arrayValue ?? [] {
            collectDocumentation(of: member, into: &names, additional: &additional)
        }
    }

    // MARK: - Schema helpers

    private func dereferenced(_ value: SpecValue) -> SpecValue? {
        var current = value
        var seen = Set<String>()
        while let reference = current["$ref"]?.stringValue {
            guard seen.insert(reference).inserted, let target = resolve(reference) else { return nil }
            current = target
        }
        return current
    }

    private func resolve(_ reference: String) -> SpecValue? {
        guard reference.hasPrefix("#/") else { return nil }
        var value = root
        for component in reference.dropFirst(2).split(separator: "/") {
            let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = value[key] else { return nil }
            value = next
        }
        return value
    }

    private func declaredType(of schema: SpecValue) -> String? {
        if let single = schema["type"]?.stringValue { return single == "null" ? nil : single }
        return schema["type"]?.arrayValue?.compactMap(\.stringValue).first { $0 != "null" }
    }

    private func allowsNull(_ schema: SpecValue) -> Bool {
        if schema["nullable"]?.boolValue == true { return true }
        if schema["type"]?.stringValue == "null" { return true }
        if schema["type"]?.arrayValue?.contains(.string("null")) == true { return true }
        for combinator in ["oneOf", "anyOf"] {
            if schema[combinator]?.arrayValue?.contains(where: { allowsNull(dereferenced($0) ?? $0) }) == true {
                return true
            }
        }
        return false
    }

    private func headerValue(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func isJSON(_ contentType: String) -> Bool {
        let media = contentType.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return media == "application/json" || media.hasSuffix("+json")
    }

    private static func segments(of path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// The path part of a server URL, which may be relative and may contain `{variables}`.
    private static func basePath(of serverURL: String?) -> [String] {
        guard var url = serverURL else { return [] }
        if let scheme = url.range(of: "://") {
            url = String(url[scheme.upperBound...])
            guard let slash = url.firstIndex(of: "/") else { return [] }
            url = String(url[slash...])
        }
        return segments(of: url)
    }

    private static func escape(_ name: String) -> String {
        name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }
}

/// A JSON value, decoded so that a boolean and a number stay distinguishable on every platform.
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number(let value): value == value.rounded() ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    func conforms(to type: String) -> Bool {
        switch (type, self) {
        case ("integer", .number(let value)): value == value.rounded()
        case ("number", .number): true
        case ("string", .string), ("boolean", .bool), ("array", .array), ("object", .object): true
        default: false
        }
    }
}
