import XCTest
import SwiftUI
import AppKit
import WebKit
@testable import Browser_Setu

/// Stage 3: what switching tabs costs, measured with the real `MacRootView` in an on-screen window (nearly transparent, so WebKit really renders), on deterministic local
/// pages. Per switch: T1 the selection is committed (`select` returns); T3 the destination web view joins the window (`ActivationProbe`); T5 (proxy) the destination page
/// answers two animation frames after the switch; and the longest the main thread took to answer a 2 ms ping during that switch (`MainLatencyMonitor`), which is the
/// app's own responsiveness, not the test runner's waiting. Throwaway profile per run; no addresses or titles are recorded.
@MainActor
final class Stage3TabActivationTests: XCTestCase {

    /// Pings the main thread every 2 ms from a background queue and records how long each ping waited. A ping sent while the main thread is busy for 300 ms waits
    /// about 300 ms, so the samples show stalls on the app's own clock.
    final class MainLatencyMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingSince: Double?
        private var samples: [(sent: Double, ms: Double)] = []
        private var timer: DispatchSourceTimer?

        func start() {
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "stage3.main-latency", qos: .userInteractive))
            source.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .microseconds(200))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.pendingSince == nil {
                    let sent = ProcessInfo.processInfo.systemUptime
                    self.pendingSince = sent
                    self.lock.unlock()
                    DispatchQueue.main.async {
                        let answered = ProcessInfo.processInfo.systemUptime
                        self.lock.lock(); self.samples.append((sent, (answered - sent) * 1000)); self.pendingSince = nil; self.lock.unlock()
                    }
                } else { self.lock.unlock() }
            }
            source.resume()
            timer = source
        }
        func stop() { timer?.cancel(); timer = nil }
        /// The longest wait of a ping sent in [from, to].
        func longest(from: Double, to: Double) -> Double {
            lock.lock(); defer { lock.unlock() }
            return samples.filter { $0.sent >= from && $0.sent <= to }.map(\.ms).max() ?? 0
        }
        func count(over ms: Double, from: Double, to: Double) -> Int {
            lock.lock(); defer { lock.unlock() }
            // A stall is one run of slow pings; count runs, not pings.
            var runs = 0, inRun = false
            for s in samples where s.sent >= from && s.sent <= to {
                if s.ms > ms { if !inRun { runs += 1 }; inRun = true } else { inRun = false }
            }
            return runs
        }
    }

    struct Stats: CustomStringConvertible {
        let values: [Double]
        var description: String {
            guard !values.isEmpty else { return "n=0" }
            let s = values.sorted()
            func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
            return String(format: "n=%d p50=%.1f p95=%.1f max=%.1f", s.count, q(0.5), q(0.95), s.last!)
        }
    }

    /// A deterministic page. Busy pages keep their web process working (a CSS animation and a timer that changes the text), as real sites do.
    static func page(_ i: Int, busy: Bool) -> String {
        let body = "<h1>Page \(i)</h1>" + String(repeating: "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>", count: 300)
        let extra = busy ? """
        <div id="spin" style="width:40px;height:40px;background:#36c;animation:s 1s linear infinite"></div><span id="t"></span>
        <style>@keyframes s{to{transform:rotate(360deg)}}</style><script>let n=0;setInterval(()=>{document.getElementById('t').textContent=++n},50)</script>
        """ : ""
        return "<html><head><meta charset=utf-8></head><body>\(extra)\(body)</body></html>"
    }

    private func web(_ tab: TabController) -> WKWebView { (tab.engine as! WebKitTab).webView }

    @discardableResult
    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// T5 proxy: the page has produced two animation frames after the switch (the first after it was shown, the second after that frame was presented).
    private func twoFrames(_ web: WKWebView, timeout: Double = 3) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                (try? await web.callAsyncJavaScript("return await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))",
                                                    contentWorld: .defaultClient)) != nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    struct Result { var select: [Double] = [], attach: [Double] = [], visible: [Double] = [], mainLongest: [Double] = []; var attachesPerSwitch: [Int] = []; var timeouts = 0; var stalls250 = 0; var stalls100 = 0; var seconds = 0.0 }

    func run(tabs n: Int, busy: Bool, switches k: Int, sameTab: Bool = false, privateTabs: Bool = false) async throws -> Result {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage3-\(UUID().uuidString)", profile: "default")
        await model.start()
        model.layoutPreset = .classic
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacRootView().environmentObject(model).frame(width: 1100, height: 760))
        window.alphaValue = 0.02
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }

        var tabs: [TabController] = []
        for i in 0..<n {
            let tab = model.openTab(url: nil, isPrivate: privateTabs)
            tab.engine.showHTML(Self.page(i, busy: busy), baseURL: URL(string: "https://p\(i).stage3.test/"))
            tabs.append(tab)
        }
        await waitUntil(max(10, Double(n) * 0.3)) { tabs.allSatisfy { !$0.isLoading && !$0.isBlank } }
        // Warm up: every tab is shown once, so each page has painted and later switches measure warm tabs.
        for tab in tabs { model.select(tab.id); try await Task.sleep(for: .milliseconds(n > 50 ? 60 : 120)) }
        try await Task.sleep(for: .milliseconds(500))

        let monitor = MainLatencyMonitor()
        monitor.start()
        defer { monitor.stop() }
        ActivationProbe.enabled = true
        defer { ActivationProbe.enabled = false; ActivationProbe.reset() }
        var rng = SystemRandomNumberGenerator()
        var seeded = UInt64(0x5EED + n * 31 + (busy ? 7 : 0))
        func nextIndex(_ bound: Int) -> Int { seeded = seeded &* 6364136223846793005 &+ 1442695040888963407; return Int((seeded >> 33) % UInt64(bound)) }
        _ = rng.next()

        var r = Result()
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<k {
            let target: TabController
            if sameTab || n == 1 { target = model.active ?? tabs[0] }
            else { var t = tabs[nextIndex(n)]; while t.id == model.activeID { t = tabs[nextIndex(n)] }; target = t }
            ActivationProbe.reset()
            let t0 = ProcessInfo.processInfo.systemUptime
            model.select(target.id)
            let t1 = ProcessInfo.processInfo.systemUptime
            let ok = await twoFrames(web(target))
            let t5 = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .milliseconds(150))       // let any trailing work (snapshots, scroll state) show up in the latency window
            let destination = ObjectIdentifier(web(target))
            let attaches = ActivationProbe.events.filter { $0.attached }
            r.select.append((t1 - t0) * 1000)
            if let a = attaches.first(where: { $0.view == destination }) { r.attach.append((a.at - t0) * 1000) }
            r.attachesPerSwitch.append(attaches.count)
            if ok { r.visible.append((t5 - t0) * 1000) } else { r.timeouts += 1 }
            r.mainLongest.append(monitor.longest(from: t0, to: t5 + 0.15))
        }
        let ended = ProcessInfo.processInfo.systemUptime
        r.seconds = ended - began
        r.stalls250 = monitor.count(over: 250, from: began, to: ended)
        r.stalls100 = monitor.count(over: 100, from: began, to: ended)
        return r
    }

    private func report(_ label: String, _ r: Result) {
        print("STAGE3 MAC \(label): select ms \(Stats(values: r.select)) | attach ms \(Stats(values: r.attach)) | visible(2 frames) ms \(Stats(values: r.visible)) timeouts \(r.timeouts) | main longest ms \(Stats(values: r.mainLongest)) | attaches/switch \(Stats(values: r.attachesPerSwitch.map(Double.init))) | stalls>100 \(r.stalls100) stalls>250 \(r.stalls250) over \(Int(r.seconds)) s")
    }

    // MARK: baseline

    func testBaselineStaticPages() async throws {
        for n in [1, 5, 20, 50, 100] {
            let r = try await run(tabs: n, busy: false, switches: n == 1 ? 20 : 40)
            report("static tabs=\(n)", r)
        }
    }

    func testBaselineBusyPages() async throws {
        for n in [5, 20, 50, 100] {
            let r = try await run(tabs: n, busy: true, switches: 40)
            report("busy tabs=\(n)", r)
        }
    }

    /// For Instruments: 100 busy tabs, many switches, so a Time Profiler attached to the app sees the switch path. Records the same numbers.
    func testProfileTarget100Busy() async throws {
        let r = try await run(tabs: 100, busy: true, switches: 120)
        report("PROFILE busy tabs=100", r)
    }

    // MARK: activation kinds, reported separately

    func testActivationKinds() async throws {
        report("kind live-to-live tabs=20", try await run(tabs: 20, busy: false, switches: 40))
        report("kind same-tab tabs=20", try await run(tabs: 20, busy: false, switches: 30, sameTab: true))
        report("kind private-to-private tabs=20", try await run(tabs: 20, busy: false, switches: 40, privateTabs: true))
        report("kind discarded-restored tabs=20", try await restoreRun(tabs: 20, restores: 15))
    }

    /// A tab put to sleep, then chosen: the time to a restored, loaded page that answers two frames (this includes WebKit reloading the page from its saved state).
    func restoreRun(tabs n: Int, restores k: Int) async throws -> Result {
        let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage3-r-\(UUID().uuidString)", profile: "default")
        await model.start()
        model.layoutPreset = .classic
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: MacRootView().environmentObject(model).frame(width: 1100, height: 760))
        window.alphaValue = 0.02
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        // Real addresses on the local fixture server (scripts/testserver.py), so a restored tab can load its page again; HTML strings have nothing to reload.
        let probe = try? await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:18765/_reset")!)
        try XCTSkipIf(probe == nil, "the local fixture server is not running on 18765 (python3 scripts/testserver.py)")
        var tabs: [TabController] = []
        for i in 0..<n { tabs.append(model.openTab(url: URL(string: "http://127.0.0.1:18765/tall?r=\(i)")!, isPrivate: false)) }
        await waitUntil(20) { tabs.allSatisfy { !$0.isLoading && !$0.isBlank } }
        for tab in tabs { model.select(tab.id); try await Task.sleep(for: .milliseconds(100)) }
        let monitor = MainLatencyMonitor(); monitor.start(); defer { monitor.stop() }
        var r = Result()
        let began = ProcessInfo.processInfo.systemUptime
        for j in 0..<k {
            let target = tabs[j % (n - 1)]
            guard target.id != model.activeID else { continue }
            target.discard(reason: "Stage 3 benchmark")
            guard target.isDiscarded else { continue }
            try await Task.sleep(for: .milliseconds(200))
            let t0 = ProcessInfo.processInfo.systemUptime
            model.select(target.id)
            let t1 = ProcessInfo.processInfo.systemUptime
            let woke = await waitUntil(8) { !target.isDiscarded && !target.isLoading && target.engine.currentURL != nil }
            let ok = woke ? await twoFrames(web(target)) : false
            let t5 = ProcessInfo.processInfo.systemUptime
            r.select.append((t1 - t0) * 1000)
            if ok { r.visible.append((t5 - t0) * 1000) } else { r.timeouts += 1 }
            r.mainLongest.append(monitor.longest(from: t0, to: t5))
            try await Task.sleep(for: .milliseconds(150))
        }
        let ended = ProcessInfo.processInfo.systemUptime
        r.seconds = ended - began
        r.stalls250 = monitor.count(over: 250, from: began, to: ended)
        r.stalls100 = monitor.count(over: 100, from: began, to: ended)
        return r
    }
}
