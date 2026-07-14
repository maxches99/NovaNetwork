// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NovaNetworkClient",
    platforms: [.iOS(.v13), .macOS(.v10_15), .watchOS(.v6), .tvOS(.v13)],
    products: [
        .library(name: "NovaNetworkCore", targets: ["NovaNetworkCore"]),
        .library(name: "NovaNetworkClient", targets: ["NovaNetworkClient"]),
        .library(name: "NovaNetworkClientTestSupport", targets: ["NovaNetworkClientTestSupport"]),
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
        .target(
            name: "NovaNetworkClientTestSupport",
            dependencies: ["NovaNetworkClient"],
            path: "Sources/NovaNetworkClientTestSupport"
        ),
        .testTarget(
            name: "NovaNetworkClientTests",
            dependencies: ["NovaNetworkClient"],
            path: "Tests/NovaNetworkClientTests"
        ),
        .testTarget(
            name: "NovaNetworkCoreTests",
            dependencies: ["NovaNetworkCore"],
            path: "Tests/NovaNetworkCoreTests"
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
    ]
)
