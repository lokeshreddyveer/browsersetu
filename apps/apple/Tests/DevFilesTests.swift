import XCTest
import WebKit
@testable import Browser_Setu

final class DevFilesTests: XCTestCase {
    func testWaterfallScalesAndSummarises() {
        let e = [ResourceEntry(name: "a.js", type: "script", startMs: 0, durationMs: 100, transferBytes: 1000),
                 ResourceEntry(name: "b.png", type: "img", startMs: 100, durationMs: 300, transferBytes: 5000)]
        let bars = Waterfall.bars(e)
        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[1].start, 0.25, accuracy: 0.001); XCTAssertEqual(bars[1].length, 0.75, accuracy: 0.001)
        let s = Waterfall.summary(e)
        XCTAssertEqual(s.requests, 2); XCTAssertEqual(s.transferBytes, 6000); XCTAssertEqual(s.slowest, "b.png"); XCTAssertEqual(s.totalMs, 400)
        XCTAssertTrue(Waterfall.bars([]).isEmpty)
    }

    func testResourceEntriesReadWhatThePageReports() {
        let e = ResourceEntry(["name": "https://a.test/x", "type": "fetch", "start": 12.5, "duration": -3, "transfer": 77])
        XCTAssertEqual(e?.type, "fetch"); XCTAssertEqual(e?.durationMs, 0); XCTAssertEqual(e?.transferBytes, 77)
        XCTAssertNil(ResourceEntry(["type": "x"]))
    }

    func testHARIsValidJSONWithTheHonestComment() throws {
        let data = HARWriter.har(page: URL(string: "https://a.test"), entries: [ResourceEntry(name: "https://a.test/x.js", type: "script", startMs: 5, durationMs: 20, transferBytes: 10, status: 200)], started: Date(timeIntervalSince1970: 0))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try XCTUnwrap(root["log"] as? [String: Any])
        XCTAssertEqual(log["version"] as? String, "1.2")
        XCTAssertEqual((log["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertTrue((log["comment"] as? String)?.contains("not available") == true)
    }

    func testStoragePreviewHidesSecretsAndShortensLongValues() {
        XCTAssertEqual(StorageItem.preview("abc123", key: "authToken"), "••••••••")
        XCTAssertEqual(StorageItem.preview("hello", key: "theme"), "hello")
        XCTAssertEqual(StorageItem.preview(String(repeating: "x", count: 200), key: "blob").count, 81)
    }

    func testPerformanceNotesOnlyWhenWarranted() {
        XCTAssertTrue(PagePerformance(["load": 900, "requests": 20, "transfer": 100_000, "nodes": 500]).notes.isEmpty)
        XCTAssertEqual(PagePerformance(["load": 9000, "requests": 300, "transfer": 9_000_000, "nodes": 9000]).notes.count, 4)
    }

    func testDownloadRulesRouteBySiteAndKindAndRefuseUnsafeFolders() {
        let rules = [DownloadRule(host: "", kind: .documents, folder: "Docs"), DownloadRule(host: "work.test", kind: .any, folder: "Work")]
        XCTAssertEqual(DownloadRouting.folder(for: "a.pdf", from: "files.work.test", rules: rules), "Work", "a site rule beats a general one")
        XCTAssertEqual(DownloadRouting.folder(for: "a.pdf", from: "other.test", rules: rules), "Docs")
        XCTAssertNil(DownloadRouting.folder(for: "a.png", from: "other.test", rules: rules))
        XCTAssertNil(DownloadRouting.folder(for: "a.pdf", from: nil, rules: [DownloadRule(host: "x.test", kind: .any, folder: "X")]))
        XCTAssertNil(DownloadRule.cleanFolder("../etc")); XCTAssertNil(DownloadRule.cleanFolder(".hidden")); XCTAssertNil(DownloadRule.cleanFolder(""))
        XCTAssertEqual(DownloadRule.cleanFolder(" Taxes "), "Taxes")
    }

    func testUniqueNamesNeverOverwrite() {
        let taken: Set<String> = ["a.pdf", "a 2.pdf"]
        XCTAssertEqual(DownloadRouting.uniqueName("a.pdf", existing: { taken.contains($0) }), "a 3.pdf")
        XCTAssertEqual(DownloadRouting.uniqueName("b.pdf", existing: { taken.contains($0) }), "b.pdf")
        XCTAssertEqual(DownloadRouting.uniqueName("noext", existing: { $0 == "noext" }), "noext 2")
    }

    func testDuplicatesNeedTheSameSizeAndContents() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("same".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("same".utf8).write(to: dir.appendingPathComponent("b.txt"))
        try Data("diff".utf8).write(to: dir.appendingPathComponent("c.txt"))
        try Data("longer".utf8).write(to: dir.appendingPathComponent("d.txt"))
        let groups = DuplicateFiles.find(in: dir)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.urls.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }
}

final class ElementPickerTests: XCTestCase {
    func testViewportPresetsFitTheScreenAndAreNeverTooSmall() {
        let screen = CGSize(width: 1440, height: 900)
        XCTAssertEqual(ViewportPreset.all.first { $0.id == "phone" }?.fitted(to: screen), CGSize(width: 393, height: 852))
        XCTAssertEqual(ViewportPreset.all.first { $0.id == "desktop" }?.fitted(to: screen), CGSize(width: 1440, height: 900), "never larger than the screen")
        XCTAssertEqual(ViewportPreset(id: "x", title: "x", width: 50, height: 50).fitted(to: screen), CGSize(width: 320, height: 320))
        XCTAssertEqual(Set(ViewportPreset.all.map(\.id)).count, ViewportPreset.all.count)
    }

    func testAPickedElementIsReadSafelyAndMakesCSS() throws {
        let raw: [String: Any] = ["selector": "#main > p.lead", "tag": "p", "width": 300, "height": 24, "text": "Hello", "html": "<p class=\"lead\">Hello</p>", "styles": [["color", "rgb(0, 0, 0)"], ["display", "block"], ["broken"]]]
        let e = try XCTUnwrap(PickedElement(raw))
        XCTAssertEqual(e.styles.count, 2, "a malformed pair is dropped")
        XCTAssertEqual(e.css, "#main > p.lead {\n  color: rgb(0, 0, 0);\n  display: block;\n}")
        XCTAssertNil(PickedElement(nil)); XCTAssertNil(PickedElement(["selector": "", "tag": "p"])); XCTAssertNil(PickedElement(["tag": "p"]))
        let huge = PickedElement(["selector": String(repeating: "a", count: 5000), "tag": "div", "html": String(repeating: "x", count: 9000)])
        XCTAssertEqual(huge?.selector.count, 500); XCTAssertEqual(huge?.html.count, 1200)
    }
}

@MainActor
final class ElementPickerPageTests: XCTestCase {
    func testClickingAnElementOnARealPageDescribesItWithoutChangingThePage() async throws {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pick-\(UUID().uuidString)", profile: "default")
        await m.start()
        let tab = m.openTab(url: nil, isPrivate: false)
        // A page in a test has no window; it is given a size so the points on it exist.
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        tab.engine.showHTML("<html><body style='margin:0'><div id='box' class='card wide' style='width:200px;height:100px;color:rgb(10,20,30);margin:20px'>Pick me</div></body></html>", baseURL: URL(string: "https://pick.example.test/"))
        try await Task.sleep(for: .seconds(1.5))
        let before = await tab.engine.pageText()
        async let result = tab.engine.pickElement()
        try await Task.sleep(for: .milliseconds(400))
        // The picker waits for a pointer press; the test supplies one at the element's centre.
        let web = try XCTUnwrap(tab.hostView as? WKWebView)
        let armed = try? await web.callAsyncJavaScript("return typeof window.__bsCancelPick;", contentWorld: .defaultClient)
        XCTAssertEqual(armed as? String, "function", "the picker is waiting for a click")
        _ = try await web.callAsyncJavaScript("const el = document.getElementById('box').getBoundingClientRect(); const t = document.elementFromPoint(el.left + 10, el.top + 10); t.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true, clientX: el.left + 10, clientY: el.top + 10 }));", contentWorld: .defaultClient)
        let picked = PickedElement(await result)
        XCTAssertEqual(picked?.selector, "#box")
        XCTAssertEqual(picked?.size, CGSize(width: 200, height: 100))
        XCTAssertEqual(picked?.styles.first { $0.name == "color" }?.value, "rgb(10, 20, 30)")
        let after = await tab.engine.pageText()
        XCTAssertEqual(before, after, "the page's content is untouched")
    }
}
