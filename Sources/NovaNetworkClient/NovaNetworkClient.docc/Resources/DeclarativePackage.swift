// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PetstoreApp",
    dependencies: [
        // The EndpointMacros trait is opt-in: without it the package resolves no dependencies.
        .package(
            url: "https://github.com/maxches99/NovaNetwork",
            from: "2.11.0",
            traits: ["EndpointMacros"]
        )
    ],
    targets: [
        .executableTarget(
            name: "PetstoreApp",
            dependencies: [
                .product(name: "NovaNetworkClient", package: "NovaNetwork"),
                .product(name: "NovaNetworkMacros", package: "NovaNetwork"),
            ]
        )
    ]
)
