import Foundation
import XCTest
@testable import SimToolCore

final class TestFilePathTests: XCTestCase {
    func testATestInsideTheProjectIsNamedRelativeToIt() {
        XCTAssertEqual(
            TestFilePath.display(
                file: URL(fileURLWithPath: "/repo/.simtool/tests/tab-order.yml"),
                projectRoot: URL(fileURLWithPath: "/repo")
            ),
            ".simtool/tests/tab-order.yml"
        )
    }

    // Someone else's checkout is not a path the reader can use, and it names the
    // sender's machine into the bargain.
    func testATestOutsideTheProjectKeepsItsFileNameOnly() {
        XCTAssertEqual(
            TestFilePath.display(
                file: URL(fileURLWithPath: "/elsewhere/tab-order.yml"),
                projectRoot: URL(fileURLWithPath: "/repo")
            ),
            "tab-order.yml"
        )
    }

    func testWithoutAProjectRootTheFileNameIsAllThereIs() {
        XCTAssertEqual(
            TestFilePath.display(file: URL(fileURLWithPath: "/repo/tests/tab-order.yml"), projectRoot: nil),
            "tab-order.yml"
        )
    }

    // /tmp is a symlink to /private/tmp on macOS, and the two spellings reach
    // this function from different places (a shell's cwd versus a standardized
    // URL). A prefix comparison that does not resolve them reports an absolute
    // path for a file that is plainly inside the project.
    func testSymlinkedTemporaryPathsStillCountAsInsideTheProject() {
        XCTAssertEqual(
            TestFilePath.display(
                file: URL(fileURLWithPath: "/private/tmp/proj/.simtool/tests/a.yml"),
                projectRoot: URL(fileURLWithPath: "/tmp/proj")
            ),
            ".simtool/tests/a.yml"
        )
    }
}
