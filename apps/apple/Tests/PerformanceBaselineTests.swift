import XCTest
@testable import Browser_Setu

/// Prints a baseline ("PERF name = value") for the moments that decide how fast the browser feels, and fails only on a gross regression. The
/// numbers are for comparing one build with the next on the same machine; they are not a comparison with any other browser.
@MainActor
final class PerformanceBaselineTests: XCTestCase {
    private func ms(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testBaseline() async throws {
        let root = NSTemporaryDirectory() + "bs-perf-\(UUID().uuidString)"
        let memory0 = currentMemoryFootprint()
        let model = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        let startup = DispatchTime.now().uptimeNanoseconds
        await model.start()
        print("PERF model-start-ms = \(Double(DispatchTime.now().uptimeNanoseconds - startup) / 1_000_000)")

        var opens: [Double] = []
        for _ in 0..<25 { opens.append(ms { model.newTab() }) }
        print("PERF new-tab-avg-ms = \(opens.reduce(0, +) / Double(opens.count)) max = \(opens.max() ?? 0)")

        let ids = model.tabs.map(\.id)
        var switches: [Double] = []
        for id in ids { switches.append(ms { model.select(id) }) }
        print("PERF tab-switch-avg-ms = \(switches.reduce(0, +) / Double(switches.count)) max = \(switches.max() ?? 0)")

        model.addressBar.isEditing = true
        var suggest: [Double] = []
        for text in ["a", "ap", "app", "apple", "apple.com", "swift ui"] {
            suggest.append(ms { model.addressBar.text = text; model.addressBar.refresh(model: model) })
        }
        print("PERF suggestion-refresh-avg-ms = \(suggest.reduce(0, +) / Double(suggest.count)) max = \(suggest.max() ?? 0)")
        print("PERF memory-growth-25-tabs-MB = \(Double(Int64(currentMemoryFootprint()) - Int64(memory0)) / 1_048_576)")

        XCTAssertLessThan(switches.max() ?? 0, 250, "a tab switch took a quarter of a second")
        XCTAssertLessThan(suggest.max() ?? 0, 100, "suggestions blocked typing for 100 ms")
    }
}

/// What the person feels when they press the + for a new tab while a real page is open: how long the window is held up. The snapshot of the page being left and
/// the extension buttons used to be made on the main thread, which froze the window for a moment.
@MainActor
final class NewTabResponsivenessTests: XCTestCase {
    func testNewTabWhileAPageIsOpenDoesNotHoldUpTheWindow() async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-newtab-\(UUID().uuidString)", profile: "default")
        await model.start()
        let first = model.openTab(url: nil, isPrivate: false)
        let rows = (0..<4000).map { "<p>row \($0) <b>bold</b> <i>italic</i> <a href='#'>link</a></p>" }.joined()
        first.engine.showHTML("<html><body style='background:#eef'>" + rows + "</body></html>", baseURL: URL(string: "https://example.test/"))
        try await Task.sleep(for: .seconds(3))
        var held: [Double] = []
        for _ in 0..<6 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = model.newTab()
            // Until the main thread is free again: a run-loop turn that completes only when nothing else is queued ahead of it.
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            held.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            try await Task.sleep(for: .milliseconds(2500))     // longer than the snapshot throttle, so each round leaves a real page again
            model.select(first.id)
        }
        print("PERF new-tab-held-window-ms = \(held.map { String(format: "%.0f", $0) }.joined(separator: ", "))")
        XCTAssertLessThan(held.max() ?? 0, 150, "pressing + held the window for \(held)")
    }
}

/// How the browser behaves with many tabs: how long they take to open, how fast switching stays, what they cost in memory, and that sleeping tabs come back.
/// Tabs 1...`loaded` hold a real page (each starts its own web process); the rest are blank, as most of a large tab set is after a restore.
@MainActor
final class TabScalingTests: XCTestCase {
    private func run(tabs count: Int, loaded: Int) async throws {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-scale-\(UUID().uuidString)", profile: "default")
        await model.start()
        let memory0 = currentMemoryFootprint()
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<count {
            let tab = model.openTab(url: nil, isPrivate: false)
            if i < loaded { tab.engine.showHTML("<html><body><h1>Page \(i)</h1>" + String(repeating: "<p>text</p>", count: 200) + "</body></html>", baseURL: URL(string: "https://scale\(i).example.test/")) }
        }
        let openMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        try await Task.sleep(for: .seconds(Double(max(3, loaded / 4))))
        var switches: [Double] = []
        for tab in model.tabs.shuffled().prefix(40) {
            let t = DispatchTime.now().uptimeNanoseconds
            model.select(tab.id)
            switches.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1_000_000)
        }
        let grown = Double(Int64(currentMemoryFootprint()) - Int64(memory0)) / 1_048_576
        // The system runs short of memory: older loaded tabs are put to sleep, the one in front never.
        for tab in model.tabs { tab.lastActive = Date().addingTimeInterval(-3600) }
        let front = model.tabs.last!
        model.select(front.id)
        let released = await model.lifecycle?.run(.critical).count ?? 0
        let asleep = model.tabs.filter(\.isDiscarded).count
        print("PERF tabs=\(count) loaded=\(loaded) open-ms=\(Int(openMs)) switch-avg-ms=\(String(format: "%.2f", switches.reduce(0, +) / Double(switches.count))) switch-max-ms=\(String(format: "%.2f", switches.max() ?? 0)) app-memory-growth-MB=\(String(format: "%.1f", grown)) asleep-after-critical=\(asleep)")
        XCTAssertLessThan(switches.max() ?? 0, 250, "switching tabs stayed quick")
        XCTAssertFalse(front.isDiscarded, "the tab in front is never put to sleep")
        if loaded > 3 { XCTAssertGreaterThan(released, 0, "a critical memory event puts some loaded tabs to sleep") }
        // A sleeping tab comes back with its address when it is chosen again.
        if let sleeper = model.tabs.first(where: \.isDiscarded) {
            let address = sleeper.url
            model.select(sleeper.id)
            try await Task.sleep(for: .seconds(2))
            XCTAssertFalse(sleeper.isDiscarded, "choosing a sleeping tab wakes it")
            XCTAssertEqual(sleeper.url, address)
        }
    }

    func testTenTabs() async throws { try await run(tabs: 10, loaded: 10) }
    func testFiftyTabs() async throws { try await run(tabs: 50, loaded: 15) }
    func testAHundredTabs() async throws { try await run(tabs: 100, loaded: 15) }
}
