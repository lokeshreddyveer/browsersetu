import XCTest
@testable import Browser_Setu

/// The userscript header is read the way the format defines it, a pattern that cannot be read never widens where a script runs, and an update can never replace code
/// with a header or quietly gain reach.
final class UserScriptSafetyTests: XCTestCase {
    private func header(_ lines: [String], body: String = "console.log(1);") -> String {
        "// ==UserScript==\n" + lines.map { "// " + $0 }.joined(separator: "\n") + "\n// ==/UserScript==\n" + body
    }

    // MARK: Parsing

    func testATrailingSlashBelongsToTheValue() {
        let meta = UserScriptMetadata.parse(header(["@match https://example.com/", "@include /^https:\\/\\/x\\.test\\//", "@updateURL https://example.com/s.meta.js/"]))
        XCTAssertEqual(meta.matches, ["https://example.com/", "/^https:\\/\\/x\\.test\\//"])
        XCTAssertEqual(meta.updateURL, "https://example.com/s.meta.js/")
    }

    func testAMatchThatEndsInASlashMatchesOnlyThatPageNotEveryPage() {
        XCTAssertTrue(UserScriptMatcher.matches("https://example.com/", patterns: ["https://example.com/"]))
        XCTAssertFalse(UserScriptMatcher.matches("https://example.com/private/page", patterns: ["https://example.com/"]))
        XCTAssertFalse(UserScriptMatcher.matches("https://example.com/private/page", patterns: ["https://example.com"]), "no path means the front page, never every page")
        XCTAssertTrue(UserScriptMatcher.matches("https://example.com/a/b", patterns: ["https://example.com/*"]))
        XCTAssertTrue(UserScriptMatcher.matches("http://example.com/anything", patterns: ["http://example.com*"]), "the older glob form still means 'starts like this'")
    }

    func testARegularExpressionIncludeWorksWithAndWithoutFlags() {
        XCTAssertTrue(UserScriptMatcher.matches("https://x.test/a", patterns: ["/^https:\\/\\/x\\.test\\//"]))
        XCTAssertFalse(UserScriptMatcher.matches("https://y.test/a", patterns: ["/^https:\\/\\/x\\.test\\//"]))
        XCTAssertTrue(UserScriptMatcher.matches("https://x.test/a", patterns: ["/^https:\\/\\/x\\.test\\//i"]))
        XCTAssertNil(UserScriptMatcher.regexSource(for: "/^(/"), "an unreadable expression is refused, not guessed at")
        // Things that are not readable as a regular expression are at most a plain address, which no web page has.
        for odd in ["//", "/abc/zz"] { XCTAssertFalse(UserScriptMatcher.matches("https://abc/zz", patterns: [odd]) || UserScriptMatcher.matches("https://example.com/", patterns: [odd]), odd) }
    }

    func testTheFirstValueWinsForDirectivesThatCanOnlyHaveOne() {
        let meta = UserScriptMetadata.parse(header(["@name Real", "@name Fake", "@version 1.0", "@version 9.9", "@run-at document-start", "@run-at document-end"]))
        XCTAssertEqual(meta.name, "Real")
        XCTAssertEqual(meta.version, "1.0")
        XCTAssertTrue(meta.runAtStart)
    }

    func testManyIncludesExcludesAndGrantsAreKeptWithinTheirLimits() {
        let many = (0..<80).map { "@match https://s\($0).example.com/*" }
        XCTAssertEqual(UserScriptMetadata.parse(header(many)).matches.count, 50)
        let meta = UserScriptMetadata.parse(header(["@match https://a.test/*", "@match https://b.test/*", "@exclude https://a.test/x/*", "@grant GM_getValue", "@grant GM_getValue", "@noframes"]))
        XCTAssertEqual(meta.matches.count, 2)
        XCTAssertEqual(meta.excludes, ["https://a.test/x/*"])
        XCTAssertEqual(meta.grants, ["GM_getValue"], "a grant listed twice is one grant")
        XCTAssertTrue(meta.noFrames)
    }

