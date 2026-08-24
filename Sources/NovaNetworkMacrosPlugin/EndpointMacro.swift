#if EndpointMacros
import Foundation
import SwiftSyntax
import SwiftSyntaxMacros

/// Expands `@Endpoint` into an ``EndpointDefinition`` conformance with a generated `makeRequest()`.
public enum EndpointMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let structDecl = declaration.as(StructDeclSyntax.self) else {
            context.report(.requiresStruct(kind: declaration.declKindDescription), at: node)
            return []
        }
        guard structDecl.genericParameterClause == nil else {
            context.report(.genericNotSupported(typeName: structDecl.name.text), at: node)
            return []
        }
        if let conflicting = structDecl.declaredEndpointConformance {
            context.report(
                .explicitConformance(typeName: structDecl.name.text, protocolName: conflicting),
                at: node
            )
            return []
        }

        guard let arguments = Arguments(node: node, in: context) else { return [] }
        guard let path = PathTemplate(literal: arguments.path, node: arguments.pathExpression, in: context) else {
            return []
        }
        guard let parameters = EndpointParameterCollector.collect(
            from: structDecl,
            placeholders: path.placeholders,
            in: context
        ) else {
            return []
        }
        guard validate(parameters, path: path, method: arguments.method, node: node, in: context) else {
            return []
        }

        let source = render(
            type: type,
            structDecl: structDecl,
            arguments: arguments,
            path: path,
            parameters: parameters,
            addsConformance: !protocols.isEmpty
        )

        return [try ExtensionDeclSyntax("\(raw: source)")]
    }

    // MARK: - Arguments

    /// The `@Endpoint(...)` attribute's arguments.
    private struct Arguments {
        let method: ExprSyntax
        let path: String
        let pathExpression: ExprSyntax
        let responseType: String?

        init?(node: AttributeSyntax, in context: some MacroExpansionContext) {
            let list = node.arguments?.as(LabeledExprListSyntax.self) ?? []
            let positional = list.filter { $0.label == nil }
            guard positional.count >= 2 else {
                context.report(.pathMustBeStringLiteral, at: node)
                return nil
            }

            method = positional[positional.startIndex].expression
            let pathArgument = positional[positional.index(after: positional.startIndex)].expression
            guard let literal = pathArgument.stringLiteralValue else {
                context.report(.pathMustBeStringLiteral, at: pathArgument)
                return nil
            }
            path = literal
            pathExpression = pathArgument

            guard let response = list.first(where: { $0.label?.text == "response" }) else {
                responseType = nil
                return
            }
            guard let metatype = response.expression.as(MemberAccessExprSyntax.self),
                  metatype.declName.baseName.tokenKind == .keyword(.`self`),
                  let base = metatype.base
            else {
                context.report(.responseMustBeMetatype, at: response.expression)
                return nil
            }
            responseType = base.trimmedDescription
        }

        /// The bare method name (`get`, `post`, …) when it is written as a member access literal.
        var methodName: String? {
            method.as(MemberAccessExprSyntax.self).map { $0.declName.baseName.text }
        }
    }

    // MARK: - Path

    /// A path template split into the part used at runtime and, for absolute URLs, an origin.
    private struct PathTemplate {
        let template: String
        let origin: String?
        let placeholders: Set<String>
        /// Placeholders in the order they appear, for stable diagnostics.
        let orderedPlaceholders: [String]

        init?(literal: String, node: ExprSyntax, in context: some MacroExpansionContext) {
            if let separator = literal.range(of: "://"), literal[..<separator.lowerBound].isURLScheme {
                let remainder = literal[separator.upperBound...]
                if let slash = remainder.firstIndex(of: "/") {
                    origin = String(literal[..<separator.lowerBound]) + "://" + String(remainder[..<slash])
                    template = String(remainder[slash...])
                } else {
                    origin = literal
                    template = ""
                }
                guard let url = URL(string: origin ?? ""), url.host != nil else {
                    context.report(.invalidAbsoluteURL(literal), at: node)
                    return nil
                }
            } else {
                origin = nil
                template = literal
            }

            orderedPlaceholders = Self.placeholderNames(in: template)
            placeholders = Set(orderedPlaceholders)
        }

        /// Extracts `{name}` placeholders, matching the runtime builder's scan exactly.
        private static func placeholderNames(in template: String) -> [String] {
            var names: [String] = []
            var remainder = Substring(template)

            while let open = remainder.firstIndex(of: "{") {
                let afterOpen = remainder.index(after: open)
                guard let close = remainder[afterOpen...].firstIndex(of: "}") else { break }
                names.append(String(remainder[afterOpen..<close]))
                remainder = remainder[remainder.index(after: close)...]
            }

            return names
        }
    }

    // MARK: - Validation

    private static func validate(
        _ parameters: [EndpointParameter],
        path: PathTemplate,
        method: ExprSyntax,
        node: AttributeSyntax,
        in context: some MacroExpansionContext
    ) -> Bool {
        var boundPlaceholders: Set<String> = []
        var bodyProperty: EndpointParameter?
        var valid = true

        for parameter in parameters {
            switch parameter.role {
            case let .path(name):
                guard path.placeholders.contains(name) else {
                    context.report(
                        .pathParameterWithoutPlaceholder(name: name, template: path.template),
                        at: parameter.declaration
                    )
                    valid = false
                    continue
                }
                boundPlaceholders.insert(name)
            case .body:
                if let existing = bodyProperty {
                    context.report(
                        .duplicateBody(existing: existing.propertyName, duplicate: parameter.propertyName),
                        at: parameter.declaration
                    )
                    valid = false
                }
                bodyProperty = parameter
            case .query, .header:
                continue
            }
        }

        let unbound = path.orderedPlaceholders.filter { !boundPlaceholders.contains($0) }
        if !unbound.isEmpty {
            context.report(.unboundPlaceholders(unbound, template: path.template), at: node)
            valid = false
        }

        if let bodyProperty,
           let methodName = method.as(MemberAccessExprSyntax.self)?.declName.baseName.text,
           methodName == "get" || methodName == "head" {
            context.report(
                .bodyOnBodylessMethod(method: methodName, property: bodyProperty.propertyName),
                at: bodyProperty.declaration
            )
            valid = false
        }

        return valid
    }

    // MARK: - Rendering

    private static func render(
        type: some TypeSyntaxProtocol,
        structDecl: StructDeclSyntax,
        arguments: Arguments,
        path: PathTemplate,
        parameters: [EndpointParameter],
        addsConformance: Bool
    ) -> String {
        let access = structDecl.accessModifierPrefix
        var members: [String] = []

        if let responseType = arguments.responseType {
            members.append("\(access)typealias Response = \(responseType)")
        }
        if let origin = path.origin {
            members.append("\(access)var baseURL: Foundation.URL { Foundation.URL(string: \(origin.swiftStringLiteral))! }")
        }
        members.append(makeRequestFunction(access: access, arguments: arguments, path: path, parameters: parameters))

        let conformance = addsConformance ? ": EndpointDefinition" : ""
        let body = members.joined(separator: "\n\n").indented()

        return """
        extension \(type.trimmedDescription)\(conformance) {
        \(body)
        }
        """
    }

    private static func makeRequestFunction(
        access: String,
        arguments: Arguments,
        path: PathTemplate,
        parameters: [EndpointParameter]
    ) -> String {
        let mutability = parameters.isEmpty ? "let" : "var"
        var lines = [
            "\(mutability) builder = NovaNetworkCore.EndpointRequestBuilder(",
            "    method: \(arguments.method.trimmedDescription),",
            "    baseURL: self.baseURL,",
            "    path: \(path.template.swiftStringLiteral)",
            ")",
        ]

        // Headers are emitted before the body so an explicit Content-Type parameter still wins.
        lines += parameters.compactMap { statement(for: $0, phase: .path) }
        lines += parameters.compactMap { statement(for: $0, phase: .query) }
        lines += parameters.compactMap { statement(for: $0, phase: .header) }
        lines += parameters.compactMap { statement(for: $0, phase: .body) }
        lines.append("return try builder.build(timeout: self.timeout, additionalHeaders: self.additionalHeaders)")

        return """
        \(access)func makeRequest() throws -> NovaNetworkCore.APIRequest {
        \(lines.joined(separator: "\n").indented())
        }
        """
    }

    private enum Phase {
        case path, query, header, body
    }

    /// The builder call for one parameter, or `nil` when it belongs to a different phase.
    private static func statement(for parameter: EndpointParameter, phase: Phase) -> String? {
        let value = "self.\(parameter.propertyName)"

        switch (parameter.role, phase) {
        case let (.path(name), .path):
            return "try builder.setPath(\(name.swiftStringLiteral), \(value))"
        case let (.query(name, style), .query):
            guard let style else {
                return "builder.addQuery(\(name.swiftStringLiteral), \(value))"
            }
            return "builder.addQuery(\(name.swiftStringLiteral), \(value), style: \(style.trimmedDescription))"
        case let (.header(name), .header):
            return "builder.setHeader(\(name.swiftStringLiteral), \(value))"
        case let (.body(contentType), .body):
            guard let contentType else {
                return "try builder.setJSONBody(\(value), encoder: self.jsonEncoder)"
            }
            return """
            builder.setHeader("Content-Type", \(contentType.swiftStringLiteral))
            try builder.setJSONBody(\(value), encoder: self.jsonEncoder)
            """
        default:
            return nil
        }
    }
}

