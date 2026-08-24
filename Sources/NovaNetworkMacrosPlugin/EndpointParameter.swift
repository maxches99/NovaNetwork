#if EndpointMacros
import SwiftSyntax
import SwiftSyntaxMacros

/// One stored property mapped to its place in the request.
struct EndpointParameter {
    /// Where a property's value ends up in the request.
    enum Role {
        case path(name: String)
        case query(name: String, style: ExprSyntax?)
        case header(name: String)
        case body(contentType: String?)
    }

    /// The Swift property name, used to read the value in generated code.
    let propertyName: String
    /// The role the property plays.
    let role: Role
    /// The declaration the parameter came from, so diagnostics can point at it.
    let declaration: VariableDeclSyntax
}

/// Protocol customization points that are never request parameters.
///
/// Without this, the recommended `let baseURL = …` on an endpoint type would be serialized as a
/// query item, which is exactly the kind of silent surprise the macro exists to remove.
let endpointReservedPropertyNames: Set<String> = ["baseURL", "timeout", "additionalHeaders", "jsonEncoder"]

/// The marker macros a property may carry.
enum EndpointMarker: String, CaseIterable {
    case path = "Path"
    case query = "Query"
    case header = "Header"
    case body = "Body"
}

enum EndpointParameterCollector {
    /// Reads every stored property of the struct and assigns it a role.
    ///
    /// - Parameters:
    ///   - structDecl: The annotated declaration.
    ///   - placeholders: Placeholder names found in the path template, which bind properties by name.
    ///   - context: Expansion context used to report malformed markers.
    /// - Returns: The collected parameters, or `nil` when a diagnostic was reported.
    static func collect(
        from structDecl: StructDeclSyntax,
        placeholders: Set<String>,
        in context: some MacroExpansionContext
    ) -> [EndpointParameter]? {
        var parameters: [EndpointParameter] = []
        var failed = false

        for member in structDecl.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self), isStoredInstanceProperty(variable) else {
                continue
            }

            for binding in variable.bindings {
                guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                    continue
                }
                let propertyName = identifier.trimmingBackticks
                guard !endpointReservedPropertyNames.contains(propertyName) else { continue }

                switch role(for: variable, propertyName: propertyName, placeholders: placeholders, in: context) {
                case .none:
                    failed = true
                case let .some(role):
                    parameters.append(
                        EndpointParameter(propertyName: identifier, role: role, declaration: variable)
                    )
                }
            }
        }

        return failed ? nil : parameters
    }

    /// Decides a property's role: an explicit marker, then the path template, then query by default.
    private static func role(
        for variable: VariableDeclSyntax,
        propertyName: String,
        placeholders: Set<String>,
        in context: some MacroExpansionContext
    ) -> EndpointParameter.Role? {
        var found: (marker: EndpointMarker, attribute: AttributeSyntax)?

        for attribute in variable.attributes {
            guard let attribute = attribute.as(AttributeSyntax.self),
                  let name = attributeName(attribute),
                  let marker = EndpointMarker(rawValue: name)
            else {
                continue
            }

            if let existing = found {
                context.report(
                    .conflictingMarkers(
                        property: propertyName,
                        first: existing.marker.rawValue,
                        second: marker.rawValue
                    ),
                    at: attribute
                )
                return nil
            }
            found = (marker, attribute)
        }

        guard let found else {
            return placeholders.contains(propertyName)
                ? .path(name: propertyName)
                : .query(name: propertyName, style: nil)
        }

        return role(marker: found.marker, attribute: found.attribute, propertyName: propertyName, in: context)
    }

    /// Reads a marker's arguments into a role.
    private static func role(
        marker: EndpointMarker,
        attribute: AttributeSyntax,
        propertyName: String,
        in context: some MacroExpansionContext
    ) -> EndpointParameter.Role? {
        let arguments = attribute.arguments?.as(LabeledExprListSyntax.self)
        let unlabeled = arguments?.first(where: { $0.label == nil })

        var wireName = propertyName
        if let unlabeled {
            guard let literal = unlabeled.expression.stringLiteralValue else {
                context.report(.nameMustBeStringLiteral(marker: marker.rawValue), at: unlabeled.expression)
                return nil
            }
            guard !literal.isEmpty else {
                context.report(.emptyParameterName(marker: marker.rawValue), at: unlabeled.expression)
                return nil
            }
            wireName = literal
        }

        switch marker {
        case .path:
            return .path(name: wireName)
        case .query:
            return .query(name: wireName, style: arguments?.first(where: { $0.label?.text == "style" })?.expression)
        case .header:
            return .header(name: wireName)
        case .body:
            guard let contentType = arguments?.first(where: { $0.label?.text == "contentType" }) else {
                return .body(contentType: nil)
            }
            guard let literal = contentType.expression.stringLiteralValue else {
                context.report(.nameMustBeStringLiteral(marker: marker.rawValue), at: contentType.expression)
                return nil
            }
            return .body(contentType: literal)
        }
    }

    /// True for `let`/`var` instance properties with storage.
    ///
    /// Computed properties are skipped; `willSet`/`didSet` observers still describe storage, so
    /// properties carrying them are kept.
    private static func isStoredInstanceProperty(_ variable: VariableDeclSyntax) -> Bool {
        let isTypeLevel = variable.modifiers.contains { modifier in
            modifier.name.tokenKind == .keyword(.static) || modifier.name.tokenKind == .keyword(.class)
        }
        guard !isTypeLevel else { return false }

        return variable.bindings.allSatisfy { binding in
            switch binding.accessorBlock?.accessors {
            case .none:
                true
            case .getter:
                false
            case let .accessors(accessors):
                accessors.allSatisfy { accessor in
                    accessor.accessorSpecifier.tokenKind == .keyword(.willSet)
                        || accessor.accessorSpecifier.tokenKind == .keyword(.didSet)
                }
            }
        }
    }

    /// The trailing identifier of an attribute name, ignoring any module qualification.
    private static func attributeName(_ attribute: AttributeSyntax) -> String? {
        if let identifier = attribute.attributeName.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = attribute.attributeName.as(MemberTypeSyntax.self) {
            return member.name.text
        }
        return nil
    }
}

extension ExprSyntax {
    /// The value of a plain string literal, or `nil` for interpolated and non-literal expressions.
    var stringLiteralValue: String? {
        guard let literal = self.as(StringLiteralExprSyntax.self) else { return nil }
        var value = ""
        for segment in literal.segments {
            guard case let .stringSegment(text) = segment else { return nil }
            value += text.content.text
        }
        return value
    }
}

extension String {
    /// The identifier without the backticks Swift uses to escape keywords.
    var trimmingBackticks: String {
        hasPrefix("`") && hasSuffix("`") && count > 1 ? String(dropFirst().dropLast()) : self
    }
}
#endif