    func testEmptyMalformedAndHostileHeadersGiveNothingAndRunNothing() {
        XCTAssertFalse(UserScriptMetadata.parse("no header at all").hasHeader)
        let empty = UserScriptMetadata.parse(header(["@match", "@name", "@grant"]))
        XCTAssertTrue(empty.matches.isEmpty && empty.grants.isEmpty)
        let hostile = UserScriptMetadata.parse(header(["@match javascript:alert(1)", "@match file:///etc/*", "@match https://[x", "@match " + String(repeating: "a", count: 600)]))
        // None of them can run on a real page: they are unreadable, or can only match an address no web page has.
        for pattern in hostile.matches {
            for page in ["https://example.com/", "https://x/", "http://a.test/etc/passwd"] { XCTAssertFalse(UserScriptMatcher.matches(page, patterns: [pattern]), pattern) }
        }
        XCTAssertNil(UserScriptMatcher.regexSource(for: String(repeating: "a", count: 600)), "too long to be a pattern")
        XCTAssertNil(UserScriptMatcher.regexSource(for: "file:///etc/*"))
        XCTAssertNil(UserScriptFile.parse(String(repeating: "x", count: UserScript.maxBytes + 1), fallbackName: "Big"))
    }

    func testAnExcludeThatCannotBeReadKeepsTheScriptOffAndNeverRunsIt() throws {
        let text = header(["@name T", "@match https://a.test/*", "@exclude /^(/"])
        let script = try XCTUnwrap(UserScriptFile.parse(text, fallbackName: "T"))
        XCTAssertFalse(script.enabled, "left off rather than run where it was meant to be kept out")
        XCTAssertEqual(script.excludes, ["/^(/"], "the bad line is kept so the person can see and fix it")
        var forced = script; forced.enabled = true
        XCTAssertFalse(UserScriptMatcher.runs(forced, on: "https://a.test/page"), "even forced on, it does not run")
    }

    // MARK: Updates

    func testAFileWithOnlyAHeaderIsNeverTakenForTheScript() {
        XCTAssertFalse(UserScriptMetadata.hasBody(header(["@name T", "@version 2"], body: "")))
        XCTAssertFalse(UserScriptMetadata.hasBody(header(["@name T"], body: "\n// just a note\n")))
        XCTAssertTrue(UserScriptMetadata.hasBody(header(["@name T"], body: "run();")))
    }

    private func installed() throws -> UserScript {
        try XCTUnwrap(UserScriptFile.parse(header(["@name T", "@version 1.0", "@match https://a.test/*", "@noframes", "@grant GM_addStyle"]), fallbackName: "T"))
    }

    func testAnUpdateThatWidensWhereOrWhenItRunsNeedsApprovalAgain() throws {
        let old = try installed()
        XCTAssertFalse(old.allFrames)
        let same = UserScriptUpdate.make(from: header(["@name T", "@version 1.1", "@match https://a.test/*", "@noframes"]), for: old)
        XCTAssertTrue(same.isNewer); XCTAssertFalse(same.needsReapproval, "nothing more than before")
        let frames = UserScriptUpdate.make(from: header(["@name T", "@version 1.1", "@match https://a.test/*"]), for: old)
        XCTAssertTrue(frames.widensFrames && frames.needsReapproval, "now in frames")
        let early = UserScriptUpdate.make(from: header(["@name T", "@version 1.1", "@match https://a.test/*", "@noframes", "@run-at document-start"]), for: old)
        XCTAssertTrue(early.runsEarlier && early.needsReapproval, "now before the page's own scripts")
        let sites = UserScriptUpdate.make(from: header(["@name T", "@version 1.1", "@match https://a.test/*", "@match https://b.test/*", "@noframes"]), for: old)
        XCTAssertEqual(sites.addedPatterns, ["https://b.test/*"]); XCTAssertTrue(sites.needsReapproval)
        let net = UserScriptUpdate.make(from: header(["@name T", "@version 1.1", "@match https://a.test/*", "@noframes", "@grant GM_xmlhttpRequest", "@connect evil.test"]), for: old)
        XCTAssertTrue(net.needsReapproval)
        XCTAssertEqual(net.addedCapabilities, [.network]); XCTAssertEqual(net.addedConnects, ["evil.test"])
    }

    func testTheUpdateFlowReadsTheCodeFromTheDownloadAddressNotFromAHeaderFile() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Shared")
        let text = try String(contentsOf: root.appendingPathComponent("UserScripts.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("UserScriptMetadata.hasBody(text)"), "a header-only reply never replaces the code")
        XCTAssertTrue(text.contains("script.downloadURL != address"))
    }
}