/// Expands to nothing: the parameter markers exist so `@Endpoint` can read them off a property.
public enum EndpointParameterMarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

// MARK: - Syntax helpers

private extension DeclGroupSyntax {
    /// A human-readable kind name for diagnostics.
    var declKindDescription: String {
        switch self {
        case is ClassDeclSyntax: "class"
        case is ActorDeclSyntax: "actor"
        case is EnumDeclSyntax: "enum"
        case is ProtocolDeclSyntax: "protocol"
        case is ExtensionDeclSyntax: "extension"
        default: "declaration"
        }
    }
}

private extension StructDeclSyntax {
    /// The endpoint protocol the declaration already conforms to, if it names one directly.
    var declaredEndpointConformance: String? {
        inheritanceClause?.inheritedTypes.lazy
            .compactMap { $0.type.as(IdentifierTypeSyntax.self)?.name.text }
            .first { $0 == "Endpoint" || $0 == "EndpointDefinition" }
    }

    /// `"public "`, `"package "`, or `""`, so generated members match the type's visibility.
    var accessModifierPrefix: String {
        for modifier in modifiers {
            switch modifier.name.tokenKind {
            case .keyword(.public), .keyword(.open): return "public "
            case .keyword(.package): return "package "
            default: continue
            }
        }
        return ""
    }
}

private extension StringProtocol {
    /// True when the text is a URL scheme such as `https`.
    var isURLScheme: Bool {
        !isEmpty && allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}

extension String {
    /// The string as Swift source for a string literal, with escapes applied.
    var swiftStringLiteral: String {
        var escaped = ""
        for character in self {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    /// The string with every line indented by four spaces.
    func indented() -> String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "    " + $0 }
            .joined(separator: "\n")
    }
}
#endif
