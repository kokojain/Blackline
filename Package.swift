// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlacklineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlacklineKit", targets: ["BlacklineKit"]),
        .executable(name: "blackline-preview", targets: ["BlacklinePreview"]),
        .executable(name: "blackline-redact", targets: ["BlacklineRedactCLI"]),
    ],
    targets: [
        .target(name: "BlacklineKit"),
        .target(name: "BlacklineIntelligence", dependencies: ["BlacklineKit"]),
        .target(name: "BlacklineRedactor", dependencies: ["BlacklineKit"]),
        .executableTarget(
            name: "BlacklinePreview",
            dependencies: ["BlacklineKit", "BlacklineIntelligence"]
        ),
        .executableTarget(
            name: "BlacklineRedactCLI",
            dependencies: ["BlacklineKit", "BlacklineIntelligence", "BlacklineRedactor"]
        ),
        .testTarget(name: "BlacklineKitTests", dependencies: ["BlacklineKit"]),
        .testTarget(
            name: "BlacklineRedactorTests",
            dependencies: ["BlacklineRedactor", "BlacklineKit"]
        ),
        .testTarget(
            name: "BlacklineIntelligenceTests",
            dependencies: ["BlacklineIntelligence", "BlacklineKit"]
        ),
    ]
)
