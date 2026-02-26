// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "NovaNetworkClient",
    platforms: [.iOS(.v13), .macOS(.v10_15), .watchOS(.v6), .tvOS(.v13)],
    products: [
        .library(name: "NovaNetworkClient", targets: ["NovaNetworkClient"]),
        .library(name: "NovaNetworkClientTestSupport", targets: ["NovaNetworkClientTestSupport"]),
        .executable(name: "NovaNetworkClientBenchmarks", targets: ["NovaNetworkClientBenchmarks"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "NovaNetworkClient",
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
        .executableTarget(
            name: "NovaNetworkClientBenchmarks",
            dependencies: ["NovaNetworkClient"],
            path: "Sources/NovaNetworkClientBenchmarks"
        ),
    ]
)
