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
        .executableTarget(name: "BlacklinePreview", dependencies: ["BlacklineKit"]),
        .testTarget(name: "BlacklineKitTests", dependencies: ["BlacklineKit"]),
    ]
)
