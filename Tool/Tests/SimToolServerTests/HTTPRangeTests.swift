import XCTest
@testable import SimToolServer

final class HTTPRangeTests: XCTestCase {
    func testNoHeaderServesFullFile() {
        XCTAssertEqual(HTTPRange.parse(header: nil, fileSize: 1000), .full)
    }

    func testClosedRange() {
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=0-99", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 0, length: 100))
        )
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=100-199", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 100, length: 100))
        )
    }

    func testClosedRangeClampsToFileEnd() {
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=900-2000", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 900, length: 100))
        )
    }

    func testOpenEndedRange() {
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=500-", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 500, length: 500))
        )
    }

    func testSuffixRange() {
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=-200", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 800, length: 200))
        )
        // Suffix longer than the file: the whole file.
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=-5000", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 0, length: 1000))
        )
    }

    func testUnsatisfiableRanges() {
        XCTAssertEqual(HTTPRange.parse(header: "bytes=1000-", fileSize: 1000), .unsatisfiable)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=1500-1600", fileSize: 1000), .unsatisfiable)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=-0", fileSize: 1000), .unsatisfiable)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=0-", fileSize: 0), .unsatisfiable)
    }

    func testMalformedHeadersAreIgnored() {
        // RFC 7233: a server may ignore an invalid Range header — serve 200.
        XCTAssertEqual(HTTPRange.parse(header: "items=0-1", fileSize: 1000), .full)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=abc", fileSize: 1000), .full)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=5-2", fileSize: 1000), .full)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=", fileSize: 1000), .full)
        XCTAssertEqual(HTTPRange.parse(header: "bytes=--5", fileSize: 1000), .full)
    }

    func testMultiRangeUsesFirstRange() {
        // Browsers never send multi-range for <video>; we honor the first part.
        XCTAssertEqual(
            HTTPRange.parse(header: "bytes=0-1,5-6", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 0, length: 2))
        )
    }

    func testHeaderIsCaseInsensitiveAndTrimmed() {
        XCTAssertEqual(
            HTTPRange.parse(header: " Bytes=0-9 ", fileSize: 1000),
            .partial(HTTPRange.ByteRange(offset: 0, length: 10))
        )
    }
}
