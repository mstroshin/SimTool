import XCTest
@testable import SimToolCore

final class XcodebuildFailureTests: XCTestCase {
    // xcodebuild routes the actual cause of a run-script failure to stdout
    // ("command not found"), while stderr carries only the trailing summary.
    func testSurfacesScriptCommandNotFoundFromStdout() {
        let stdout = """
        PhaseScriptExecution Compile\\ assets /path/Script-FAD2A85B.sh
        /path/Script-FAD2A85B.sh: line 4: sampletool: command not found
        Command PhaseScriptExecution failed with a nonzero exit code
        """
        let stderr = """
        ** BUILD FAILED **


        The following build commands failed:
        \tPhaseScriptExecution Compile\\ assets /path/Script-FAD2A85B.sh (in target 'ApplicationAssetsBundle' from project 'ApplicationAssets')
        (2 failures)
        """

        let detail = XcodebuildFailure.detail(stdout: stdout, stderr: stderr)

        XCTAssertTrue(detail.contains("sampletool: command not found"), detail)
        // The summary stays for context.
        XCTAssertTrue(detail.contains("** BUILD FAILED **"), detail)
    }

    func testSurfacesCompilerErrorFromStdout() {
        let stdout = """
        CompileSwift normal arm64 /path/Foo.swift
        /path/Foo.swift:10:5: error: cannot find 'bar' in scope
        """
        let stderr = "** BUILD FAILED **\n(1 failure)"

        let detail = XcodebuildFailure.detail(stdout: stdout, stderr: stderr)

        XCTAssertTrue(detail.contains("cannot find 'bar' in scope"), detail)
    }

    // When neither stream has a recognizable error line, fall back to the
    // previous behavior: stderr if non-empty, else stdout.
    func testFallsBackToStderrWhenNoErrorLines() {
        let stdout = "Building workspace SampleApp with scheme App\nnoise\n"
        let stderr = "** BUILD FAILED **\n(1 failure)"

        let detail = XcodebuildFailure.detail(stdout: stdout, stderr: stderr)

        XCTAssertEqual(detail, "** BUILD FAILED **\n(1 failure)")
    }

    func testFallsBackToStdoutWhenStderrEmpty() {
        let detail = XcodebuildFailure.detail(stdout: "  some build log  \n", stderr: "   ")
        XCTAssertEqual(detail, "some build log")
    }

    // "error:" inside a Swift parameter label (e.g. an `error:` argument in a
    // deprecation warning) is not a compiler diagnostic and must be ignored.
    func testIgnoresErrorColonInsideSwiftParameterLabels() {
        let stdout = """
        /path/Foo.swift:35:29: warning: 'defaultError(title:message:isLoading:error:buttonAction:)' is deprecated: replaced by 'HolaFullscreenAlert.error()'
        /path/Bar.swift:10:5: error: real failure here
        """
        let stderr = "** BUILD FAILED **"

        let detail = XcodebuildFailure.detail(stdout: stdout, stderr: stderr)

        XCTAssertTrue(detail.contains("real failure here"), detail)
        XCTAssertFalse(detail.contains("is deprecated"), detail)
    }

    func testCatchesLineStartingWithErrorColon() {
        let detail = XcodebuildFailure.detail(
            stdout: "error: Build input file cannot be found: '/x.swift'",
            stderr: "** BUILD FAILED **"
        )
        XCTAssertTrue(detail.contains("Build input file cannot be found"), detail)
    }

    // A cause line that also appears in the stderr summary must not be repeated.
    func testDoesNotDuplicateLinesAcrossStreams() {
        let stdout = "/path/Foo.swift:1:1: error: boom\n"
        let stderr = "/path/Foo.swift:1:1: error: boom\n** BUILD FAILED **"

        let detail = XcodebuildFailure.detail(stdout: stdout, stderr: stderr)

        let occurrences = detail.components(separatedBy: "error: boom").count - 1
        XCTAssertEqual(occurrences, 1, detail)
    }
}
