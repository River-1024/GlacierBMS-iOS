// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ANTuRideDomain",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ANTuRideDomain", targets: ["ANTuRideDomain"])
    ],
    targets: [
        .target(
            name: "ANTuRideDomain",
            path: "Sources/Domain"
        ),
        .testTarget(
            name: "ANTuRideDomainTests",
            dependencies: ["ANTuRideDomain"],
            path: "Tests/UnitTests"
        )
    ]
)
