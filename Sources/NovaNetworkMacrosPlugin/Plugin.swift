#if EndpointMacros
import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The compiler plugin hosting NovaNetwork's endpoint macros.
@main
struct NovaNetworkMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        EndpointMacro.self,
        EndpointParameterMarkerMacro.self,
    ]
}
#else
/// A do-nothing entry point for builds with the `EndpointMacros` trait disabled.
///
/// With the trait off, swift-syntax is pruned from resolution and every source file in this target
/// compiles away, leaving an executable with no `main`. Nothing loads this plugin in that
/// configuration — the macro module that would reference it is empty too — but the tool still has
/// to link when the root package builds all of its targets.
@main
struct NovaNetworkMacrosPluginDisabled {
    static func main() {}
}
#endif
