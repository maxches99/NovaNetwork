import Foundation

// MARK: - Operations

extension OpenAPIReader {
    /// HTTP methods read from a path item, in the order they are emitted.
    static var methods: [String] { ["get", "put", "post", "delete", "patch", "head", "options"] }
}

extension OpenAPIReader {
    /// Reads every operation in `paths`, in document order.
    mutating func readOperations() -> [OpenAPIOperation] {
        var operations: [OpenAPIOperation] = []

        for (path, item) in root["paths"]?.objectValue?.pairs ?? [] {
            let sharedParameters = item["parameters"]?.arrayValue ?? []

            for method in Self.methods {
                guard let operation = item[method], operation.objectValue != nil else { continue }
                let location = "#/paths/\(path)/\(method)"
                let typeName = SwiftNaming.disambiguated(
                    SwiftNaming.operationTypeName(
                        method: method,
                        path: path,
                        operationID: operation["operationId"]?.stringValue
                    ),
                    taken: &takenTypeNames
                )

                operations.append(
                    OpenAPIOperation(
                        typeName: typeName,
                        method: method,
                        path: path,
                        responseType: readResponseType(operation, typeName: typeName, location: location),
                        parameters: readParameters(
                            shared: sharedParameters,
                            operation: operation,
                            typeName: typeName,
                            location: location
                        ),
                        requestBody: readRequestBody(operation, typeName: typeName, location: location),
                        documentation: operationDocumentation(operation),
                        isDeprecated: operation["deprecated"]?.boolValue == true
                    )
                )
            }
        }

        return operations
    }

