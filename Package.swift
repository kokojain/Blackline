// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlacklineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlacklineKit", targets: ["BlacklineKit"]),
        .executable(name: "blackline-preview", targets: ["BlacklinePreview"]),
    ],
    targets: [
        .target(name: "BlacklineKit"),
        .target(name: "BlacklineIntelligence", dependencies: ["BlacklineKit"]),
        .executableTarget(
            name: "BlacklinePreview",
            dependencies: ["BlacklineKit", "BlacklineIntelligence"]
        ),
        .testTarget(name: "BlacklineKitTests", dependencies: ["BlacklineKit"]),
        .testTarget(
            name: "BlacklineIntelligenceTests",
            dependencies: ["BlacklineIntelligence", "BlacklineKit"]
        ),
    ]
)
