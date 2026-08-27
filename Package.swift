// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "NovaNetworkClient",
    platforms: [.iOS(.v13), .macOS(.v10_15), .watchOS(.v6), .tvOS(.v13)],
    products: [
        .library(name: "NovaNetworkCore", targets: ["NovaNetworkCore"]),
        .library(name: "NovaNetworkClient", targets: ["NovaNetworkClient"]),
        .library(name: "NovaNetworkClientTestSupport", targets: ["NovaNetworkClientTestSupport"]),
        .library(name: "NovaNetworkMacros", targets: ["NovaNetworkMacros"]),
        .library(name: "NovaNetworkCassette", targets: ["NovaNetworkCassette"]),
        .library(name: "NovaNetworkOpenAPI", targets: ["NovaNetworkOpenAPI"]),
        .executable(name: "nova-openapi", targets: ["NovaNetworkOpenAPIGenerator"]),
        .plugin(name: "GenerateOpenAPIEndpoints", targets: ["GenerateOpenAPIEndpoints"]),
        .executable(name: "NovaNetworkClientBenchmarks", targets: ["NovaNetworkClientBenchmarks"]),
        .executable(name: "NovaNetworkClientJSONPlaceholderExample", targets: ["NovaNetworkClientJSONPlaceholderExample"]),
        .executable(name: "NovaNetworkClientBatchTodosExample", targets: ["NovaNetworkClientBatchTodosExample"]),
        .executable(name: "NovaNetworkClientMiddlewareExample", targets: ["NovaNetworkClientMiddlewareExample"]),
        .executable(name: "NovaNetworkClientOfflineQueueExample", targets: ["NovaNetworkClientOfflineQueueExample"]),
        .executable(name: "NovaNetworkClientWebSocketExample", targets: ["NovaNetworkClientWebSocketExample"]),
        .executable(name: "NovaNetworkClientAuthRefreshReferenceExample", targets: ["NovaNetworkClientAuthRefreshReferenceExample"]),
        .executable(name: "NovaNetworkClientReconnectRecoveryReferenceExample", targets: ["NovaNetworkClientReconnectRecoveryReferenceExample"]),
        .executable(name: "NovaNetworkClientOfflineReplayReferenceExample", targets: ["NovaNetworkClientOfflineReplayReferenceExample"]),
        .executable(name: "NovaNetworkClientDiagnosticsReferenceExample", targets: ["NovaNetworkClientDiagnosticsReferenceExample"]),
        .executable(name: "NovaNetworkClientProductionProfileExample", targets: ["NovaNetworkClientProductionProfileExample"]),
        .executable(name: "NovaNetworkClientOpenAPIPetstoreExample", targets: ["NovaNetworkClientOpenAPIPetstoreExample"]),
        .executable(name: "NovaNetworkClientCassetteExample", targets: ["NovaNetworkClientCassetteExample"]),
    ],
    traits: [
        .trait(
            name: "EndpointMacros",
            description: """
            Enables the @Endpoint macro and its parameter markers. Off by default: the macro is the \
            only part of this package that needs swift-syntax, and SwiftPM prunes that dependency \
            entirely when the trait is disabled, so the default package graph resolves nothing. \
            Enable it with .package(url: ..., from: "2.11.0", traits: ["EndpointMacros"]).
            """
        ),
    ],
    dependencies: [
        // Only reachable with the EndpointMacros trait enabled; pruned from resolution otherwise.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NovaNetworkCore",
            path: "Sources/NovaNetworkCore"
        ),
        .target(
            name: "NovaNetworkClient",
            dependencies: ["NovaNetworkCore"],
            path: "Sources/NovaNetworkClient"
        ),
        .macro(
            name: "NovaNetworkMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax", condition: .when(traits: ["EndpointMacros"])),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax", condition: .when(traits: ["EndpointMacros"])),
            ],
            path: "Sources/NovaNetworkMacrosPlugin"
        ),
        .target(
            name: "NovaNetworkMacros",
            dependencies: [
                "NovaNetworkCore",
                .target(name: "NovaNetworkMacrosPlugin", condition: .when(traits: ["EndpointMacros"])),
            ],
            path: "Sources/NovaNetworkMacros"
        ),
        .target(
            name: "NovaNetworkOpenAPI",
            path: "Sources/NovaNetworkOpenAPI"
        ),
        .executableTarget(
            name: "NovaNetworkOpenAPIGenerator",
            dependencies: ["NovaNetworkOpenAPI"],
            path: "Sources/NovaNetworkOpenAPIGenerator"
        ),
        .plugin(
            name: "GenerateOpenAPIEndpoints",
            capability: .command(
                intent: .custom(
                    verb: "nova-openapi",
                    description: "Generates NovaNetwork endpoint types from an OpenAPI document."
                ),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes the generated endpoints file into the package."),
                ]
            ),
            dependencies: ["NovaNetworkOpenAPIGenerator"],
            path: "Plugins/GenerateOpenAPIEndpoints"
        ),
        .target(
            // Depends on the transport-neutral core alone, so a preview or demo build can link it
            // without the umbrella client and it still compiles on Linux.
            name: "NovaNetworkCassette",
            dependencies: ["NovaNetworkCore"],
            path: "Sources/NovaNetworkCassette"
        ),
        .target(
            name: "NovaNetworkClientTestSupport",
            dependencies: ["NovaNetworkClient", "NovaNetworkCassette"],
            path: "Sources/NovaNetworkClientTestSupport"
        ),
        .testTarget(
            name: "NovaNetworkClientTests",
            dependencies: ["NovaNetworkClient"],
            path: "Tests/NovaNetworkClientTests"
        ),
        .testTarget(
            name: "NovaNetworkClientTestSupportTests",
            dependencies: ["NovaNetworkClientTestSupport"],
            path: "Tests/NovaNetworkClientTestSupportTests"
        ),
        .testTarget(
            name: "NovaNetworkCoreTests",
            dependencies: ["NovaNetworkCore"],
            path: "Tests/NovaNetworkCoreTests"
        ),
        .testTarget(
            name: "NovaNetworkMacrosTests",
            dependencies: [
                "NovaNetworkMacros",
                .target(name: "NovaNetworkMacrosPlugin", condition: .when(traits: ["EndpointMacros"])),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax", condition: .when(traits: ["EndpointMacros"])),
            ],
            path: "Tests/NovaNetworkMacrosTests"
        ),
        .testTarget(
            name: "NovaNetworkCassetteTests",
            dependencies: ["NovaNetworkCassette", "NovaNetworkClient"],
            path: "Tests/NovaNetworkCassetteTests"
        ),
        .testTarget(
            name: "NovaNetworkOpenAPITests",
            dependencies: ["NovaNetworkOpenAPI", "NovaNetworkPetstoreGenerated", "NovaNetworkClient"],
            path: "Tests/NovaNetworkOpenAPITests"
        ),
        .executableTarget(
            name: "NovaNetworkClientBenchmarks",
            dependencies: ["NovaNetworkClient"],
            path: "Sources/NovaNetworkClientBenchmarks"
        ),
        .executableTarget(
            name: "NovaNetworkClientJSONPlaceholderExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/JSONPlaceholder"
        ),
        .executableTarget(
            name: "NovaNetworkClientBatchTodosExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/BatchTodos"
        ),
        .executableTarget(
            name: "NovaNetworkClientMiddlewareExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/Middleware"
        ),
        .executableTarget(
            name: "NovaNetworkClientOfflineQueueExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/OfflineQueue"
        ),
        .executableTarget(
            name: "NovaNetworkClientWebSocketExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/WebSocket"
        ),
        .executableTarget(
            name: "NovaNetworkClientAuthRefreshReferenceExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/AuthRefreshReference"
        ),
        .executableTarget(
            name: "NovaNetworkClientReconnectRecoveryReferenceExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/ReconnectRecoveryReference"
        ),
        .executableTarget(
            name: "NovaNetworkClientOfflineReplayReferenceExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/OfflineReplayReference"
        ),
        .executableTarget(
            name: "NovaNetworkClientDiagnosticsReferenceExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/DiagnosticsReference"
        ),
        .executableTarget(
            name: "NovaNetworkClientProductionProfileExample",
            dependencies: ["NovaNetworkClient"],
            path: "Examples/ProductionProfile"
        ),
        .target(
            // Checked-in output of `swift package nova-openapi`, in a target that depends on
            // NovaNetworkCore alone: generated code needs neither the macro nor its trait.
            name: "NovaNetworkPetstoreGenerated",
            dependencies: ["NovaNetworkCore"],
            path: "Examples/OpenAPIPetstore/Generated"
        ),
        .executableTarget(
            name: "NovaNetworkClientCassetteExample",
            dependencies: ["NovaNetworkClient", "NovaNetworkCassette"],
            path: "Examples/Cassette"
        ),
        .executableTarget(
            name: "NovaNetworkClientOpenAPIPetstoreExample",
            dependencies: ["NovaNetworkClient", "NovaNetworkPetstoreGenerated"],
            path: "Examples/OpenAPIPetstore",
            exclude: ["petstore.yaml", "Generated"]
        ),
    ]
)
