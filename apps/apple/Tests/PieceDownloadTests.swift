import XCTest
@testable import Browser_Setu

final class PieceDownloadTests: XCTestCase {
    private func response(status: Int = 200, headers: [String: String] = [:], length: Int64 = 50_000_000, url: String = "https://example.com/big.dmg") -> HTTPURLResponse {
        var h = headers; h["Content-Length"] = String(length)
        return HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!
    }

    func testRangesCoverTheFileExactlyOnceWithNoGaps() {
        for total: Int64 in [1, 5_000_000, 8_000_001, 217_000_000, 1_000_000_007] {
            let parts = PiecePlan.ranges(total: total)
            XCTAssertEqual(parts.first?.lowerBound, 0)
            XCTAssertEqual(parts.last?.upperBound, total - 1)
            for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.upperBound + 1, b.lowerBound, "no gap or overlap") }
            XCTAssertEqual(parts.reduce(Int64(0)) { $0 + $1.upperBound - $1.lowerBound + 1 }, total)
            XCTAssertLessThanOrEqual(parts.count, PiecePlan.connections)
        }
        XCTAssertTrue(PiecePlan.ranges(total: 0).isEmpty)
        XCTAssertEqual(PiecePlan.ranges(total: 3_000_000).count, 1, "a small file is not split into slivers")
    }

    func testEligibilityNeedsAPlainLargeHTTPSFileThatAllowsRanges() {
        XCTAssertTrue(PiecePlan.eligible(response: response(headers: ["Accept-Ranges": "bytes"]), request: nil))
        XCTAssertFalse(PiecePlan.eligible(response: response(), request: nil), "no Accept-Ranges")
        XCTAssertFalse(PiecePlan.eligible(response: response(headers: ["Accept-Ranges": "none"]), request: nil))
        XCTAssertFalse(PiecePlan.eligible(response: response(headers: ["Accept-Ranges": "bytes"], length: 1_000_000), request: nil), "too small")
        XCTAssertFalse(PiecePlan.eligible(response: response(headers: ["Accept-Ranges": "bytes", "Content-Encoding": "gzip"]), request: nil), "compressed")
        XCTAssertFalse(PiecePlan.eligible(response: response(headers: ["Accept-Ranges": "bytes"], url: "http://example.com/a.bin"), request: nil), "not https")
        XCTAssertFalse(PiecePlan.eligible(response: response(status: 206, headers: ["Accept-Ranges": "bytes"]), request: nil))
        var post = URLRequest(url: URL(string: "https://example.com/x")!); post.httpMethod = "POST"
        XCTAssertFalse(PiecePlan.eligible(response: response(headers: ["Accept-Ranges": "bytes"]), request: post), "a form post is never repeated")
    }

    func testContentRangeTotal() {
        XCTAssertEqual(PiecePlan.total(fromContentRange: "bytes 0-0/217000000"), 217_000_000)
        XCTAssertNil(PiecePlan.total(fromContentRange: "bytes 0-0/*"))
        XCTAssertNil(PiecePlan.total(fromContentRange: nil))
    }
}
