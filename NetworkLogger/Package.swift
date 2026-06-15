// swift-tools-version: 5.9
import PackageDescription

// Standalone, dependency-free package for the embeddable iOS network logger.
// Kept separate from the main SimTool package so host apps (iOS, gRPC, Tuist) can
// depend on only this product without pulling in macOS-only simulator targets.
let package = Package(
    name: "SimToolNetworkLogger",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .library(name: "SimToolNetworkLogger", targets: ["SimToolNetworkLogger"]),
    ],
    targets: [
        .target(name: "SimToolNetworkLogger"),
        .testTarget(
            name: "SimToolNetworkLoggerTests",
            dependencies: ["SimToolNetworkLogger"]
        ),
    ]
)