    private func operationDocumentation(_ operation: SpecValue) -> String? {
        let parts = [operation["summary"]?.stringValue, operation["description"]?.stringValue]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    // MARK: Parameters

    private mutating func readParameters(
        shared: [SpecValue],
        operation: SpecValue,
        typeName: String,
        location: String
    ) -> [OpenAPIParameter] {
        var merged: [(key: String, value: SpecValue)] = []

        for (offset, raw) in (shared + (operation["parameters"]?.arrayValue ?? [])).enumerated() {
            guard let parameter = dereferenced(raw, location: "\(location)/parameters/\(offset)") else { continue }
            guard let name = parameter["name"]?.stringValue, let location = parameter["in"]?.stringValue else { continue }
            let key = "\(location):\(name)"
            if let index = merged.firstIndex(where: { $0.key == key }) {
                merged[index] = (key, parameter)
            } else {
                merged.append((key, parameter))
            }
        }

        var parameters: [OpenAPIParameter] = []
        var taken: Set<String> = []

        for (offset, entry) in merged.enumerated() {
            let parameter = entry.value
            let parameterLocation = "\(location)/parameters/\(offset)"
            guard let wireName = parameter["name"]?.stringValue else { continue }
            guard let place = parameter["in"]?.stringValue else { continue }
            guard let where_ = ParameterLocation(rawValue: place) else {
                warnings.append(
                    GenerationWarning(
                        location: parameterLocation,
                        message: "Parameter '\(wireName)' is in '\(place)', which generated endpoints do not send; it is skipped."
                    )
                )
                continue
            }

            let required = where_ == .path || parameter["required"]?.boolValue == true
            let schema = parameter["schema"] ?? .object(SpecObject([("type", .string("string"))]))
            var type = typeReference(
                for: schema,
                preferredName: typeName + SwiftNaming.typeName(wireName),
                location: parameterLocation + "/schema"
            )
            if !required { type = type.madeOptional }

            var swiftName = SwiftNaming.propertyName(wireName)
            if taken.contains(swiftName) {
                swiftName = SwiftNaming.disambiguated(swiftName, taken: &taken)
            } else {
                taken.insert(swiftName)
            }

            parameters.append(
                OpenAPIParameter(
                    wireName: wireName,
                    swiftName: swiftName,
                    location: where_,
                    type: type,
                    queryStyle: queryStyle(for: parameter, location: parameterLocation),
                    documentation: parameter["description"]?.stringValue
                )
            )
        }

        let order: [ParameterLocation] = [.path, .query, .header]
        return parameters.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.location) ?? 0
            let right = order.firstIndex(of: rhs.location) ?? 0
            return left == right ? false : left < right
        }
    }

    /// Maps OpenAPI's `style` and `explode` onto ``EndpointQueryStyle``.
    private mutating func queryStyle(for parameter: SpecValue, location: String) -> String {
        guard parameter["in"]?.stringValue == "query" else { return ".repeated" }
        let style = parameter["style"]?.stringValue ?? "form"
        let explode = parameter["explode"]?.boolValue ?? (style == "form")

        switch style {
        case "form": return explode ? ".repeated" : ".commaSeparated"
        case "simple": return ".commaSeparated"
        case "spaceDelimited": return ".spaceDelimited"
        case "pipeDelimited": return ".pipeDelimited"
        default:
            warnings.append(
                GenerationWarning(location: location, message: "Query style '\(style)' is not supported; using repeated values.")
            )
            return ".repeated"
        }
    }

    // MARK: Bodies and responses

    private mutating func readRequestBody(
        _ operation: SpecValue,
        typeName: String,
        location: String
    ) -> OpenAPIRequestBody? {
        guard let raw = operation["requestBody"] else { return nil }
        guard let body = dereferenced(raw, location: location + "/requestBody") else { return nil }
        guard let (contentType, media) = jsonContent(body["content"], location: location + "/requestBody/content") else {
            return nil
        }
        guard let schema = media["schema"] else { return nil }

        var type = typeReference(
            for: schema,
            preferredName: typeName + "Body",
            location: location + "/requestBody/content/\(contentType)/schema"
        )
        if body["required"]?.boolValue != true {
            type = type.madeOptional
        }

        return OpenAPIRequestBody(swiftName: "body", type: type, contentType: contentType)
    }

    private mutating func readResponseType(
        _ operation: SpecValue,
        typeName: String,
        location: String
    ) -> SwiftTypeReference? {
        guard let responses = operation["responses"]?.objectValue else { return nil }

        let successCodes = responses.keys
            .filter { $0.hasPrefix("2") }
            .sorted { (Int($0) ?? 299) < (Int($1) ?? 299) }

        guard let code = successCodes.first, let response = responses[code] else {
            if !responses.isEmpty {
                warnings.append(
                    GenerationWarning(
                        location: location + "/responses",
                        message: "No 2xx response is declared; the operation is generated as returning no content."
                    )
                )
            }
            return nil
        }

        guard let resolved = dereferenced(response, location: location + "/responses/\(code)"),
              let (contentType, media) = jsonContent(resolved["content"], location: location + "/responses/\(code)/content"),
              let schema = media["schema"]
        else {
            return nil
        }

        return typeReference(
            for: schema,
            preferredName: typeName + "Response",
            location: location + "/responses/\(code)/content/\(contentType)/schema"
        )
    }

    /// Picks the JSON media type from a `content` mapping, warning when only other types exist.
    private mutating func jsonContent(_ content: SpecValue?, location: String) -> (String, SpecValue)? {
        guard let object = content?.objectValue, !object.isEmpty else { return nil }

        if let media = object["application/json"] {
            return ("application/json", media)
        }
        if let key = object.keys.first(where: { $0.hasSuffix("+json") }), let media = object[key] {
            return (key, media)
        }

        warnings.append(
            GenerationWarning(
                location: location,
                message: "No JSON media type among \(object.keys.joined(separator: ", ")); this payload is not generated."
            )
        )
        return nil
    }

    /// Follows a `$ref` when present, warning when it cannot be resolved.
    private mutating func dereferenced(_ value: SpecValue, location: String) -> SpecValue? {
        guard let reference = value["$ref"]?.stringValue else { return value }
        guard let resolved = resolveReference(reference) else {
            warnings.append(
                GenerationWarning(location: location, message: "Unresolved reference '\(reference)'.")
            )
            return nil
        }
        return resolved
    }
}
