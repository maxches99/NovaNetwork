#if EndpointMacros
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A diagnostic emitted by the `@Endpoint` macro.
///
/// Every rejection path in the macro produces one of these instead of a malformed expansion, so a
/// mistake in an endpoint declaration reads as an explanation of what to write rather than as a
/// compiler error in generated code.
struct EndpointMacroDiagnostic: DiagnosticMessage {
    let message: String
    let messageID: String
    let severity: DiagnosticSeverity

    var diagnosticID: MessageID { MessageID(domain: "NovaNetworkMacros", id: messageID) }

    private init(_ message: String, id: String, severity: DiagnosticSeverity = .error) {
        self.message = message
        messageID = id
        self.severity = severity
    }

    static func requiresStruct(kind: String) -> Self {
        Self(
            "@Endpoint can only be applied to a struct; this is a \(kind). Endpoints must be Sendable value types.",
            id: "requiresStruct"
        )
    }

    static func genericNotSupported(typeName: String) -> Self {
        Self(
            "@Endpoint does not support generic types. Remove the generic parameters from '\(typeName)', or write makeRequest() by hand.",
            id: "genericNotSupported"
        )
    }

    static func explicitConformance(typeName: String, protocolName: String) -> Self {
        Self(
            "'\(typeName)' already declares conformance to \(protocolName), which @Endpoint adds itself. Remove ': \(protocolName)' from the declaration.",
            id: "explicitConformance"
        )
    }

    static let pathMustBeStringLiteral = Self(
        "The path must be a plain string literal so placeholders can be bound at compile time, for example \"/users/{id}\".",
        id: "pathMustBeStringLiteral"
    )

    static func invalidAbsoluteURL(_ text: String) -> Self {
        Self(
            """
            '\(text)' starts with a scheme but is not a valid URL. Use an absolute URL such as \
            "https://api.example.com/users/{id}", or a relative path with a baseURL on the type.
            """,
            id: "invalidAbsoluteURL"
        )
    }

    static func unboundPlaceholders(_ names: [String], template: String) -> Self {
        let list = names.map { "{\($0)}" }.joined(separator: ", ")
        let first = names[0]
        return Self(
            """
            Path template "\(template)" has no property for \(list). Add a stored property named \
            '\(first)', or mark an existing one with @Path("\(first)").
            """,
            id: "unboundPlaceholders"
        )
    }

    static func duplicateBody(existing: String, duplicate: String) -> Self {
        Self(
            """
            An endpoint can have one @Body property, but '\(existing)' and '\(duplicate)' are both \
            marked. Combine them into a single body type.
            """,
            id: "duplicateBody"
        )
    }

    static func bodyOnBodylessMethod(method: String, property: String) -> Self {
        let name = method.uppercased()
        return Self(
            "@Body is not allowed on a \(name) endpoint: \(name) requests have no defined body semantics. Send '\(property)' as a @Query parameter, or change the method.",
            id: "bodyOnBodylessMethod"
        )
    }

    static func conflictingMarkers(property: String, first: String, second: String) -> Self {
        Self(
            "'\(property)' is marked both @\(first) and @\(second); a property takes exactly one role.",
            id: "conflictingMarkers"
        )
    }

    static func emptyParameterName(marker: String) -> Self {
        Self(
            "@\(marker) was given an empty name. Pass a name, or omit the argument to use the property's own name.",
            id: "emptyParameterName"
        )
    }

    static func nameMustBeStringLiteral(marker: String) -> Self {
        Self(
            "@\(marker)'s name must be a plain string literal, so the wire name is fixed at compile time.",
            id: "nameMustBeStringLiteral"
        )
    }

    static func pathParameterWithoutPlaceholder(name: String, template: String) -> Self {
        Self(
            "@Path(\"\(name)\") has no matching placeholder in \"\(template)\". Add {\(name)} to the path, or change the marker to @Query.",
            id: "pathParameterWithoutPlaceholder"
        )
    }

    static let responseMustBeMetatype = Self(
        "The response argument must be a metatype literal such as User.self.",
        id: "responseMustBeMetatype"
    )
}

extension MacroExpansionContext {
    /// Reports a diagnostic anchored to a syntax node.
    func report(_ diagnostic: EndpointMacroDiagnostic, at node: some SyntaxProtocol) {
        diagnose(Diagnostic(node: Syntax(node), message: diagnostic))
    }
}
#endif
