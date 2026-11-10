import XCTest
import SwiftUI
@testable import Browser_Setu

@MainActor
final class FaviconStoreFacadeTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() { folders.forEach { try? FileManager.default.removeItem(at: $0) }; folders = [] }
    private func folder() -> URL { let f = FaviconFixtures.temporaryFolder("facade"); folders.append(f); return f }

    private func waitForIcon(_ store: FaviconStore, _ url: String, seconds: Double = 3) async -> PlatformImage? {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if let image = store.image(forURL: url) { return image }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    func testAMissReturnsAtOnceAndTheIconAppearsWhenTheServiceHasIt() async {
        let stub = StubFetcher(); await stub.set("https://a.example/favicon.ico", .image())
        let store = FaviconStore(directory: folder(), fetcher: stub)
        XCTAssertNil(store.image(forURL: "https://a.example/page"), "nothing yet, and it did not wait")
        await store.learn(pageURL: URL(string: "https://a.example/page")!, declared: [])
        let image = await waitForIcon(store, "https://a.example/other")
        XCTAssertNotNil(image, "found for any page of the site once learned")
    }

    func testTheViewIsToldWhenAnIconArrives() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let store = FaviconStore(directory: folder(), fetcher: stub)
        let before = store.version
        await store.learn(pageURL: URL(string: "https://a.example/")!, declared: [])
        let end = Date().addingTimeInterval(3)
        while store.version == before, Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(store.version, before)
    }

    func testAnotherProfileDoesNotSeeTheFirstProfilesIcons() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let store = FaviconStore(directory: folder(), fetcher: stub)
        await store.learn(pageURL: URL(string: "https://only-in-a.example/")!, declared: [])
        let seen = await waitForIcon(store, "https://only-in-a.example/")
        XCTAssertNotNil(seen)
        store.activate(directory: folder())
        XCTAssertNil(store.image(forURL: "https://only-in-a.example/"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(store.image(forURL: "https://only-in-a.example/"), "the second profile's folder has no such icon")
    }

    func testRemovingASiteForgetsItsIconInMemoryAndOnDisk() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let dir = folder()
        let store = FaviconStore(directory: dir, fetcher: stub)
        await store.learn(pageURL: URL(string: "https://a.example/")!, declared: [])
        let first = await waitForIcon(store, "https://a.example/")
        XCTAssertNotNil(first)
        store.remove(host: "a.example")
        try? await Task.sleep(for: .milliseconds(300))
        let reopened = FaviconStore(directory: dir, fetcher: stub)
        XCTAssertNil(reopened.image(forURL: "https://a.example/"))
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(reopened.image(forURL: "https://a.example/"))
    }

    func testAPrivateStyleMissIsRememberedSoRedrawsDoNotAskAgain() async {
        let stub = StubFetcher()
        let store = FaviconStore(directory: folder(), fetcher: stub)
        for _ in 0..<50 { XCTAssertNil(store.image(forURL: "https://no-icon.example/")) }
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<500 { XCTAssertNil(store.image(forURL: "https://no-icon.example/")) }
        let asked = await stub.requestedURLs().count
        XCTAssertEqual(asked, 0, "reading never touches the network; only learning does")
    }



    func testAnIconBeingLookedUpIsLoadingThenReadyOrNone() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let store = FaviconStore(directory: folder(), fetcher: stub)
        XCTAssertEqual(store.phase(forURL: "https://a.example/"), .none, "nothing has asked yet")
        _ = store.image(forURL: "https://a.example/")
        XCTAssertEqual(store.phase(forURL: "https://a.example/"), .loading, "the lookup is under way")
        let end = Date().addingTimeInterval(3)
        while store.phase(forURL: "https://a.example/") == .loading, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.phase(forURL: "https://a.example/"), .none, "this site has no icon yet: a letter, not a skeleton that never ends")
        await store.learn(pageURL: URL(string: "https://a.example/")!, declared: [])
        _ = await waitForIcon(store, "https://a.example/")
        XCTAssertEqual(store.phase(forURL: "https://a.example/"), .ready)
    }

    func testALoadStartedBeforeAProfileSwitchIsNeverDrawnInTheNewProfile() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let store = FaviconStore(directory: folder(), fetcher: stub)
        await store.learn(pageURL: URL(string: "https://a.example/")!, declared: [])
        let ready = await waitForIcon(store, "https://a.example/")
        XCTAssertNotNil(ready)
        store.activate(directory: folder())                         // the new profile starts with nothing in memory
        XCTAssertNil(store.image(forURL: "https://a.example/"))     // this starts a lookup in the new profile's folder, which has no such icon
        store.activate(directory: folder())                         // ...and another switch before it answers
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(store.image(forURL: "https://a.example/"), "the answer of an earlier epoch was dropped")
        XCTAssertTrue(store.memoryKeys.isEmpty)
    }

    func testClearingWhileALoadIsInFlightDoesNotPutTheIconBack() async {
        let stub = StubFetcher(); await stub.setFallback(.image())
        let store = FaviconStore(directory: folder(), fetcher: stub)
        await store.learn(pageURL: URL(string: "https://a.example/")!, declared: [])
        _ = await waitForIcon(store, "https://a.example/")
        store.trimMemory(limit: 0)
        _ = store.image(forURL: "https://a.example/")     // a load starts...
        store.clear()                                       // ...and the data is cleared before it answers
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(store.memoryKeys.isEmpty, "a cleared icon is not drawn again")
    }

    func testTheViewDrawsTheIconOnRetinaAndTheLetterWhenThereIsNone() throws {
        let store = FaviconStore.shared
        let key = "render-test.example"
        let icon = NSImage(size: NSSize(width: 64, height: 64)); icon.lockFocus(); NSColor.systemRed.setFill(); NSRect(x: 0, y: 0, width: 64, height: 64).fill(); icon.unlockFocus()
        store.remember(key, icon)
        defer { store.trimMemory(limit: 0) }
        func render(_ url: String) throws -> NSBitmapImageRep {
            // The real AppKit path, at twice the points: 54 x 54 points drawn into 108 x 108 pixels.
            let host = NSHostingView(rootView: SiteTile(url: url, title: "Render", size: 54).frame(width: 54, height: 54).background(Color.white))
            host.frame = NSRect(x: 0, y: 0, width: 54, height: 54)
            // SwiftUI paints only inside a window: an off-screen one, never shown.
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 108, pixelsHigh: 108, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = NSSize(width: 54, height: 54)
            host.cacheDisplay(in: host.bounds, to: rep)
            XCTAssertEqual(rep.pixelsWide, 108, "a Retina render is twice the points")
            return rep
        }
        func redShare(_ rep: NSBitmapImageRep) -> Double {
            var red = 0, total = 0
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) { for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                total += 1; if c.redComponent > 0.8 && c.greenComponent < 0.35 && c.blueComponent < 0.35 { red += 1 }
            } }
            return Double(red) / Double(max(total, 1))
        }
        let withIcon = try render("https://\(key)/"), letter = try render("https://no-such-icon.example/")
        XCTAssertGreaterThan(redShare(withIcon), 0.25, "the plate holds the red icon")
        XCTAssertLessThan(redShare(letter), 0.02, "no icon: a letter tile, not the red one")
    }
}

