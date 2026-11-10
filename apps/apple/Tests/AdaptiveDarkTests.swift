import AppKit
import WebKit
import XCTest
@testable import Browser_Setu

/// Adaptive Dark Mode: which pages are darkened and which are left alone, on real pages in a real web view.
@MainActor
final class AdaptiveDarkTests: XCTestCase {
    private func model(_ mode: DarkPages, off: [String] = [], on: [String] = []) async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-dark-\(UUID().uuidString)", profile: "default")
        await m.start()
        m.darkPages = mode
        for site in off { m.setDarkChoice(host: site, .never) }
        for site in on { m.setDarkChoice(host: site, .dark) }
        return m
    }

    private func eval(_ tab: TabController, _ code: String) async -> Any? {
        guard let web = tab.hostView as? WKWebView else { return nil }
        return try? await web.callAsyncJavaScript(code, contentWorld: .page)
    }

    private func page(_ html: String, host: String, model m: BrowserModel, wait: Double = 1.6) async throws -> TabController {
        let tab = m.openTab(url: nil, isPrivate: false)
        (tab.hostView as? WKWebView)?.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        tab.engine.showHTML(html, baseURL: URL(string: "http://\(host)/"))
        try await Task.sleep(for: .seconds(wait))
        return tab
    }

    private func darkened(_ tab: TabController) async -> Bool {
        (await eval(tab, "return !!document.getElementById('__bs_dark__') && document.documentElement.hasAttribute('data-bsd-on');") as? Bool) ?? false
    }

    private let light = "<html><head><title>L</title></head><body style='background:#fff;color:#111'><h1>Light page</h1><p>Some text that is long enough to be a page.</p></body></html>"
    private let dark = "<html><head><title>D</title></head><body style='background:#101418;color:#e8e8e8'><h1>Dark page</h1><p>Some text.</p></body></html>"
    private let declares = "<html><head><meta name='color-scheme' content='light dark'><title>S</title></head><body style='background:#fff;color:#111'><h1>Supports dark</h1></body></html>"
    private let lightOnly = "<html><head><meta name='color-scheme' content='only light'><title>O</title></head><body style='background:#fff;color:#111'><h1>Light only</h1></body></html>"

    func testALightPageIsDarkenedWhenTheSwitchIsAlways() async throws {
        let m = await model(.always)
        let tab = try await page(light, host: "light-a.test", model: m)
        let on = await darkened(tab)
        XCTAssertTrue(on)
    }

    func testNothingChangesWhenTheSwitchIsOff() async throws {
        let m = await model(.off)
        let tab = try await page(light, host: "light-b.test", model: m)
        let on = await darkened(tab)
        XCTAssertFalse(on)
        let visible = await eval(tab, "return getComputedStyle(document.documentElement).opacity;") as? String
        XCTAssertEqual(visible, "1", "and the page is never hidden")
    }

    func testAPageThatIsAlreadyDarkIsLeftAlone() async throws {
        let m = await model(.always)
        let tab = try await page(dark, host: "dark-c.test", model: m)
        let on = await darkened(tab)
        XCTAssertFalse(on)
        let visible = await eval(tab, "return getComputedStyle(document.documentElement).opacity;") as? String
        XCTAssertEqual(visible, "1", "it is shown once judged")
    }

    func testWhatCountsIsHowAPageLooksNotWhatItSays() async throws {
        let m = await model(.always)
        // Says it supports dark but is showing light (a site whose dark theme is switched by a class, not by the device): darkened. Skipping it for the claim made the
        // whole page turn light again when the page was judged a second time.
        let a = try await page(declares, host: "declares-d.test", model: m)
        // Says it supports dark and is showing dark: left alone.
        let declaresAndDark = "<html><head><meta name='color-scheme' content='light dark'><title>S</title></head><body style='background:#101418;color:#e8e8e8'><h1>Dark</h1></body></html>"
        let c = try await page(declaresAndDark, host: "declares-dark-d.test", model: m)
        // Asked to stay light: left alone.
        let b = try await page(lightOnly, host: "lightonly-d.test", model: m)
        let onA = await darkened(a)
        let onB = await darkened(b)
        let onC = await darkened(c)
        XCTAssertTrue(onA, "it looks light, so it is darkened whatever it declares")
        XCTAssertFalse(onB, "the site asked not to be changed")
        XCTAssertFalse(onC, "it is already dark")
    }

    func testThePageStaysDarkAfterScrollingToADarkFooter() async throws {
        let html = """
        <html><head><title>F</title></head><body style='margin:0;background:#fff;color:#111'>
        <div style='height:1800px'>Long light page</div>
        <footer style='height:900px;background:#10151c;color:#eee'>A dark footer</footer></body></html>
        """
        let m = await model(.always)
        let tab = try await page(html, host: "footer-h.test", model: m, wait: 2.0)
        let before = await darkened(tab)
        _ = await eval(tab, "window.scrollTo(0, 2000); await new Promise(r => setTimeout(r, 2500)); return true;")
        let after = await darkened(tab)
        XCTAssertTrue(before)
        XCTAssertTrue(after, "a dark footer under the sample points must not turn the whole page light")
    }

    func testASiteSetToNeverIsNotTouchedAndASiteSetToDarkAlwaysIs() async throws {
        let never = await model(.always, off: ["never-e.test"])
        let a = try await page(light, host: "never-e.test", model: never)
        let onA = await darkened(a)
        XCTAssertFalse(onA)
        let forced = await model(.off, on: ["forced-e.test"])
        let b = try await page(lightOnly, host: "forced-e.test", model: forced)
        let onB = await darkened(b)
        XCTAssertTrue(onB, "chosen by the person: even a page that asked for light, and even with the global switch off")
    }

    func testPicturesAreKeptAndTheFixedHeaderStaysFixed() async throws {
        let html = """
        <html><head><title>P</title></head><body style='margin:0;background:#fff;color:#111;height:3000px'>
        <div id=bar style='position:fixed;top:0;left:0;right:0;height:40px;background:#eee'>bar</div>
        <img id=photo width=60 height=60 src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='60' height='60'><rect width='60' height='60' fill='%23ff0000'/></svg>">
        <div id=hero style="width:80px;height:80px;background-image:url('data:image/svg+xml;utf8,<svg xmlns=%27http://www.w3.org/2000/svg%27 width=%2780%27 height=%2780%27><rect width=%2780%27 height=%2780%27 fill=%27%230000ff%27/></svg>')"></div>
        </body></html>
        """
        let m = await model(.always)
        let tab = try await page(html, host: "pics-f.test", model: m, wait: 2.2)
        let result = await eval(tab, """
        window.scrollTo(0, 800);
        await new Promise(r => setTimeout(r, 300));
        var bar = document.getElementById('bar').getBoundingClientRect();
        return JSON.stringify({
          photoFilter: getComputedStyle(document.getElementById('photo')).filter,
          heroKept: document.getElementById('hero').hasAttribute('data-bsd-keep'),
          barTop: Math.round(bar.top),
          rootFilter: getComputedStyle(document.documentElement).filter
        });
        """) as? String
        let json = try XCTUnwrap(result?.data(using: .utf8))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertTrue((dict["photoFilter"] as? String ?? "").contains("invert"), "the picture is put back by its own opposite filter")
        XCTAssertEqual(dict["heroKept"] as? Bool, true, "a picture used as a background is kept too")
        XCTAssertEqual(dict["barTop"] as? Int, 0, "a fixed header stays at the top of the window after scrolling")
        XCTAssertTrue((dict["rootFilter"] as? String ?? "").contains("invert"))
    }

    func testTheScriptCarriesTheSiteListsAndNothingElse() {
        let source = AdaptiveDarkScript.source(always: true, off: ["a.com"], on: ["b.com"])
        XCTAssertTrue(source.contains("\"a.com\"") && source.contains("\"b.com\"") && source.contains("\"always\""))
        XCTAssertFalse(source.contains("fetch(") || source.contains("XMLHttpRequest") || source.contains("sendBeacon"), "it talks to nobody")
    }

    func testTheSettingTheSiteListsAndTheButtonAgree() async throws {
        let m = await model(.off)
        XCTAssertFalse(m.shouldDarken(host: "x.test"))
        m.toggleDark(host: "x.test")
        XCTAssertEqual(m.darkPages, .chosen, "choosing a site while the setting is Off switches it to Only sites I choose")
        XCTAssertTrue(m.shouldDarken(host: "x.test"))
        XCTAssertFalse(m.shouldDarken(host: "y.test"))
        m.darkPages = .always
        XCTAssertTrue(m.shouldDarken(host: "y.test"))
        m.toggleDark(host: "y.test")
        XCTAssertEqual(m.darkChoice(forHost: "y.test"), .never, "the button in Every light page mode switches one site off")
        XCTAssertFalse(m.shouldDarken(host: "y.test"))
        m.toggleDark(host: "y.test")
        XCTAssertEqual(m.darkChoice(forHost: "y.test"), .dark)
        m.setDarkChoice(host: "y.test", .automatic)
        XCTAssertEqual(m.darkChoice(forHost: "y.test"), .automatic)
        XCTAssertTrue(m.shouldDarken(host: "y.test"))
    }

    /// Writes a picture of a darkened page so it can be looked at (path printed).
    func testSnapshotForLooking() async throws {
        let html = """
        <html><head><title>S</title></head><body style='margin:0;font:16px -apple-system;background:#fff;color:#1a1a1a'>
        <div style='position:fixed;top:0;left:0;right:0;height:44px;background:#f2f2f2;border-bottom:1px solid #ddd;padding:12px'>Header <a href='#' style='color:#0a58ca'>Link</a></div>
        <div style='padding:60px 16px 16px'><h2>Adaptive dark</h2><p>Body text on a white page, <a href='#' style='color:#0a58ca'>a blue link</a> and <b>bold</b>.</p>
        <img width=120 height=60 src="data:image/svg+xml;utf8,<svg xmlns='http://www.w3.org/2000/svg' width='120' height='60'><defs><linearGradient id='g'><stop offset='0' stop-color='%23ff5a00'/><stop offset='1' stop-color='%2300a8ff'/></linearGradient></defs><rect width='120' height='60' fill='url(%23g)'/></svg>">
        <p style='background:#e8f0fe;padding:10px;border-radius:8px'>A light blue card.</p>
        <button style='padding:8px 14px;border-radius:8px;border:0;background:#0a58ca;color:#fff'>Button</button>
        <input value='A text field' style='display:block;margin-top:12px;padding:8px'></div></body></html>
        """
        let m = await model(.always)
        let tab = try await page(html, host: "snap-g.test", model: m, wait: 2.2)
        guard let web = tab.hostView as? WKWebView else { return XCTFail("no web view") }
        let image = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adaptive-dark-snapshot.png")
        try png.write(to: url)
        print("SNAPSHOT \(url.path)")
    }
}
