// swift-tools-version: 5.9
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

// The simtool CLI/server/UI. Kept in a subdirectory package so the embeddable logger
// products at the repo root stay dependency-light for host apps; this package pulls the
// heavier CLI dependencies (argument-parser, Noora, swifter, Yams) and consumes the
// loggers from the root package via a path dependency.
let package = Package(
    name: "SimToolTool",
    platforms: [.macOS(.v14), .iOS(.v15)],
    products: [
        .executable(name: "simtool", targets: ["SimToolCLI"]),
        .library(name: "SimToolClient", targets: ["SimToolClient"]),
        .library(name: "SimToolUI", targets: ["SimToolUI"]),
    ],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMajor(from: "1.8.1")),
        .package(url: "https://github.com/tuist/Noora", .upToNextMajor(from: "0.15.0")),
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "SimToolCore",
            dependencies: [
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
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
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
                .product(name: "SimToolStateLogger", package: "SimTool"),
                "SimToolStream",
                "SimToolWeb",
                .product(name: "Swifter", package: "swifter"),
            ]
        ),
        .target(
            name: "SimToolClient",
            dependencies: [
                "SimToolCore",
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
                .product(name: "SimToolStateLogger", package: "SimTool"),
            ]
        ),
        .target(
            name: "SimToolUI",
            dependencies: [
                "SimToolClient",
                "SimToolCore",
                "SimToolStream",
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
            ]
        ),
        .executableTarget(
            name: "SimToolCLI",
            dependencies: [
                "SimToolCore",
                "SimToolClient",
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
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
            dependencies: ["SimToolCore", .product(name: "SimToolNetworkLogger", package: "SimTool")]
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
                .product(name: "SimToolNetworkLogger", package: "SimTool"),
                .product(name: "SimToolStateLogger", package: "SimTool"),
                "SimToolServer",
            ]
        ),
        .testTarget(
            name: "SimToolCLITests",
            dependencies: ["SimToolCLI"]
        ),
    ]
)
