import Foundation
import NovaNetworkOpenAPI

/// Command-line front end for ``OpenAPIGenerator``.
///
/// Invoked directly as `nova-openapi`, or through the `swift package nova-openapi` command plugin.
private enum CommandLineTool {
    static let usage = """
    USAGE: nova-openapi --spec <path> --output <path> [options]

    OPTIONS:
      --spec <path>        The OpenAPI 3 document to read (JSON or YAML).
      --output <path>      Where to write the generated Swift file, or - for standard output.
      --namespace <name>   Name of the generated namespace enum. Defaults to the document title.
      --access <level>     public (default) or internal.
      --quiet              Suppress warnings.
      --help               Print this message.
    """

    static func run() -> Int32 {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var values: [String: String] = [:]
        var quiet = false

        while let argument = arguments.first {
            arguments.removeFirst()
            switch argument {
            case "--help", "-h":
                print(usage)
                return 0
            case "--quiet":
                quiet = true
            case "--spec", "--output", "--namespace", "--access":
                guard let value = arguments.first else {
                    return fail("Missing value for \(argument).")
                }
                arguments.removeFirst()
                values[String(argument.dropFirst(2))] = value
            default:
                return fail("Unknown argument '\(argument)'.\n\n\(usage)")
            }
        }

        guard let specPath = values["spec"] else { return fail("Missing --spec.\n\n\(usage)") }
        guard let outputPath = values["output"] else { return fail("Missing --output.\n\n\(usage)") }

        let access = values["access"] ?? "public"
        guard access == "public" || access == "internal" else {
            return fail("--access must be 'public' or 'internal'.")
        }

        let specURL = URL(fileURLWithPath: specPath)
        let specText: String
        do {
            specText = try String(contentsOf: specURL, encoding: .utf8)
        } catch {
            return fail("Cannot read \(specPath): \(error.localizedDescription)")
        }

        let options = GeneratorOptions(
            namespace: values["namespace"],
            isPublic: access == "public",
            sourceName: specURL.lastPathComponent
        )

        let result: GenerationResult
        do {
            result = try OpenAPIGenerator.generate(specText: specText, options: options)
        } catch {
            return fail("\(specURL.lastPathComponent): \(error.localizedDescription)")
        }

        if !quiet {
            for warning in result.warnings {
                write("\(specURL.lastPathComponent): \(warning.formatted)\n", to: .standardError)
            }
        }

        if outputPath == "-" {
            print(result.source, terminator: "")
            return 0
        }

        do {
            try result.source.write(to: URL(fileURLWithPath: outputPath), atomically: true, encoding: .utf8)
        } catch {
            return fail("Cannot write \(outputPath): \(error.localizedDescription)")
        }

        if !quiet {
            let count = result.warnings.count
            write(
                "nova-openapi: wrote \(outputPath)\(count == 0 ? "" : " with \(count) warning\(count == 1 ? "" : "s")")\n",
                to: .standardError
            )
        }
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        write("error: \(message)\n", to: .standardError)
        return 1
    }

    private static func write(_ text: String, to handle: FileHandle) {
        handle.write(Data(text.utf8))
    }
}

exit(CommandLineTool.run())
