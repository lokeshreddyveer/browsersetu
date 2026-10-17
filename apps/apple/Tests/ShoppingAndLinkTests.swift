import XCTest
@testable import Browser_Setu

final class ShoppingAndLinkTests: XCTestCase {
    func testSubscriptionRollsForwardToNextRealCharge() {
        let cal = Calendar(identifier: .gregorian)
        let start = cal.date(from: DateComponents(year: 2025, month: 1, day: 31))!
        let sub = Subscription(name: "Music", amount: 10, period: .monthly, nextRenewal: start)
        let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 15))!
        XCTAssertGreaterThanOrEqual(sub.nextCharge(after: now, calendar: cal), cal.startOfDay(for: now))
        XCTAssertLessThan(sub.nextCharge(after: now, calendar: cal), cal.date(byAdding: .month, value: 1, to: now)!)
    }

    func testMonthlyTotalAndRenewingSoon() {
        let now = Date()
        let list = [Subscription(name: "A", amount: 12, period: .yearly, nextRenewal: now.addingTimeInterval(86400 * 2)),
                    Subscription(name: "B", amount: 10, period: .monthly, nextRenewal: now.addingTimeInterval(86400 * 20))]
        XCTAssertEqual(SubscriptionMath.monthlyTotal(list), 11, accuracy: 0.001)
        XCTAssertEqual(SubscriptionMath.renewingSoon(list, now: now).map(\.name), ["A"])
    }

    func testWireFramesRoundTripAndSplitAcrossReads() throws {
        let a = LinkMessage(kind: .text, name: nil, text: "hello", data: nil)
        let b = LinkMessage(kind: .file, name: "x.bin", text: nil, data: Data([1, 2, 3]))
        var buffer = try LinkWire.frame(a) + LinkWire.frame(b)
        let tail = buffer.suffix(5)
        buffer = Data(buffer.dropLast(5))
        var first = try LinkWire.unframe(&buffer)
        XCTAssertEqual(first, [a])
        buffer.append(tail)
        first = try LinkWire.unframe(&buffer)
        XCTAssertEqual(first, [b])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOversizedFrameIsRejected() {
        var bad = Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data(repeating: 0, count: 8)
        XCTAssertThrowsError(try LinkWire.unframe(&bad))
    }

    func testCodeIsLongRandomAndKeyDependsOnEveryCharacter() {
        let code = LinkWire.makeCode()
        XCTAssertEqual(code.count, LinkWire.codeLength)
        XCTAssertTrue(code.allSatisfy { LinkWire.alphabet.contains($0) })
        XCTAssertNotEqual(code, LinkWire.makeCode(), "two codes are not the same")
        XCTAssertEqual(LinkWire.key(forCode: code), LinkWire.key(forCode: code))
        var other = Array(code); other[0] = other[0] == "A" ? "B" : "A"
        XCTAssertNotEqual(LinkWire.key(forCode: code), LinkWire.key(forCode: String(other)))
        XCTAssertEqual(LinkWire.key(forCode: code).count, 32)
    }

    func testTypedCodesAreReadForgivinglyAndRefusedWhenIncomplete() {
        let code = "0123456789ABCDEFGHJK"
        XCTAssertEqual(LinkWire.normalized(LinkWire.formatted(code)), code)
        XCTAssertEqual(LinkWire.normalized("o1l3456789abcdefghjk"), "01134567" + "89ABCDEFGHJK", "look-alike letters and lower case are accepted")
        XCTAssertNil(LinkWire.normalized("123456"), "a six-digit code is not a code any more")
        XCTAssertNil(LinkWire.normalized(String(repeating: "U", count: 20)), "letters outside the alphabet are refused")
        XCTAssertEqual(LinkWire.formatted(code), "01234-56789-ABCDE-FGHJK")
    }

    func testReceivedFileNamesCannotEscapeTheFolder() {
        XCTAssertEqual(LinkWire.safeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(LinkWire.safeFileName(".hidden"), "Received File")
        XCTAssertEqual(LinkWire.safeFileName(""), "Received File")
    }

    func testVideoDetectionReadsFlags() {
        let v = DetectedVideo(index: 2, raw: ["tag": "video", "duration": 125.0, "currentTime": 10.0, "paused": true, "rate": 1.5, "hasMediaKeys": true])
        XCTAssertEqual(v.title, "Video · 2:05")
        XCTAssertTrue(v.protected)
        XCTAssertEqual(v.rate, 1.5)
        XCTAssertEqual(DetectedVideo.clock(3725), "1:02:05")
    }
}
