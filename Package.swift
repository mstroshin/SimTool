// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

// Lightweight package vending only the embeddable, app-agnostic logger libraries.
// Host apps depend on these via this repo's URL and pull only swift-syntax (for the
// state-logger macro) — none of the simulator CLI's dependencies. The CLI/server/UI
// tooling lives in the Tool/ subdirectory package, which depends back on these.
let package = Package(
    name: "SimTool",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .library(name: "SimToolNetworkLogger", targets: ["SimToolNetworkLogger"]),
        .library(name: "SimToolStateLogger", targets: ["SimToolStateLogger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(name: "SimToolNetworkLogger", path: "NetworkLogger/Sources/SimToolNetworkLogger"),
        .target(
            name: "SimToolStateLogger",
            dependencies: ["SimToolStateLoggerMacros"],
            path: "StateLogger/Sources/SimToolStateLogger"
        ),
        .macro(
            name: "SimToolStateLoggerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "StateLogger/Sources/SimToolStateLoggerMacros"
        ),
        .testTarget(
            name: "SimToolNetworkLoggerTests",
            dependencies: ["SimToolNetworkLogger"],
            path: "NetworkLogger/Tests/SimToolNetworkLoggerTests"
        ),
        .testTarget(
            name: "SimToolStateLoggerTests",
            dependencies: ["SimToolStateLogger"],
            path: "StateLogger/Tests/SimToolStateLoggerTests"
        ),
        .testTarget(
            name: "SimToolStateLoggerMacrosTests",
            dependencies: [
                "SimToolStateLoggerMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "StateLogger/Tests/SimToolStateLoggerMacrosTests"
        ),
    ]
)
