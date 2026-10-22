import Foundation
import XCTest
@testable import SimToolCore

final class SimulatorAppLifecycleTests: XCTestCase {
    func testBuildSelectionValidationAndXcodebuildArguments() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: nil, scheme: "App"))
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: workspace.path, projectPath: "Example.xcodeproj", scheme: "App"))
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: workspace.path, projectPath: nil, scheme: nil))

        // Nonexistent paths fail fast: fingerprinting a selection whose parent
        // resolves to "/" would otherwise hash the entire filesystem.
        let missingWorkspace = root.appendingPathComponent("Missing.xcworkspace").path
        let missingProject = root.appendingPathComponent("Missing.xcodeproj").path
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: missingWorkspace, projectPath: nil, scheme: "App")) { error in
            XCTAssertTrue("\(error)".contains("Missing.xcworkspace"))
        }
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: missingProject, scheme: "App")) { error in
            XCTAssertTrue("\(error)".contains("Missing.xcodeproj"))
        }

        let selection = try SimulatorAppBuildSelection.validated(
            workspacePath: workspace.path,
            projectPath: nil,
            scheme: "Example",
            configuration: nil,
            derivedDataPath: root.appendingPathComponent("DerivedData", isDirectory: true).path
        )

        XCTAssertEqual(selection.identity.configuration, "Debug")
        let arguments = SimulatorAppLifecycleClient.xcodebuildArguments(selection: selection, derivedDataPath: selection.identity.derivedDataPath)
        XCTAssertEqual(arguments, [
            "xcodebuild",
            "-workspace", workspace.path,
            "-scheme", "Example",
            "-configuration", "Debug",
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", selection.identity.derivedDataPath!,
            "-hideShellScriptEnvironment",
            "build",
        ])
        // Asking for settings is no build: nothing to hide.
        XCTAssertFalse(
            SimulatorAppLifecycleClient.xcodebuildArguments(selection: selection, derivedDataPath: nil, showBuildSettings: true)
                .contains("-hideShellScriptEnvironment")
        )
    }

    func testBuildSettingsAndADeviceReachTheXcodebuildCommandLine() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var selection = try SimulatorAppBuildSelection.validated(
            workspacePath: workspace.path,
            projectPath: nil,
            scheme: "Example",
            buildSettings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG FLAG", "MACOSX_DEPLOYMENT_TARGET": "15.0"]
        )
        selection.deviceUDID = "DEVICE"

        // Settings follow the options, sorted by key; the device narrows the destination.
        XCTAssertEqual(SimulatorAppLifecycleClient.xcodebuildArguments(selection: selection, derivedDataPath: nil), [
            "xcodebuild",
            "-workspace", workspace.path,
            "-scheme", "Example",
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=DEVICE",
            "-hideShellScriptEnvironment",
            "MACOSX_DEPLOYMENT_TARGET=15.0",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG FLAG",
            "build",
        ])
        let device = SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        XCTAssertEqual(
            SimulatorAppLifecycleClient.xcodebuildTestArguments(selection: selection, device: device, derivedDataPath: nil).suffix(3),
            ["MACOSX_DEPLOYMENT_TARGET=15.0", "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG FLAG", "test"]
        )
    }

    func testBuildSettingsSplitTheCacheButLeaveSettinglessKeysAlone() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let cache = SimulatorAppBuildCache(simtoolDirectory: root.appendingPathComponent(".simtool"))

        let plain = try SimulatorAppBuildSelection.validated(workspacePath: workspace.path, projectPath: nil, scheme: "Example")
        let withSetting = try SimulatorAppBuildSelection.validated(
            workspacePath: workspace.path, projectPath: nil, scheme: "Example", buildSettings: ["MACOSX_DEPLOYMENT_TARGET": "15.0"]
        )

        // A build without settings encodes exactly as before, so existing caches stay valid…
        XCTAssertFalse(try JSON.string(plain.identity).contains("buildSettings"))
        // …while a build with settings never reuses one built without them.
        XCTAssertNotEqual(try cache.identityKey(for: plain.identity), try cache.identityKey(for: withSetting.identity))
        XCTAssertEqual(withSetting.identity.buildSettings, ["MACOSX_DEPLOYMENT_TARGET=15.0"])
    }

    // The first build of a configured DerivedData creates it: before and
    // after, the same path must key the same cache entry.
    func testADerivedDataPathKeysOneEntryWhetherItExistsYetOrNot() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cache = SimulatorAppBuildCache(simtoolDirectory: root.appendingPathComponent(".simtool"), derivedDataRoot: root.appendingPathComponent("managed"))
        // Temporary directories live behind the /var → /private/var symlink.
        let spelled = "/private" + root.standardizedFileURL.path + "/DerivedData"
        func key() throws -> String {
            try cache.identityKey(for: SimulatorAppBuildSelection.validated(
                workspacePath: nil, projectPath: project.path, scheme: "Example", derivedDataPath: spelled
            ).identity)
        }
        let before = try key()
        try FileManager.default.createDirectory(atPath: spelled, withIntermediateDirectories: true)
        XCTAssertEqual(try key(), before)
        XCTAssertEqual(
            SimulatorAppBuildSelection.canonicalPath(spelled + "/Nested/../Deeper/./More"),
            SimulatorAppBuildSelection.canonicalPath(spelled)! + "/Deeper/More"
        )
        XCTAssertEqual(SimulatorAppBuildSelection.canonicalPath("/definitely/not/here"), "/definitely/not/here")
        XCTAssertNil(SimulatorAppBuildSelection.canonicalPath("  "))
    }

    func testBuildSettingEntriesAreKeyEqualsValue() throws {
        XCTAssertEqual(
            try SimulatorAppBuildSelection.parseBuildSettings(["A=1", "B=x=y", "C=", "A=2"]),
            ["A": "2", "B": "x=y", "C": ""]
        )
        XCTAssertThrowsError(try SimulatorAppBuildSelection.parseBuildSettings(["MACOSX_DEPLOYMENT_TARGET 15.0"])) { error in
            XCTAssertTrue("\(error)".contains("KEY=VALUE"))
        }
        XCTAssertThrowsError(try SimulatorAppBuildSelection.parseBuildSettings(["-sdk=iphoneos"]))
        XCTAssertThrowsError(try SimulatorAppBuildSelection.parseBuildSettings(["=1"]))
    }

    func testFingerprintIsDeterministicChangesWithInputsAndSeparatesSchemes() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let first = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        let second = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(first.inputFileCount, 2)

        try write("Sources/App.swift", contents: "struct App { let value = 1 }", root: root)
        let changed = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertNotEqual(first.checksum, changed.checksum)

        let otherScheme = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Other")
        let otherSchemeFingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: otherScheme)
        XCTAssertNotEqual(changed.checksum, otherSchemeFingerprint.checksum)
    }

    func testFingerprintInGitRepoIgnoresGitIgnoredFilesButTracksSource() throws {
        try XCTSkipUnless(gitIsAvailable(), "git not available")
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "objects v1", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        // Generated sources (Tuist's `Derived/`) derive from tracked inputs.
        try write("Derived/Sources/Bundle+Example.swift", contents: "// generated v1", root: root)
        try write(".gitignore", contents: "Derived/\n", root: root)
        runGit(["init"], in: root)
        runGit(["add", "-A"], in: root)

        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let before = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)

        // Rewriting a gitignored generated file must NOT change the checksum —
        // generators rewrite them on every run, which broke cache reuse.
        try write("Derived/Sources/Bundle+Example.swift", contents: "// generated v2 CHANGED BY BUILD", root: root)
        let afterIgnoredChange = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertEqual(before.checksum, afterIgnoredChange.checksum, "gitignored generated files must not affect the source checksum")

        // Mutating a tracked source file MUST change the checksum.
        try write("Sources/App.swift", contents: "struct App { let value = 1 }", root: root)
        let afterTrackedChange = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        XCTAssertNotEqual(before.checksum, afterTrackedChange.checksum, "tracked source changes must change the checksum")
    }

    // A generated workspace and its projects are gitignored, yet they are what
    // xcodebuild builds: the same tracked inputs can generate another project.
    func testGeneratedWorkspaceAndItsProjectsAreInputsEvenWhenGitIgnoresThem() throws {
        try XCTSkipUnless(gitIsAvailable(), "git not available")
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try write("Example.xcworkspace/contents.xcworkspacedata", contents: """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0">
               <FileRef location = "group:Example.xcodeproj"></FileRef>
               <Group location = "group:Modules" name = "Modules">
                  <FileRef location = "group:Feature/Feature.xcodeproj"></FileRef>
               </Group>
            </Workspace>
            """, root: root)
        try write("Example.xcworkspace/xcshareddata/xcschemes/Example.xcscheme", contents: "scheme v1", root: root)
        try write("Example.xcworkspace/xcuserdata/me.xcuserdatad/UserInterfaceState.xcuserstate", contents: "ui v1", root: root)
        try write("Example.xcodeproj/project.pbxproj", contents: "objects v1", root: root)
        try write("Example.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", contents: "pins v1", root: root)
        try write("Modules/Feature/Feature.xcodeproj/project.pbxproj", contents: "feature v1", root: root)
        try write("Modules/Feature/Feature.xcodeproj/xcshareddata/xcschemes/Feature.xcscheme", contents: "feature scheme v1", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        try write(".gitignore", contents: "*.xcworkspace\n*.xcodeproj\n", root: root)
        runGit(["init"], in: root)
        runGit(["add", "-A"], in: root)

        let selection = try SimulatorAppBuildSelection.validated(workspacePath: workspace.path, projectPath: nil, scheme: "Example")
        let inputs = try SimulatorAppBuildFingerprinter.inputFiles(selection: selection).map(\.relativePath)
        for expected in [
            "Example.xcworkspace/contents.xcworkspacedata",
            "Example.xcworkspace/xcshareddata/xcschemes/Example.xcscheme",
            "Example.xcodeproj/project.pbxproj",
            "Example.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "Modules/Feature/Feature.xcodeproj/project.pbxproj",
            "Modules/Feature/Feature.xcodeproj/xcshareddata/xcschemes/Feature.xcscheme",
            "Sources/App.swift",
        ] {
            XCTAssertTrue(inputs.contains(expected), "missing \(expected) in \(inputs)")
        }
        XCTAssertFalse(inputs.contains { $0.contains("xcuserdata") }, "per-user state is no build input")
        XCTAssertEqual(inputs.count, Set(inputs).count, "a file is hashed once")

        let before = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        // Regenerating with the same content is no change: mtimes do not count.
        try write("Modules/Feature/Feature.xcodeproj/project.pbxproj", contents: "feature v1", root: root)
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection), before)
        // A project generated differently is.
        try write("Modules/Feature/Feature.xcodeproj/project.pbxproj", contents: "feature v2 from the binary cache", root: root)
        XCTAssertNotEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection).checksum, before.checksum)
        try write("Modules/Feature/Feature.xcodeproj/project.pbxproj", contents: "feature v1", root: root)
        try write("Example.xcworkspace/xcshareddata/xcschemes/Example.xcscheme", contents: "scheme v2", root: root)
        XCTAssertNotEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection).checksum, before.checksum)
    }

    // Configuration a repository keeps out of git is still read by the build:
    // an edit to it must miss the cache. Ignored directories stay unread.
    func testIgnoredConfigurationFilesCountButIgnoredDirectoriesDoNot() throws {
        try XCTSkipUnless(gitIsAvailable(), "git not available")
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        try write(".env", contents: "API=1", root: root)
        try write("Config/Secrets.xcconfig", contents: "KEY = 1", root: root)
        try write("Config/GoogleService-Info.plist", contents: "<plist/>", root: root)
        try write("Derived/InfoPlists/Example-Info.plist", contents: "<plist>generated</plist>", root: root)
        try write("Sources/Generated.swift", contents: "// generated", root: root)
        try write("build.log", contents: "log", root: root)
        try write(".gitignore", contents: ".env\nSecrets.xcconfig\nGoogleService-Info.plist\nDerived/\nGenerated.swift\n*.log\n", root: root)
        runGit(["init"], in: root)
        runGit(["add", "-A"], in: root)

        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.inputFiles(selection: selection).map(\.relativePath), [
            ".env",
            "Config/GoogleService-Info.plist",
            "Config/Secrets.xcconfig",
            "Example.xcodeproj/project.pbxproj",
            "Sources/App.swift",
        ])
        let before = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        try write("Config/Secrets.xcconfig", contents: "KEY = 2", root: root)
        XCTAssertNotEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection).checksum, before.checksum)
    }

    func testWorkspaceReferencesResolveTheWayXcodeResolvesThem() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("App/App.xcworkspace", isDirectory: true)
        try write("App/App.xcworkspace/contents.xcworkspacedata", contents: """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0">
               <FileRef location = "group:App.xcodeproj"></FileRef>
               <FileRef location = "container:../Shared/Shared.xcodeproj"></FileRef>
               <FileRef location = "absolute:/opt/Vendor/Vendor.xcodeproj"></FileRef>
               <FileRef location = "group:README.md"></FileRef>
               <Group location = "container:Packages" name = "Packages">
                  <Group location = "group:Core" name = "Core">
                     <FileRef location = "group:Core.xcodeproj"></FileRef>
                  </Group>
                  <FileRef location = "group:Kit.xcodeproj"></FileRef>
               </Group>
               <Group name = "Unplaced">
                  <FileRef location = "group:Loose.xcodeproj"></FileRef>
               </Group>
            </Workspace>
            """, root: root)
        let app = root.appendingPathComponent("App", isDirectory: true)
        XCTAssertEqual(SimulatorAppBuildFingerprinter.workspaceProjects(workspace).map(\.path), [
            app.appendingPathComponent("App.xcodeproj").path,
            root.appendingPathComponent("Shared/Shared.xcodeproj").path,
            "/opt/Vendor/Vendor.xcodeproj",
            app.appendingPathComponent("Packages/Core/Core.xcodeproj").path,
            app.appendingPathComponent("Packages/Kit.xcodeproj").path,
            app.appendingPathComponent("Loose.xcodeproj").path,
        ])

        // A project's own embedded workspace refers to the project as `self:`.
        let embedded = root.appendingPathComponent("App/App.xcodeproj/project.xcworkspace", isDirectory: true)
        try write("App/App.xcodeproj/project.xcworkspace/contents.xcworkspacedata", contents: """
            <?xml version="1.0" encoding="UTF-8"?>
            <Workspace version = "1.0"><FileRef location = "self:"></FileRef></Workspace>
            """, root: root)
        XCTAssertEqual(SimulatorAppBuildFingerprinter.workspaceProjects(embedded).map(\.path), [app.appendingPathComponent("App.xcodeproj").path])
        XCTAssertEqual(SimulatorAppBuildFingerprinter.workspaceProjects(root.appendingPathComponent("Missing.xcworkspace")), [])
    }

    // Edits to any of these change what lands in the app, so each must miss
    // the cache; the original list saw only code and a few resource types.
    func testFingerprintSeesResourcesAndBuildFilesBeyondCode() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        let inputs = [
            "Resources/Photo.heic", "Resources/Spinner.gif", "Resources/Intro.mp4", "Resources/Intro.mov",
            "Resources/Ding.caf", "Resources/Ding.mp3", "Resources/Ding.wav", "Resources/Ding.m4a",
            "Resources/Confetti.lottie", "Resources/Brand.ttf", "Resources/Brand.otf", "Resources/Brand.woff2",
            "Resources/Legacy.nib", "Resources/Model.bin", "Resources/PrivacyInfo.xcprivacy", "Resources/Scene.scn",
            "Resources/Art.scnassets/ship.dae", "Resources/Model.mom", "Protos/api.proto",
            "Resources/Localizable.xcstrings", "Scripts/inputs.xcfilelist", "Scripts/generate.sh",
            "Resources/Licenses.txt", "Resources/es.lproj/InfoPlist.unknownext", "Settings.bundle/Root.inc",
            "Model.xcdatamodel/contents", "Resources/pinning.cer", "Vendor/Lib.xcframework/Info.plist",
            "Vendor/libThing.a",
        ]
        for input in inputs { try write(input, contents: "v1 \(input)", root: root) }
        try write("docs/Guide.md", contents: "v1", root: root)
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let baseline = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)

        for input in inputs {
            try write(input, contents: "v2 \(input)", root: root)
            XCTAssertNotEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection).checksum, baseline.checksum, "\(input) is a build input")
            try write(input, contents: "v1 \(input)", root: root)
        }
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection), baseline)
        // Documentation edits do not rebuild the app.
        try write("docs/Guide.md", contents: "v2", root: root)
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: selection), baseline)
    }

    // A project whose .gitignore misses its build directories must get the
    // walk's exclusions from git too: otherwise build products are "sources"
    // — a cache that never hits, and gigabytes hashed on every run. What git
    // tracks was committed on purpose, though, wherever it sits.
    func testGitListingKeepsBuildProductsOutLikeTheWalk() throws {
        try XCTSkipUnless(gitIsAvailable(), "git not available")
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        try write("Tracked/build/Generated.swift", contents: "tracked under build/", root: root)
        runGit(["init"], in: root)
        runGit(["add", "-A"], in: root)
        // Untracked and not ignored: products of builds into the project.
        for product in [
            "DerivedData/Build/Products/Debug-iphonesimulator/Example.app/Info.plist",
            "build/Debug-iphonesimulator/Example.swiftmodule/arm64.json",
            ".simtool/build/abc.json",
            ".swiftpm/configuration/Package.resolved",
            "Products/Build/Intermediates.noindex/Example.build/Objects.json",
            "Products/SourcePackages/checkouts/Lib/Sources/Lib.swift",
        ] {
            try write(product, contents: "product", root: root)
        }

        let configuredDerivedData = root.appendingPathComponent("Products", isDirectory: true)
        let selection = try SimulatorAppBuildSelection.validated(
            workspacePath: nil, projectPath: project.path, scheme: "Example", derivedDataPath: configuredDerivedData.path
        )
        let cacheRoot = root.appendingPathComponent("managed", isDirectory: true)
        try write("managed/abc/Build/Products/Example.swift", contents: "product", root: root)
        let inputs = try SimulatorAppBuildFingerprinter.inputFiles(selection: selection, cacheRoot: cacheRoot).map(\.relativePath)
        XCTAssertEqual(inputs, ["Example.xcodeproj/project.pbxproj", "Sources/App.swift", "Tracked/build/Generated.swift"])

        // The listing is git's: with git gone, the walk keeps the same products
        // out — and, telling no tracked file from another, the committed one too.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        XCTAssertEqual(
            try SimulatorAppBuildFingerprinter.inputFiles(selection: selection, cacheRoot: cacheRoot).map(\.relativePath),
            ["Example.xcodeproj/project.pbxproj", "Sources/App.swift"]
        )
    }

    // What a test run asks before it records anything: is the build on the
    // device the one we are about to judge?
    func testInstallIsNeededOnlyWhenTheDeviceHasSomethingElse() {
        let product = SimulatorAppProductStamp(digest: "p1", fileCount: 3)
        let record = SimulatorAppInstallRecord(
            deviceUDID: "UDID",
            checksum: "abc",
            bundleIdentifier: "com.example.app",
            product: product
        )
        func needsInstall(
            checksum: String = "abc",
            bundleIdentifier: String = "com.example.app",
            product: SimulatorAppProductStamp? = product,
            installed: SimulatorAppInstallRecord? = record,
            xcodebuildRan: Bool = false,
            force: Bool = false
        ) -> Bool {
            SimulatorAppLifecycleClient.needsInstall(
                checksum: checksum, bundleIdentifier: bundleIdentifier, product: product,
                installed: installed, xcodebuildRan: xcodebuildRan, force: force
            )
        }

        XCTAssertFalse(needsInstall())
        XCTAssertTrue(needsInstall(checksum: "def"), "a changed checksum is a different build")
        XCTAssertTrue(needsInstall(bundleIdentifier: "com.example.other"), "a different bundle id is a different app")
        XCTAssertTrue(needsInstall(xcodebuildRan: true), "a fresh xcodebuild means the bundle on the device is stale")
        XCTAssertTrue(needsInstall(installed: nil), "nothing recorded means nothing installed")
        XCTAssertTrue(needsInstall(force: true))
        // The same sources do not make the same bundle: one rebuilt with other
        // settings, or by Xcode, since it was installed is another build.
        XCTAssertTrue(needsInstall(product: SimulatorAppProductStamp(digest: "p2", fileCount: 3)), "another bundle at the same checksum")
        XCTAssertTrue(needsInstall(product: nil), "an unknown bundle cannot be the installed one")
        var legacy = record
        legacy.product = nil
        XCTAssertTrue(needsInstall(installed: legacy), "a record from before product stamps names no bundle")
    }

    func testProductStampChangesWhenAnythingInTheBundleIsRewritten() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeApp(at: root.appendingPathComponent("Example.app", isDirectory: true))
        try Data("dylib v1".utf8).write(to: app.appendingPathComponent("Example.debug.dylib"))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Base.lproj"), withIntermediateDirectories: true)
        try Data("strings".utf8).write(to: app.appendingPathComponent("Base.lproj/Main.strings"))

        let stamp = try XCTUnwrap(SimulatorAppProductStamp(appBundleURL: app))
        XCTAssertEqual(stamp.fileCount, 4)
        XCTAssertEqual(SimulatorAppProductStamp(appBundleURL: app), stamp, "reading it twice reads the same bundle")

        // With ENABLE_DEBUG_DYLIB the executable is a stub: a rebuild relinks
        // the dylib beside it and leaves the stub alone.
        let dylib = app.appendingPathComponent("Example.debug.dylib")
        try Data("dylib v2".utf8).write(to: dylib)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: dylib.path)
        let relinked = try XCTUnwrap(SimulatorAppProductStamp(appBundleURL: app))
        XCTAssertNotEqual(relinked, stamp)

        // A resource rewritten with the same size, at another time.
        let strings = app.appendingPathComponent("Base.lproj/Main.strings")
        try Data("STRINGS".utf8).write(to: strings)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: strings.path)
        XCTAssertNotEqual(SimulatorAppProductStamp(appBundleURL: app), relinked)

        XCTAssertNil(SimulatorAppProductStamp(appBundleURL: root.appendingPathComponent("Missing.app")))
        XCTAssertNil(SimulatorAppProductStamp(appBundleURL: strings), "a file is no bundle")
    }

    // The .app one checksum was recorded for can be rebuilt behind the cache's
    // back — by a build with other settings or by Xcode into the same
    // DerivedData — while the sources come back to that checksum.
    func testACacheEntryMissesOnceItsBundleIsRebuiltByAnythingElse() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let app = try makeApp(at: root.appendingPathComponent("Shared/Build/Products/Debug-iphonesimulator/Example.app", isDirectory: true))
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        var metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            product: SimulatorAppProductStamp(appBundleURL: app)
        )
        try cache.write(metadata)
        XCTAssertTrue(try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache).isCacheHit)

        // Another build relinks the executable in place.
        let executable = app.appendingPathComponent("Example")
        try Data("binary v2 other settings".utf8).write(to: executable)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: executable.path)
        let plan = try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache)
        XCTAssertEqual(plan.fingerprint.checksum, fingerprint.checksum, "the sources are where they were")
        XCTAssertFalse(plan.isCacheHit, "but the bundle is someone else's build")

        // Metadata from before SimTool stamped products cannot tell, so it misses.
        metadata.product = nil
        try cache.write(metadata)
        XCTAssertFalse(try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache).isCacheHit)
        XCTAssertFalse(try JSON.string(metadata).contains("\"product\""), "an absent stamp is left out, not written as null")
    }

    func testCacheMetadataReadWriteValidationCorruptMissesAndInstallRecords() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let simtoolDir = root.appendingPathComponent(".simtool", isDirectory: true)
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: simtoolDir,
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let app = try makeApp(at: root.appendingPathComponent("Build/Example.app", isDirectory: true))
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let metadata = SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: "abc",
            inputFileCount: 2,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            product: SimulatorAppProductStamp(appBundleURL: app)
        )

        try cache.write(metadata)
        // Metadata lands in `.simtool/build/<identityKey>.json`, and writing
        // creates the self-ignoring .gitignore.
        XCTAssertTrue(
            try cache.metadataURL(for: selection.identity).path
                .hasPrefix(simtoolDir.appendingPathComponent("build").path)
        )
        XCTAssertEqual(
            try String(contentsOf: simtoolDir.appendingPathComponent(".gitignore"), encoding: .utf8),
            "*\n"
        )
        let read = try XCTUnwrap(cache.readMetadata(for: selection.identity))
        XCTAssertEqual(read.identity, metadata.identity)
        XCTAssertEqual(read.checksum, metadata.checksum)
        XCTAssertEqual(read.appBundlePath, metadata.appBundlePath)
        XCTAssertEqual(read.bundleIdentifier, metadata.bundleIdentifier)
        XCTAssertEqual(cache.validMetadata(for: selection.identity, checksum: "abc")?.checksum, "abc")

        try cache.recordInstall(identity: selection.identity, checksum: "abc", bundleIdentifier: "com.example.app", deviceUDID: "DEVICE")
        let updated = try XCTUnwrap(cache.readMetadata(for: selection.identity))
        XCTAssertEqual(updated.installRecords["DEVICE"]?.checksum, "abc")

        try FileManager.default.removeItem(at: app)
        XCTAssertNil(cache.validMetadata(for: selection.identity, checksum: "abc"))

        let url = try cache.metadataURL(for: selection.identity)
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(cache.readMetadata(for: selection.identity))
    }

    func testBundleIdentifierDiscovery() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.example.app"],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))

        XCTAssertEqual(try SimulatorAppLifecycleClient.bundleIdentifier(appBundleURL: app), "com.example.app")

        let missing = root.appendingPathComponent("Missing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let missingPlist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Missing"], format: .xml, options: 0)
        try missingPlist.write(to: missing.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.bundleIdentifier(appBundleURL: missing)) { error in
            XCTAssertTrue(error.localizedDescription.contains(missing.path))
        }
    }

    func testRecordExternalBuildWritesCacheHitMetadataAndPrunesStaleInstalls() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")

        // The external .app lives under Build/, which the fingerprinter excludes,
        // so its Info.plist never perturbs the source checksum.
        let app = try makeApp(at: root.appendingPathComponent("Build/Example.app", isDirectory: true))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.app"], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))

        let expected = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        // Pre-existing install records of other builds must be pruned: one for
        // a different checksum, and one for the same checksum but another
        // bundle — what the external build just replaced.
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: "stale",
            inputFileCount: 0,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            installRecords: [
                "DEVICE": SimulatorAppInstallRecord(deviceUDID: "DEVICE", checksum: "stale", bundleIdentifier: "com.example.app"),
                "OTHER": SimulatorAppInstallRecord(
                    deviceUDID: "OTHER",
                    checksum: expected.checksum,
                    bundleIdentifier: "com.example.app",
                    product: SimulatorAppProductStamp(digest: "replaced", fileCount: 2)
                ),
            ]
        ))

        let payload = try SimulatorAppLifecycleClient.recordExternalBuild(selection: selection, appBundleURL: app, cache: cache)

        XCTAssertEqual(payload.checksum, expected.checksum)
        XCTAssertEqual(payload.bundleIdentifier, "com.example.app")
        XCTAssertFalse(payload.cacheHit)
        XCTAssertFalse(payload.xcodebuildRan)

        // run's cache-hit predicate now matches the recorded checksum, and the
        // stale install record is gone.
        let valid = try XCTUnwrap(cache.validMetadata(for: selection.identity, checksum: expected.checksum))
        XCTAssertEqual(valid.appBundlePath, app.standardizedFileURL.path)
        XCTAssertTrue(valid.installRecords.isEmpty)
        XCTAssertEqual(payload.product, SimulatorAppProductStamp(appBundleURL: app))
        XCTAssertEqual(valid.product, payload.product)

        // A missing bundle is a hard error.
        try FileManager.default.removeItem(at: app)
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.recordExternalBuild(selection: selection, appBundleURL: app, cache: cache))
    }

    func testPlanDetectsCacheHitAndBuildFromPlanReusesWithoutXcodebuild() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let app = try makeApp(at: root.appendingPathComponent("Build/Example.app", isDirectory: true))

        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            product: SimulatorAppProductStamp(appBundleURL: app)
        ))

        // Planning is the checksum stage: it fingerprints sources and resolves
        // the cache, without touching xcodebuild.
        let plan = try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache)
        XCTAssertEqual(plan.fingerprint.checksum, fingerprint.checksum)
        XCTAssertTrue(plan.isCacheHit)
        XCTAssertEqual(plan.cachedMetadata?.appBundlePath, app.path)

        // Building from a cache-hit plan reuses the bundle, never running xcodebuild.
        let payload = try await SimulatorAppLifecycleClient.build(plan: plan, cache: cache)
        XCTAssertTrue(payload.cacheHit)
        XCTAssertFalse(payload.xcodebuildRan)
        XCTAssertEqual(payload.appBundlePath, app.path)
        XCTAssertEqual(payload.bundleIdentifier, "com.example.app")
        XCTAssertEqual(payload.checksum, fingerprint.checksum)
    }

    func testBuildsForASimulatorAndForAnyShareOneCacheEntry() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let anySimulator = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let device = SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        let oneSimulator = anySimulator.targeting(device)

        XCTAssertNil(anySimulator.deviceUDID)
        XCTAssertEqual(oneSimulator.deviceUDID, "DEVICE")
        XCTAssertEqual(oneSimulator.identity, anySimulator.identity)
        XCTAssertEqual(try cache.identityKey(for: oneSimulator.identity), try cache.identityKey(for: anySimulator.identity))
        XCTAssertEqual(try cache.derivedDataPath(for: oneSimulator.identity), try cache.derivedDataPath(for: anySimulator.identity))

        // A build for any simulator — say `app build` without --device — is
        // reused by a run that builds for one, and the other way round.
        let app = try makeApp(at: root.appendingPathComponent("Build/Example.app", isDirectory: true))
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: anySimulator, cacheRoot: cache.derivedDataRoot)
        XCTAssertEqual(try SimulatorAppBuildFingerprinter.fingerprint(selection: oneSimulator, cacheRoot: cache.derivedDataRoot), fingerprint)
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: anySimulator.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            product: SimulatorAppProductStamp(appBundleURL: app)
        ))
        XCTAssertTrue(try SimulatorAppLifecycleClient.plan(selection: oneSimulator, cache: cache).isCacheHit)
        XCTAssertTrue(try SimulatorAppLifecycleClient.plan(selection: anySimulator, cache: cache).isCacheHit)

        // On a miss the plan keeps the device, so xcodebuild still gets it.
        let forced = try SimulatorAppLifecycleClient.plan(selection: oneSimulator, force: true, cache: cache)
        XCTAssertTrue(
            SimulatorAppLifecycleClient.xcodebuildArguments(selection: forced.selection, derivedDataPath: forced.derivedDataPath)
                .contains("platform=iOS Simulator,id=DEVICE")
        )
    }

    // `-derivedDataPath` does not decide where the .app lands: Xcode's build
    // location settings can put products next to the workspace. The build's
    // own log says where it wrote it.
    func testTheProductIsTheAppTheBuildLogShowsWritten() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("DerivedData/Build/Products/Debug-iphonesimulator", isDirectory: true)
        let app = try makeApp(at: products.appendingPathComponent("Example.app", isDirectory: true))
        let clip = try makeApp(at: products.appendingPathComponent("ExampleClip.app", isDirectory: true), executable: "ExampleClip")
        let gone = products.appendingPathComponent("Gone.app", isDirectory: true)
        let identity = SimulatorAppBuildIdentity(projectPath: root.appendingPathComponent("Example.xcodeproj").path, scheme: "Example")
        func previous(at url: URL) -> SimulatorAppBuildCacheMetadata {
            SimulatorAppBuildCacheMetadata(identity: identity, checksum: "old", inputFileCount: 1, appBundlePath: url.path, bundleIdentifier: "com.example.app")
        }

        XCTAssertEqual(SimulatorAppLifecycleClient.productInLog([app], scheme: "Other", previous: nil), app)
        XCTAssertEqual(SimulatorAppLifecycleClient.productInLog([gone, app], scheme: "Other", previous: nil), app, "only bundles that exist")
        // An app and its App Clip: the one built before, else the scheme's.
        XCTAssertEqual(SimulatorAppLifecycleClient.productInLog([clip, app], scheme: "Other", previous: previous(at: URL(fileURLWithPath: "/elsewhere/Example.app"))), app)
        XCTAssertEqual(SimulatorAppLifecycleClient.productInLog([clip, app], scheme: "Example", previous: nil), app)
        XCTAssertNil(SimulatorAppLifecycleClient.productInLog([clip, app], scheme: "Other", previous: nil), "ambiguous: ask xcodebuild")
        XCTAssertNil(SimulatorAppLifecycleClient.productInLog([], scheme: "Example", previous: nil))
    }

    // A build with nothing to do writes nothing, so its log names no app: the
    // previous build's bundle is still the product while nothing rebuilt it.
    func testABuildWithNothingToDoKeepsThePreviousProduct() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        let selection = try SimulatorAppBuildSelection.validated(
            workspacePath: nil, projectPath: root.appendingPathComponent("Example.xcodeproj").path, scheme: "Example"
        )
        let app = try makeApp(at: root.appendingPathComponent("Products/Debug-iphonesimulator/Example.app", isDirectory: true))
        let previous = SimulatorAppBuildCacheMetadata(
            identity: selection.identity, checksum: "old", inputFileCount: 1, appBundlePath: app.path,
            bundleIdentifier: "com.example.app", product: SimulatorAppProductStamp(appBundleURL: app)
        )
        let product = try await SimulatorAppLifecycleClient.builtProduct(
            selection: selection, derivedDataPath: root.appendingPathComponent("DD").path, logged: [], previous: previous
        )
        XCTAssertEqual(product.appBundleURL.path, app.path)
    }

    func testBuildLogsLiveBesideTheMetadataOneReplacedPerIdentity() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let simtool = root.appendingPathComponent(".simtool", isDirectory: true)
        let cache = SimulatorAppBuildCache(simtoolDirectory: simtool, derivedDataRoot: root.appendingPathComponent("derived"))
        let identity = SimulatorAppBuildIdentity(projectPath: "/p/App.xcodeproj", scheme: "App")
        let key = try cache.identityKey(for: identity)
        XCTAssertEqual(try cache.logURL(for: identity).path, simtool.appendingPathComponent("build/\(key).log").path)
        XCTAssertEqual(try cache.logURL(for: identity, action: "test").lastPathComponent, "\(key)-test.log")
        XCTAssertNotEqual(
            try cache.logURL(for: SimulatorAppBuildIdentity(projectPath: "/p/App.xcodeproj", scheme: "App", buildSettings: ["A=1"])),
            try cache.logURL(for: identity)
        )
    }

    func testTimeLimitsReadInTheirUnits() {
        XCTAssertEqual(SimulatorAppLifecycleClient.formatDuration(5_400), "1h 30m")
        XCTAssertEqual(SimulatorAppLifecycleClient.formatDuration(2_700), "45m")
        XCTAssertEqual(SimulatorAppLifecycleClient.formatDuration(3_600), "1h")
        XCTAssertEqual(SimulatorAppLifecycleClient.formatDuration(90), "1m 30s")
        XCTAssertEqual(SimulatorAppLifecycleClient.formatDuration(0.2), "0s")
    }

    func testXcodeBuildsKeepACacheEntryOfTheirOwn() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )

        let xcodebuild = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let xcode = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example", builder: .xcodeMCP)

        // An xcodebuild identity encodes as it did before there was a second
        // builder, so existing cache entries stay valid.
        XCTAssertFalse(try JSON.string(xcodebuild.identity, pretty: false).contains("builder"))
        XCTAssertEqual(
            try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example", builder: .xcodebuild).identity,
            xcodebuild.identity
        )
        XCTAssertEqual(xcodebuild.builder, .xcodebuild)
        // Xcode's product comes from its own settings and DerivedData: never
        // handed to an xcodebuild run, nor the other way round.
        XCTAssertEqual(xcode.builder, .xcodeMCP)
        XCTAssertNotEqual(try cache.identityKey(for: xcode.identity), try cache.identityKey(for: xcodebuild.identity))
        // Building for one simulator still shares the entry, as with xcodebuild.
        let device = SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)
        XCTAssertEqual(xcode.targeting(device).identity, xcode.identity)

        // What only xcodebuild can take is refused, not dropped in silence.
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(
            workspacePath: nil, projectPath: project.path, scheme: "Example", derivedDataPath: root.path, builder: .xcodeMCP
        )) { XCTAssertTrue("\($0)".contains("DerivedData its own settings name"), "\($0)") }
        XCTAssertThrowsError(try SimulatorAppBuildSelection.validated(
            workspacePath: nil, projectPath: project.path, scheme: "Example", buildSettings: ["ENABLE_PREVIEWS": "NO"], builder: .xcodeMCP
        )) { XCTAssertTrue("\($0)".contains("own settings"), "\($0)") }
    }

    func testXcodeBuildingAnotherConfigurationFails() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let debug = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example", builder: .xcodeMCP)

        XCTAssertNoThrow(try SimulatorAppLifecycleClient.checkConfiguration("Debug", of: debug))
        XCTAssertNoThrow(try SimulatorAppLifecycleClient.checkConfiguration(nil, of: debug))
        // Xcode builds the scheme's Run configuration; caching a Release app
        // as the Debug one would hand it to every later Debug run.
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.checkConfiguration("Release", of: debug)) { error in
            XCTAssertTrue("\(error)".contains("Run configuration Release, not Debug"), "\(error)")
        }
    }

    func testPlanForceIgnoresValidCache() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)

        let cache = SimulatorAppBuildCache(
            simtoolDirectory: root.appendingPathComponent(".simtool", isDirectory: true),
            derivedDataRoot: root.appendingPathComponent("derived", isDirectory: true)
        )
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")
        let app = try makeApp(at: root.appendingPathComponent("Build/Example.app", isDirectory: true))
        let fingerprint = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection, cacheRoot: cache.derivedDataRoot)
        try cache.write(SimulatorAppBuildCacheMetadata(
            identity: selection.identity,
            checksum: fingerprint.checksum,
            inputFileCount: fingerprint.inputFileCount,
            appBundlePath: app.path,
            bundleIdentifier: "com.example.app",
            product: SimulatorAppProductStamp(appBundleURL: app)
        ))

        XCTAssertTrue(try SimulatorAppLifecycleClient.plan(selection: selection, cache: cache).isCacheHit)
        XCTAssertFalse(try SimulatorAppLifecycleClient.plan(selection: selection, force: true, cache: cache).isCacheHit)
    }

    func testBuildAndLaunchPayloadJSONFields() throws {
        let identity = SimulatorAppBuildIdentity(projectPath: "/tmp/App.xcodeproj", scheme: "App")
        let build = SimulatorAppBuildPayload(
            identity: identity,
            checksum: "abc",
            inputFileCount: 3,
            cacheHit: true,
            xcodebuildRan: false,
            appBundlePath: "/tmp/App.app",
            bundleIdentifier: "com.example.app",
            xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild", ran: false)
        )
        let launch = SimulatorAppLaunchPayload(
            build: build,
            device: SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true),
            launchEnvironment: ["SIMTOOL_NETWORK_LOGGER": "1"],
            launchArguments: ["-DebugFlag", "1234"],
            installed: true,
            launched: true,
            installRan: false,
            launchRan: true,
            install: SimulatorAppProcessStepSummary(name: "simctl install", ran: false),
            launch: SimulatorAppProcessStepSummary(name: "simctl launch", ran: true, status: 0, stdout: "ok")
        )

        let json = try JSON.string(launch, pretty: false)
        XCTAssertTrue(json.contains("\"checksum\":\"abc\""))
        XCTAssertTrue(json.contains("\"cacheHit\":true"))
        XCTAssertTrue(json.contains("\"installed\":true"))
        XCTAssertTrue(json.contains("\"installRan\":false"))
        XCTAssertTrue(json.contains("\"launchRan\":true"))
        XCTAssertTrue(json.contains("\"launchEnvironment\":{"))
        XCTAssertTrue(json.contains("\"SIMTOOL_NETWORK_LOGGER\":\"1\""))
        XCTAssertTrue(json.contains("\"launchArguments\":[\"-DebugFlag\",\"1234\"]"))
        XCTAssertTrue(json.contains("\"bundleIdentifier\":\"com.example.app\""))
    }

    func testSimctlLaunchArgumentsTerminateRunningAndForwardLaunchArguments() {
        let withArgs = SimulatorAppLifecycleClient.simctlLaunchArguments(
            deviceUDID: "DEVICE",
            bundleIdentifier: "com.example.app",
            launchArguments: ["-DebugFlag", "1234", "-AnotherFlag", "value"]
        )
        XCTAssertEqual(withArgs, [
            "simctl", "launch", "--terminate-running-process",
            "DEVICE", "com.example.app",
            "-DebugFlag", "1234", "-AnotherFlag", "value",
        ])

        let withoutArgs = SimulatorAppLifecycleClient.simctlLaunchArguments(
            deviceUDID: "DEVICE",
            bundleIdentifier: "com.example.app"
        )
        XCTAssertEqual(withoutArgs, [
            "simctl", "launch", "--terminate-running-process",
            "DEVICE", "com.example.app",
        ])
    }

    func testLaunchEnvironmentParsingValidationAndSimctlChildEnvironment() throws {
        let environment = try SimulatorAppLifecycleClient.parseLaunchEnvironment([
            "SIMTOOL_NETWORK_LOGGER=1",
            "SIMTOOL_SERVER_URL=http://127.0.0.1:3311/path?token=a=b",
            "EMPTY=",
        ])

        XCTAssertEqual(environment["SIMTOOL_NETWORK_LOGGER"], "1")
        XCTAssertEqual(environment["SIMTOOL_SERVER_URL"], "http://127.0.0.1:3311/path?token=a=b")
        XCTAssertEqual(environment["EMPTY"], "")

        XCTAssertThrowsError(try SimulatorAppLifecycleClient.parseLaunchEnvironment(["INVALID"]))
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.parseLaunchEnvironment(["=value"]))
        XCTAssertThrowsError(try SimulatorAppLifecycleClient.parseLaunchEnvironment(["BAD-KEY=value"]))

        let simctlEnvironment = SimulatorAppLifecycleClient.simctlChildEnvironment(
            launchEnvironment: environment,
            base: ["BASE": "value"]
        )
        XCTAssertEqual(simctlEnvironment["BASE"], "value")
        XCTAssertEqual(simctlEnvironment["SIMCTL_CHILD_SIMTOOL_NETWORK_LOGGER"], "1")
        XCTAssertEqual(simctlEnvironment["SIMCTL_CHILD_SIMTOOL_SERVER_URL"], "http://127.0.0.1:3311/path?token=a=b")
        XCTAssertEqual(simctlEnvironment["SIMCTL_CHILD_EMPTY"], "")
    }

    func testLaunchEnvironmentDoesNotAffectBuildFingerprint() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        try write("Example.xcodeproj/project.pbxproj", contents: "project", root: root)
        try write("Sources/App.swift", contents: "struct App {}", root: root)
        let selection = try SimulatorAppBuildSelection.validated(workspacePath: nil, projectPath: project.path, scheme: "Example")

        let first = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)
        _ = try SimulatorAppLifecycleClient.parseLaunchEnvironment(["SIMTOOL_NETWORK_LOGGER=1"])
        let second = try SimulatorAppBuildFingerprinter.fingerprint(selection: selection)

        XCTAssertEqual(first, second)
    }

    func testXcodebuildTestArgumentsAndPayloadJSONFields() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("Example.xcworkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let derivedData = root.appendingPathComponent("DerivedData", isDirectory: true).path
        let selection = try SimulatorAppBuildSelection.validated(
            workspacePath: workspace.path,
            projectPath: nil,
            scheme: "ExampleUITests",
            configuration: "Debug",
            derivedDataPath: derivedData
        )
        let device = SimulatorDevice(udid: "DEVICE", name: "iPhone", runtime: "iOS", state: "Booted", isAvailable: true)

        XCTAssertEqual(SimulatorAppLifecycleClient.xcodebuildTestArguments(selection: selection, device: device, derivedDataPath: derivedData), [
            "xcodebuild",
            "-workspace", workspace.path,
            "-scheme", "ExampleUITests",
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=DEVICE",
            "-derivedDataPath", derivedData,
            "-hideShellScriptEnvironment",
            "test",
        ])

        let payload = SimulatorAppTestPayload(
            identity: selection.identity,
            device: device,
            passed: false,
            xcodebuildRan: true,
            xcodebuild: SimulatorAppProcessStepSummary(name: "xcodebuild test", ran: true, status: 65, stdout: "failed")
        )
        let json = try JSON.string(payload, pretty: false)
        XCTAssertTrue(json.contains("\"passed\":false"))
        XCTAssertTrue(json.contains("\"xcodebuildRan\":true"))
        XCTAssertTrue(json.contains("\"scheme\":\"ExampleUITests\""))
        XCTAssertTrue(json.contains("\"status\":65"))
    }

    /// A bundle with what a built app has at least: an Info.plist naming the
    /// executable, and the executable.
    @discardableResult
    private func makeApp(at app: URL, executable: String = "Example", bundleIdentifier: String = "com.example.app") throws -> URL {
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier, "CFBundleExecutable": executable],
            format: .xml,
            options: 0
        )
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        try Data("binary v1".utf8).write(to: app.appendingPathComponent(executable))
        return app
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func gitIsAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Avoid leaking the test runner's identity/hooks into the throwaway repo.
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "HOME": directory.path]
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func write(_ relativePath: String, contents: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
}
