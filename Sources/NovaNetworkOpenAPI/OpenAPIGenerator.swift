import Foundation

/// Generated source plus everything the generator could not represent faithfully.
public struct GenerationResult: Sendable, Equatable {
    /// The Swift source to write.
    public let source: String
    /// Warnings raised while reading the document.
    public let warnings: [GenerationWarning]

    /// Creates a result.
    public init(source: String, warnings: [GenerationWarning]) {
        self.source = source
        self.warnings = warnings
    }
}

/// Turns an OpenAPI document into Swift endpoint types.
///
/// Generation is a pure function of the document text and the options: the same input always
/// produces byte-identical output, so a regenerated file only differs when the spec did.
public enum OpenAPIGenerator {
    /// Generates Swift source from a specification document.
    ///
    /// - Parameters:
    ///   - specText: The document, JSON or YAML.
    ///   - options: How the source is shaped.
    /// - Returns: The generated source and any warnings.
    /// - Throws: ``SpecParseError`` for an unreadable document, ``GenerationError`` for a readable
    ///   document that is not an OpenAPI 3 spec.
    public static func generate(specText: String, options: GeneratorOptions = GeneratorOptions()) throws -> GenerationResult {
        let parsed = try SpecParser.parse(specText)
        let (document, warnings) = try OpenAPIReader.read(parsed)
        return GenerationResult(source: SwiftEndpointEmitter.emit(document, options: options), warnings: warnings)
    }
}