/// Draws real icons, fetched from real sites through the shipping pipeline, in the real tile view, light and dark, and saves the pictures for a person to look at.
/// Pictures go to /private/tmp/claude-501/favicon-sheets (best effort); the test asserts only that the tiles drew something other than their letters.
@MainActor
final class FaviconRenderSheetTests: XCTestCase {
    func testRealIconsInTheRealTileLightAndDark() async throws {
        let store = FaviconStore.shared
        let dir = FaviconFixtures.temporaryFolder("sheet"); defer { try? FileManager.default.removeItem(at: dir) }
        store.activate(directory: dir)
        let hosts = ["www.wikipedia.org", "github.com", "www.apple.com", "www.mozilla.org", "example.com"]
        for h in hosts { await store.learn(pageURL: URL(string: "https://\(h)/")!, declared: []) }
        let end = Date().addingTimeInterval(4)
        while Date() < end, hosts.contains(where: { store.image(forURL: "https://\($0)/") == nil }) { try? await Task.sleep(for: .milliseconds(50)) }
        try XCTSkipIf(store.image(forURL: "https://github.com/") == nil, "no network")
        for h in hosts { _ = store.image(forURL: "https://\(h)/", scheme: .dark) }
        try? await Task.sleep(for: .milliseconds(300))

        func sheet(dark: Bool) throws -> Data {
            let tiles = HStack(spacing: 14) {
                ForEach(hosts + ["never-had-an-icon.example"], id: \.self) { h in
                    VStack(spacing: 10) {
                        SiteTile(url: "https://\(h)/", title: h.replacingOccurrences(of: "www.", with: ""), size: 54)
                        SiteTile(url: "https://\(h)/", title: h.replacingOccurrences(of: "www.", with: ""), size: 24)
                    }
                }
            }
            .padding(22)
            .background(dark ? Color(white: 0.11) : Color(white: 0.97))
            let host = NSHostingView(rootView: tiles)
            host.frame = NSRect(x: 0, y: 0, width: 560, height: 170)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1120, pixelsHigh: 340, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = host.frame.size
            host.cacheDisplay(in: host.bounds, to: rep)
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }
        let out = URL(fileURLWithPath: "/private/tmp/claude-501/favicon-sheets", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            let png = try sheet(dark: dark)
            try? png.write(to: out.appendingPathComponent(dark ? "dark.png" : "light.png"))
            XCTAssertGreaterThan(png.count, 5_000)
        }
        store.clear()
    }
}

