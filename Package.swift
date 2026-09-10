// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlacklineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BlacklineKit", targets: ["BlacklineKit"]),
    ],
    targets: [
        .target(name: "BlacklineKit"),
        .testTarget(name: "BlacklineKitTests", dependencies: ["BlacklineKit"]),
    ]
)
