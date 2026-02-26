// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RequestCoalescer",
    platforms: [.iOS(.v13), .macOS(.v10_15), .watchOS(.v6), .tvOS(.v13)],
    products: [
        .library(name: "RequestCoalescer", targets: ["RequestCoalescer"]),
        .library(name: "RequestCoalescerTestSupport", targets: ["RequestCoalescerTestSupport"]),
        .executable(name: "RequestCoalescerBenchmarks", targets: ["RequestCoalescerBenchmarks"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "RequestCoalescer"
        ),
        .target(
            name: "RequestCoalescerTestSupport",
            dependencies: ["RequestCoalescer"]
        ),
        .testTarget(
            name: "RequestCoalescerTests",
            dependencies: ["RequestCoalescer"]
        ),
        .executableTarget(
            name: "RequestCoalescerBenchmarks",
            dependencies: ["RequestCoalescer"]
        ),
    ]
)
