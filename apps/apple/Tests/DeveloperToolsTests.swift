import XCTest
@testable import Browser_Setu

final class DeveloperToolsTests: XCTestCase {
    func testJSONFormatting() {
        XCTAssertEqual(DevUtilities.formatJSON("{\"b\":1,\"a\":[1,2]}", pretty: false), .ok("{\"a\":[1,2],\"b\":1}"))
        if case .ok(let pretty) = DevUtilities.formatJSON("{\"a\":1}") { XCTAssertTrue(pretty.contains("\n")) } else { XCTFail() }
        if case .failed = DevUtilities.formatJSON("{oops") {} else { XCTFail("bad JSON must fail") }
        if case .failed = DevUtilities.formatJSON("  ") {} else { XCTFail("empty must fail") }
    }

    func testURLAndBase64() {
        XCTAssertEqual(DevUtilities.urlEncode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9")
        XCTAssertEqual(DevUtilities.urlDecode("a%20b+c"), "a b c")
        XCTAssertNil(DevUtilities.urlDecode("%E0%A4%A"))
        XCTAssertEqual(DevUtilities.base64Encode("hello"), "aGVsbG8=")
        XCTAssertEqual(DevUtilities.base64Decode("aGVsbG8"), "hello", "padding is optional")
        XCTAssertEqual(DevUtilities.base64Decode(DevUtilities.base64Encode("a?b>c~", urlSafe: true)), "a?b>c~")
        XCTAssertNil(DevUtilities.base64Decode("***"))
    }

    func testTimestamps() throws {
        let utc = TimeZone(identifier: "UTC")!
        let s = try XCTUnwrap(DevUtilities.readTimestamp("0", zone: utc))
        XCTAssertEqual(s.utc, "1970-01-01T00:00:00Z")
        XCTAssertEqual(try XCTUnwrap(DevUtilities.readTimestamp("1700000000000", zone: utc)).unit, "milliseconds")
        XCTAssertEqual(try XCTUnwrap(DevUtilities.readTimestamp("1700000000000", zone: utc)).seconds, 1_700_000_000)
        XCTAssertNil(DevUtilities.readTimestamp("abc"))
        XCTAssertEqual(DevUtilities.timestamp(fromISO: "2023-11-14T22:13:20Z"), 1_700_000_000)
        XCTAssertEqual(DevUtilities.timestamp(fromISO: "1970-01-02"), 86_400)
    }

    func testRegex() {
        guard case .matches(let m) = DevUtilities.testRegex("(\\w+)@(\\w+)\\.com", in: "a@b.com and c@d.com") else { return XCTFail() }
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].groups, ["a", "b"])
        if case .failed = DevUtilities.testRegex("(", in: "x") {} else { XCTFail("an invalid pattern must fail") }
        guard case .matches(let none) = DevUtilities.testRegex("Z", in: "abc", flags: "") else { return XCTFail() }
        XCTAssertTrue(none.isEmpty)
        guard case .matches(let ci) = DevUtilities.testRegex("ABC", in: "abc", flags: "i") else { return XCTFail() }
        XCTAssertEqual(ci.count, 1)
    }

    func testColours() throws {
        let c = try XCTUnwrap(DevUtilities.parseColor("#f00"))
        XCTAssertEqual(DevUtilities.describeColor(c), DevUtilities.ColorValues(hex: "#FF0000", rgb: "rgb(255, 0, 0)", hsl: "hsl(0, 100%, 50%)"))
        XCTAssertEqual(DevUtilities.describeColor(try XCTUnwrap(DevUtilities.parseColor("rgb(0, 0, 255)"))).hex, "#0000FF")
        XCTAssertEqual(DevUtilities.describeColor(try XCTUnwrap(DevUtilities.parseColor("hsl(120, 100%, 50%)"))).hex, "#00FF00")
        XCTAssertNil(DevUtilities.parseColor("rgb(300, 0, 0)"))
        XCTAssertNil(DevUtilities.parseColor("nonsense"))
    }

    func testDiffAndHashes() {
        let d = DevUtilities.diffLines("a\nb\nc", "a\nx\nc")
        XCTAssertEqual(d.removed, ["b"]); XCTAssertEqual(d.added, ["x"]); XCTAssertEqual(d.same, 2)
        XCTAssertEqual(DevUtilities.hash("abc", .sha256), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(DevUtilities.hash("abc", .md5), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(DevUtilities.hash("abc", .sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(DevUtilities.hash("", .sha256).count, 64)
    }

    func testDevLogParsingAndExport() {
        let raw: [String: Any] = ["console": [["level": "error", "text": "boom", "at": 1_700_000_000_000.0]], "ws": [["url": "wss://x.test/s", "state": "open", "sent": 2, "received": 5, "bytesSent": 10, "bytesReceived": 50, "opened": 1_700_000_000_000.0]],
                                  "failed": [["url": "https://ads.test/a.js", "tag": "script", "blocked": true]]]
        let log = DevLog(raw: raw)
        XCTAssertEqual(log.console.count, 1)
        XCTAssertTrue(log.consoleText.contains("[error] boom"))
        XCTAssertEqual(log.sockets.first?.received, 5)
        XCTAssertTrue(log.socketText.contains("wss://x.test/s"))
        XCTAssertEqual(log.failed.first?.blocked, true)
    }

    func testSecurityHeaderNotes() {
        let none = ResponseHeaders.securityNotes([])
        XCTAssertEqual(none.count, 5)
        let good = ResponseHeaders.securityNotes([("Strict-Transport-Security", "max-age=1"), ("Content-Security-Policy", "frame-ancestors 'none'"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer")])
        XCTAssertTrue(good.isEmpty)
    }
}

final class NetworkAndAutofillTests: XCTestCase {
    func testInterfaceKinds() {
        XCTAssertEqual(NetworkInterfaces.kind(of: "lo0"), "Loopback")
        XCTAssertEqual(NetworkInterfaces.kind(of: "utun3"), "VPN or tunnel")
        XCTAssertEqual(NetworkInterfaces.kind(of: "pdp_ip0"), "Cellular")
        XCTAssertEqual(NetworkInterfaces.kind(of: "en0"), "Wi-Fi or Ethernet")
    }

    func testCaptivePortalClassification() {
        XCTAssertEqual(CaptivePortal.classify(status: 200, body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>", redirected: false, error: nil), .clear)
        if case .suspected = CaptivePortal.classify(status: 200, body: "Please sign in", redirected: false, error: nil) {} else { XCTFail() }
        if case .suspected = CaptivePortal.classify(status: 302, body: "", redirected: true, error: nil) {} else { XCTFail() }
        if case .unknown = CaptivePortal.classify(status: nil, body: "", redirected: false, error: "offline") {} else { XCTFail() }
    }

    func testBreakdownGroupsByKind() {
        let rows = ResourceBreakdown.rows([ResourceEntry(name: "a.js", type: "script", startMs: 0, durationMs: 1, transferBytes: 100), ResourceEntry(name: "b.js", type: "script", startMs: 0, durationMs: 1, transferBytes: 50),
                                           ResourceEntry(name: "c.png", type: "img", startMs: 0, durationMs: 1, transferBytes: 500)])
        XCTAssertEqual(rows.map(\.type), ["img", "script"])
        XCTAssertEqual(rows.last?.count, 2)
        XCTAssertEqual(rows.last?.bytes, 150)
    }

    func testPathSummary() {
        XCTAssertEqual(PathInfo(online: false).summary, "Offline")
        XCTAssertEqual(PathInfo(constrained: true).summary, "Low Data Mode")
        XCTAssertEqual(PathInfo(expensive: true).summary, "Metered connection")
        XCTAssertEqual(PathInfo().summary, "Normal")
    }

    func testPasswordStrength() {
        XCTAssertTrue(PasswordStrength.evaluate("password").isWeak)
        XCTAssertTrue(PasswordStrength.evaluate("123456").isWeak)
        XCTAssertTrue(PasswordStrength.evaluate("aaaaaaaaaaaa").isWeak)
        XCTAssertTrue(PasswordStrength.evaluate("short1").isWeak)
        XCTAssertGreaterThanOrEqual(PasswordStrength.evaluate("c0rrect-Horse-battery-staple!").score, 3)
        XCTAssertGreaterThanOrEqual(PasswordStrength.evaluate(PasswordGenerator.make()).score, 3)
        XCTAssertLessThan(PasswordStrength.evaluate("Summer2024!", user: "summer").bits, PasswordStrength.evaluate("Summer2024!").bits)
        XCTAssertEqual(PasswordStrength.evaluate("").score, 0)
    }

    func testAddressNameSplitAndEmptiness() {
        let a = SavedAddress(name: "Ada King Lovelace", street: "1 Main St")
        XCTAssertEqual(a.given, "Ada"); XCTAssertEqual(a.family, "King Lovelace")
        XCTAssertFalse(a.isEmpty)
        XCTAssertTrue(SavedAddress(label: "Home").isEmpty)
        XCTAssertTrue(AddressFill.script(for: a).contains("\"given-name\""))
    }
}
