import Foundation
import PackagePlugin

/// Runs the `nova-openapi` generator against a package's OpenAPI document.
///
/// Generated code is written into the package and checked in, rather than produced during every
/// build: it is ordinary source that shows up in review, in search, and in diffs.
///
///     swift package --allow-writing-to-package-directory nova-openapi \
///       --spec openapi.yaml --output Sources/MyApp/GeneratedEndpoints.swift
@main
struct GenerateOpenAPIEndpoints: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let tool = try context.tool(named: "nova-openapi")

        let process = Process()
        process.executableURL = tool.url
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PluginError.generationFailed(status: process.terminationStatus)
        }
    }
}

/// A failure from the generator tool.
enum PluginError: Error, CustomStringConvertible {
    case generationFailed(status: Int32)

    var description: String {
        switch self {
        case let .generationFailed(status):
            "nova-openapi exited with status \(status)."
        }
    }
}
