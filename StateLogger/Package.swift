// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

// Standalone package for the embeddable model-state logger. Kept separate from the main
// SimTool package (like NetworkLogger) so host apps can depend on only this product.
// iOS floor stays at 15 so SimToolClient consumers don't regress; the Observation-driven
// tracker is gated with @available(iOS 17, macOS 14, *).
let package = Package(
    name: "SimToolStateLogger",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .library(name: "SimToolStateLogger", targets: ["SimToolStateLogger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(name: "SimToolStateLogger", dependencies: ["SimToolStateLoggerMacros"]),
        .macro(
            name: "SimToolStateLoggerMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .testTarget(
            name: "SimToolStateLoggerTests",
            dependencies: ["SimToolStateLogger"]
        ),
        .testTarget(
            name: "SimToolStateLoggerMacrosTests",
            dependencies: [
                "SimToolStateLoggerMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
