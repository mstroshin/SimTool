// swift-tools-version: 5.9
import CompilerPluginSupport
import Foundation
import PackageDescription

func selectedDeveloperDir() -> String {
    if let value = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !value.isEmpty {
        return value
    }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    let selected = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return selected?.isEmpty == false ? selected! : "/Applications/Xcode.app/Contents/Developer"
}

let developerDir = selectedDeveloperDir()
let privateFrameworks = "\(developerDir)/Library/PrivateFrameworks"

let package = Package(
    name: "SimTool",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .executable(name: "simtool", targets: ["SimToolCLI"]),
        .library(name: "SimToolClient", targets: ["SimToolClient"]),
        .library(name: "SimToolUI", targets: ["SimToolUI"]),
        // Embeddable, app-agnostic logger libraries that host apps depend on directly.
        .library(name: "SimToolNetworkLogger", targets: ["SimToolNetworkLogger"]),
        .library(name: "SimToolStateLogger", targets: ["SimToolStateLogger"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"700.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.8.1")),
        .package(url: "https://github.com/tuist/Noora", .upToNextMajor(from: "0.15.0")),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        // Embeddable client libraries. Sources live under NetworkLogger/ and StateLogger/
        // (each was its own package); folded into the root manifest so the products are
        // resolvable from this repo's URL by SwiftPM/Tuist consumers.
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
        .target(
            name: "SimToolCore",
            dependencies: [
                "SimToolNetworkLogger",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .target(
            name: "SimToolStream",
            dependencies: ["SimToolCore"],
            swiftSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/PrivateFrameworks",
                    "-F\(privateFrameworks)",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/PrivateFrameworks",
                    "-F\(privateFrameworks)",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/PrivateFrameworks",
                    "-Xlinker", "-rpath", "-Xlinker", privateFrameworks,
                ]),
                .linkedFramework("CoreSimulator"),
                .linkedFramework("SimulatorKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("IOSurface"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .target(
            name: "SimToolWeb",
            dependencies: []
        ),
        .target(
            name: "SimToolServer",
            dependencies: [
                "SimToolCore",
                "SimToolNetworkLogger",
                "SimToolStateLogger",
                "SimToolStream",
                "SimToolWeb",
                .product(name: "Swifter", package: "swifter"),
            ]
        ),
        .target(
            name: "SimToolClient",
            dependencies: [
                "SimToolCore",
                "SimToolNetworkLogger",
                "SimToolStateLogger",
            ]
        ),
        .target(
            name: "SimToolUI",
            dependencies: ["SimToolClient", "SimToolCore", "SimToolStream", "SimToolNetworkLogger"]
        ),
        .executableTarget(
            name: "SimToolCLI",
            dependencies: [
                "SimToolCore",
                "SimToolClient",
                "SimToolNetworkLogger",
                "SimToolServer",
                "SimToolUI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora"),
            ]
        ),
        .testTarget(
            name: "SimToolWebTests",
            dependencies: ["SimToolWeb"]
        ),
        .testTarget(
            name: "SimToolStreamTests",
            dependencies: ["SimToolStream"]
        ),
        .testTarget(
            name: "SimToolCoreTests",
            dependencies: ["SimToolCore", "SimToolNetworkLogger"]
        ),
        .testTarget(
            name: "SimToolClientTests",
            dependencies: ["SimToolClient"]
        ),
        .testTarget(
            name: "SimToolServerTests",
            dependencies: [
                "SimToolClient",
                "SimToolCore",
                "SimToolNetworkLogger",
                "SimToolStateLogger",
                "SimToolServer",
            ]
        ),
        .testTarget(
            name: "SimToolCLITests",
            dependencies: ["SimToolCLI"]
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
