import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import Browser_Setu

/// Stage 3 on the iPhone: what switching live tabs costs with the real `PhoneRootView` in a real window, on deterministic local pages. Per switch: T1 the selection is
/// committed; T3 the destination web view joins the window (`ActivationProbe`); T5 (proxy) the destination page answers two animation frames; and the longest the main
/// thread took to answer a 2 ms ping in that switch. No addresses or titles are recorded; throwaway profile per run.
@MainActor
final class Stage3PhoneActivationTests: XCTestCase {
    final class MainLatencyMonitor: @unchecked Sendable {
        private let lock = NSLock()
        private var pendingSince: Double?
        private var samples: [(sent: Double, ms: Double)] = []
        private var timer: DispatchSourceTimer?
        func start() {
            let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "stage3.ios.main-latency", qos: .userInteractive))
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
            source.resume(); timer = source
        }
        func stop() { timer?.cancel(); timer = nil }
        func longest(from: Double, to: Double) -> Double {
            lock.lock(); defer { lock.unlock() }
            return samples.filter { $0.sent >= from && $0.sent <= to }.map(\.ms).max() ?? 0
        }
        func count(over ms: Double, from: Double, to: Double) -> Int {
            lock.lock(); defer { lock.unlock() }
            var runs = 0, inRun = false
            for s in samples where s.sent >= from && s.sent <= to { if s.ms > ms { if !inRun { runs += 1 }; inRun = true } else { inRun = false } }
            return runs
        }
    }

    private func stats(_ v: [Double]) -> String {
        guard !v.isEmpty else { return "n=0" }
        let s = v.sorted()
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))] }
        return String(format: "n=%d p50=%.1f p95=%.1f max=%.1f", s.count, q(0.5), q(0.95), s.last!)
    }

    private func page(_ i: Int) -> String {
        "<html><head><meta name=viewport content='width=device-width,initial-scale=1'></head><body><h1>Page \(i)</h1>"
            + String(repeating: "<p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.</p>", count: 300) + "</body></html>"
    }

    private func web(_ tab: TabController) -> WKWebView { (tab.engine as! WebKitTab).webView }

    @discardableResult
    private func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end { if condition() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    private func twoFrames(_ web: WKWebView) -> Bool {
        var done = false, ok = false
        web.callAsyncJavaScript("return await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r(1))))", in: nil, in: .defaultClient) { result in
            if case .success = result { ok = true }; done = true
        }
        waitUntil(3) { done }
        return ok
    }

    func testIPhoneLiveTabSwitching() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "needs an iPhone")
        for n in [5, 20, 50] {
            let model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage3-ios-\(UUID().uuidString)", profile: "default")
            model.phonePreset = .bottomBar
            var tabs: [TabController] = []
            for i in 0..<n {
                let tab = model.openTab(url: nil, isPrivate: false)
                tab.engine.showHTML(page(i), baseURL: URL(string: "https://p\(i).stage3.test/"))
                tabs.append(tab)
            }
            let controller = UIHostingController(rootView: AnyView(PhoneRootView().environmentObject(model)))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
            window.frame = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            waitUntil(Double(n) * 0.3 + 10) { tabs.allSatisfy { !$0.isLoading && !$0.isBlank } }
            for tab in tabs { model.select(tab.id); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))

            let monitor = MainLatencyMonitor(); monitor.start(); defer { monitor.stop() }
            ActivationProbe.enabled = true; defer { ActivationProbe.enabled = false; ActivationProbe.reset() }
            var seed = UInt64(0x105 + n)
            func next(_ b: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(b)) }
            var select: [Double] = [], attach: [Double] = [], visible: [Double] = [], longest: [Double] = [], timeouts = 0
            let began = ProcessInfo.processInfo.systemUptime
            for _ in 0..<30 {
                var target = tabs[next(n)]; while target.id == model.activeID { target = tabs[next(n)] }
                ActivationProbe.reset()
                let t0 = ProcessInfo.processInfo.systemUptime
                model.select(target.id)
                let t1 = ProcessInfo.processInfo.systemUptime
                let ok = twoFrames(web(target))
                let t5 = ProcessInfo.processInfo.systemUptime
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                select.append((t1 - t0) * 1000)
                if let a = ActivationProbe.events.first(where: { $0.attached && $0.view == ObjectIdentifier(web(target)) }) { attach.append((a.at - t0) * 1000) }
                if ok { visible.append((t5 - t0) * 1000) } else { timeouts += 1 }
                longest.append(monitor.longest(from: t0, to: t5 + 0.15))
            }
            let ended = ProcessInfo.processInfo.systemUptime
            print("STAGE3 IPHONE tabs=\(n): select ms \(stats(select)) | attach ms \(stats(attach)) | visible(2 frames) ms \(stats(visible)) timeouts \(timeouts) | main longest ms \(stats(longest)) | stalls>100 \(monitor.count(over: 100, from: began, to: ended)) stalls>250 \(monitor.count(over: 250, from: began, to: ended))")
            XCTAssertEqual(timeouts, 0)
        }
    }
}