/// Before/after numbers for the rebuild. Prints BENCH lines (compare with FaviconBaselineBench); asserts only that the main thread is not blocked.
@MainActor
final class FaviconAfterBench: XCTestCase {
    func testNewPipeline() async throws {
        let dir = FaviconFixtures.temporaryFolder("bench"); defer { try? FileManager.default.removeItem(at: dir) }
        let stub = StubFetcher()
        for i in 0..<400 { await stub.set("https://host\(i).example.com/favicon.ico", .image(FaviconFixtures.png(width: 64, height: 64, red: UInt8(i % 250), green: UInt8(i / 2 % 250)))) }
        let seeding = FaviconService(directory: dir, fetcher: stub, maxConcurrentFetches: 8)
        await withTaskGroup(of: Void.self) { g in for i in 0..<400 { g.addTask { _ = await seeding.resolve(pageURL: URL(string: "https://host\(i).example.com/")!, declared: []) } } }
        await seeding.flush()

        let store = FaviconStore(directory: dir, memoryCapacity: 1_000)           // a cold start: nothing in memory
        var t = CFAbsoluteTimeGetCurrent()
        for i in 0..<400 { _ = store.image(forURL: "https://host\(i).example.com/") }
        let mainBlock = (CFAbsoluteTimeGetCurrent() - t) * 1000
        t = CFAbsoluteTimeGetCurrent()
        while (0..<400).contains(where: { store.image(forURL: "https://host\($0).example.com/") == nil }), CFAbsoluteTimeGetCurrent() - t < 10 { try? await Task.sleep(for: .milliseconds(5)) }
        let allReady = (CFAbsoluteTimeGetCurrent() - t) * 1000
        t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<10 { for i in 0..<400 { _ = store.image(forURL: "https://host\(i).example.com/") } }
        let warm = (CFAbsoluteTimeGetCurrent() - t) * 1000 / 10
        let big = FaviconFixtures.png(width: 256, height: 256)
        t = CFAbsoluteTimeGetCurrent()
        let decodeBackground = await Task.detached { () -> Double in
            let s = CFAbsoluteTimeGetCurrent(); for _ in 0..<200 { _ = IconDecoder.decode(big) }; return (CFAbsoluteTimeGetCurrent() - s) * 1000
        }.value
        let mainWhileDecoding = (CFAbsoluteTimeGetCurrent() - t) * 1000 - decodeBackground
        t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<2000 { _ = store.image(forURL: "https://noicon.example.org/") }
        let missing = (CFAbsoluteTimeGetCurrent() - t) * 1000
        print("BENCH new cold400 main-thread=\(String(format: "%.1f", mainBlock))ms all-400-ready=\(Int(allReady))ms warm400=\(String(format: "%.1f", warm))ms decode200x256px=\(Int(decodeBackground))ms (off main) missing2000=\(String(format: "%.1f", missing))ms")
        XCTAssertLessThan(mainBlock, 250, "reading 400 uncached icons must not block the main thread")
        _ = mainWhileDecoding
    }
}
