// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlacklineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlacklineKit", targets: ["BlacklineKit"]),
        .executable(name: "blackline-preview", targets: ["BlacklinePreview"]),
        .executable(name: "blackline-redact", targets: ["BlacklineRedactCLI"]),
        .executable(name: "Blackline", targets: ["BlacklineApp"]),
    ],
    targets: [
        .target(name: "BlacklineKit"),
        .target(name: "BlacklineIntelligence", dependencies: ["BlacklineKit"]),
        .target(name: "BlacklineOCR"),
        .target(name: "BlacklineRedactor", dependencies: ["BlacklineKit", "BlacklineOCR"]),
        .executableTarget(
            name: "BlacklinePreview",
            dependencies: ["BlacklineKit", "BlacklineIntelligence"]
        ),
        .target(
            name: "BlacklineUI",
            dependencies: ["BlacklineKit", "BlacklineRedactor", "BlacklineIntelligence"]
        ),
        .executableTarget(name: "BlacklineApp", dependencies: ["BlacklineUI"]),
        .executableTarget(
            name: "BlacklineRedactCLI",
            dependencies: ["BlacklineKit", "BlacklineIntelligence", "BlacklineRedactor"]
        ),
        .testTarget(name: "BlacklineKitTests", dependencies: ["BlacklineKit"]),
        .testTarget(name: "BlacklineOCRTests", dependencies: ["BlacklineOCR"]),
        .testTarget(
            name: "BlacklineUITests",
            dependencies: ["BlacklineUI", "BlacklineKit", "BlacklineRedactor"]
        ),
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
