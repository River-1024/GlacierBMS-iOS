// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlacierBMSDomain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "GlacierBMSDomain", targets: ["GlacierBMSDomain"])
    ],
    targets: [
        .target(
            name: "GlacierBMSDomain",
            path: "Sources/Domain"
        ),
        .testTarget(
            name: "GlacierBMSDomainTests",
            dependencies: ["GlacierBMSDomain"],
            path: "Tests/UnitTests"
        )
    ]
)
