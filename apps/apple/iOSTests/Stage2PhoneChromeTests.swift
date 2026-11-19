import XCTest
import Combine
import SwiftUI
import UIKit
import WebKit
@testable import Browser_Setu

/// Stage 2: the iPhone chrome and the page under it, measured rather than looked at. The real `PhoneRootView` is hosted in a real `UIWindow` of the app's scene. For each
/// layout and state this records where the bar sheet really is (`viewportProbe`), where the web view is, what WebKit was told, what the page itself measures (DOM rectangles,
/// `innerHeight`, `100dvh`, `env(safe-area-inset-*)`), and where WebKit really draws the page's fixed header (pure red) and fixed footer (pure blue), found in WebKit's own
/// snapshot of the web view. Throwaway profile per test.
@MainActor
final class Stage2PhoneChromeTests: XCTestCase {
    private final class Host {
        let window: UIWindow
        let controller: UIHostingController<AnyView>
        init(model: BrowserModel) {
            controller = UIHostingController(rootView: AnyView(PhoneRootView().environmentObject(model)))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
            window.frame = scene?.coordinateSpace.bounds ?? UIScreen.main.bounds
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }
        func tearDown() { window.isHidden = true; window.rootViewController = nil }
    }

    /// One measured state, in window points.
    struct Measure: CustomStringConvertible {
        var label = ""
        var window = CGSize.zero
        var windowSafe = UIEdgeInsets.zero
        var slot: CGRect?, container: CGRect?, glass: CGRect?
        var containerSafe: EdgeInsets?
        var webFrame = CGRect.zero
        var webSafe = UIEdgeInsets.zero
        var contentInset = UIEdgeInsets.zero, adjustedInset = UIEdgeInsets.zero, told = UIEdgeInsets.zero
        var innerHeight = 0.0, headerRect = CGRect.zero, footerRect = CGRect.zero, dvh = 0.0, envTop = 0.0, envBottom = 0.0
        /// Where WebKit drew the red header and the blue footer, in window points (nil if not visible).
        var drawnHeader: ClosedRange<CGFloat>?, drawnFooter: ClosedRange<CGFloat>?
        var description: String {
            func r(_ v: CGRect?) -> String { v.map { "y \(Int($0.minY))…\(Int($0.maxY)) h \(Int($0.height))" } ?? "-" }
            func s(_ v: ClosedRange<CGFloat>?) -> String { v.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "-" }
            return "STAGE2 \(label): window \(Int(window.height)) safe \(Int(windowSafe.top))/\(Int(windowSafe.bottom)) | slot \(r(slot)) container \(r(container)) containerSafe \(containerSafe.map { "\(Int($0.top))/\(Int($0.bottom))" } ?? "-") glass(pre-offset) \(r(glass)) | web \(r(webFrame)) webSafe \(Int(webSafe.top))/\(Int(webSafe.bottom)) inset \(Int(contentInset.top))/\(Int(contentInset.bottom)) adjusted \(Int(adjustedInset.top))/\(Int(adjustedInset.bottom)) told \(Int(told.top))/\(Int(told.bottom)) | DOM innerH \(Int(innerHeight)) header \(Int(headerRect.minY))…\(Int(headerRect.maxY)) footer \(Int(footerRect.minY))…\(Int(footerRect.maxY)) dvh \(Int(dvh)) env \(Int(envTop))/\(Int(envBottom)) | drawn header \(s(drawnHeader)) footer \(s(drawnFooter))"
        }
    }

    private var host: Host?
    private var model: BrowserModel!

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the Stage 2 iPhone tests need an iPhone simulator or device")
        ViewportShadow.reset()
        ViewportShadow.enabled = true
        model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage2-\(UUID().uuidString)", profile: "default")
    }

    override func tearDown() {
        host?.tearDown(); host = nil; model = nil
        super.tearDown()
    }

    @discardableResult
    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }

    /// Fixed header (red) and footer (blue), a sticky heading, an input, a `100dvh` box, the safe-area environment, long content. `sessionStorage.n` counts loads.
    static let fixture = """
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><style>
    body{margin:0;font:16px -apple-system;background:#fff} #h,#f{position:fixed;left:0;right:0;height:44px} #h{top:0;background:#f00} #f{bottom:0;background:#00f}
    h2{position:sticky;top:0;background:#eee;margin:0} main{padding-top:44px;padding-bottom:44px} #dvh{height:100dvh;background:#fafafa}
    #env{position:absolute;top:0;padding-top:env(safe-area-inset-top);padding-bottom:env(safe-area-inset-bottom);height:0;width:0}
    </style></head><body><div id="h"></div><main><h2>sticky</h2><input id="i" placeholder="field"><div id="dvh"></div><div style="height:3000px"></div><div id="end" style="height:20px;background:#0f0"></div></main>
    <div id="f"></div><div id="env"></div><script>sessionStorage.n=(+sessionStorage.n||0)+1</script></body></html>
    """

    /// An ordinary page: long content and a green end marker, no fixed elements.
    static let ordinary = """
    <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0;font:16px -apple-system;background:#fff}</style></head>
    <body><div style="height:3000px">content</div><div id="end" style="height:20px;background:#0f0"></div><script>sessionStorage.n=(+sessionStorage.n||0)+1</script></body></html>
    """

    private func pageTab(_ html: String = Stage2PhoneChromeTests.fixture) -> TabController {
        let tab = model.openTab(url: nil, isPrivate: false)
        tab.engine.showHTML(html, baseURL: URL(string: "https://stage2.example.test/"))
        waitUntil(8) { !tab.isBlank && !tab.isLoading }
        return tab
    }

    private func web(_ tab: TabController) -> WKWebView { (tab.engine as! WebKitTab).webView }

    private func js(_ web: WKWebView, _ script: String) -> Any? {
        var result: Any?, done = false
        web.evaluateJavaScript(script) { value, _ in result = value; done = true }
        waitUntil(3) { done }
        return result
    }

    /// Rows of the web view's own snapshot whose middle pixel is (nearly) the given pure colour, as a range in web view points.
    private func drawnRows(_ web: WKWebView, red: Bool) -> ClosedRange<CGFloat>? { drawnRows(web, red ? (255, 0, 0) : (0, 0, 255)) }

    /// Rows of the web view's own snapshot whose middle pixel is (nearly) the given pure colour, as a range in web view points.
    private func drawnRows(_ web: WKWebView, _ colour: (Int, Int, Int)) -> ClosedRange<CGFloat>? {
        var image: UIImage?, done = false
        web.takeSnapshot(with: nil) { snapshot, _ in image = snapshot; done = true }
        waitUntil(3) { done }
        guard let cg = image?.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let scale = CGFloat(cg.height) / web.bounds.height
        let x = cg.width / 2, bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        let littleEndian = cg.bitmapInfo.contains(.byteOrder32Little)
        var first: Int?, last: Int?
        for y in 0..<cg.height {
            let p = bytes + y * bpr + x * bpp
            let (r, g, b) = littleEndian ? (p[2], p[1], p[0]) : (p[0], p[1], p[2])
            func near(_ v: UInt8, _ w: Int) -> Bool { w == 255 ? v > 200 : v < 60 }
            let hit = near(r, colour.0) && near(g, colour.1) && near(b, colour.2)
            if hit { if first == nil { first = y }; last = y }
        }
        guard let first, let last else { return nil }
        return CGFloat(first) / scale ... CGFloat(last) / scale
    }

    private func measure(_ label: String, _ tab: TabController) -> Measure {
        let w = web(tab)
        var m = Measure(label: label)
        if let window = host?.window {
            m.window = window.bounds.size; m.windowSafe = window.safeAreaInsets
            m.webFrame = w.convert(w.bounds, to: window)
        }
        m.slot = ViewportShadow.probes["sheet.slot"]?.frame
        m.container = ViewportShadow.probes["sheet.container"]?.frame
        m.containerSafe = ViewportShadow.probes["sheet.container"]?.safe
        m.glass = ViewportShadow.probes["sheet.glass"]?.frame
        m.webSafe = w.safeAreaInsets
        m.contentInset = w.scrollView.contentInset
        m.adjustedInset = w.scrollView.adjustedContentInset
        m.told = w.minimumViewportInset
        if let v = js(w, """
        (function(){var h=document.getElementById('h').getBoundingClientRect(),f=document.getElementById('f').getBoundingClientRect(),e=getComputedStyle(document.getElementById('env'));
        return [innerHeight,h.top,h.bottom,f.top,f.bottom,document.getElementById('dvh').getBoundingClientRect().height,parseFloat(e.paddingTop),parseFloat(e.paddingBottom)];})()
        """) as? [Double], v.count == 8 {
            m.innerHeight = v[0]; m.headerRect = CGRect(x: 0, y: v[1], width: 1, height: v[2] - v[1]); m.footerRect = CGRect(x: 0, y: v[3], width: 1, height: v[4] - v[3])
            m.dvh = v[5]; m.envTop = v[6]; m.envBottom = v[7]
        }
        let top = m.webFrame.minY
        m.drawnHeader = drawnRows(w, red: true).map { ($0.lowerBound + top)...($0.upperBound + top) }
        m.drawnFooter = drawnRows(w, red: false).map { ($0.lowerBound + top)...($0.upperBound + top) }
        print(m)
        return m
    }

    private func start(_ preset: PhonePreset) -> TabController {
        model.phonePreset = preset
        let tab = pageTab()
        host = Host(model: model)
        waitUntil(5) { web(tab).window != nil }
        settle()
        return tab
    }

    private func picture(_ name: String) {
        guard let window = host?.window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "stage2-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: characterization (records; the assertions are in the tests below)

    func testMeasureEveryLayoutOpenAndFolded() {
        let tab = start(.bottomBar)
        for preset in [PhonePreset.bottomBar, .topBar, .compactBottom, .compactTop, .immersive] {
            model.phonePreset = preset; settle()
            model.expandChrome(userRequested: true); settle()
            _ = measure("\(preset) open", tab); picture("\(preset)-open")
            model.foldChrome(); settle()
            _ = measure("\(preset) folded", tab); picture("\(preset)-folded")
        }
        model.expandChrome(userRequested: true); settle()
        XCTAssertEqual(js(web(tab), "+sessionStorage.n") as? Int, 1, "layout changes reloaded the page")
    }

    // MARK: Issue A: the bottom card sits on the page with no band and ends at the screen's edge; nothing else moves

    func testBottomCardMeetsThePageAndEndsAtTheScreenEdge() throws {
        let tab = start(.bottomBar)
        let m = measure("A bottomBar open", tab)
        let glass = try XCTUnwrap(m.glass)
        XCTAssertEqual(glass.maxY, m.window.height, accuracy: 1, "the bar ends at the screen's bottom edge, under the home indicator")
        if #available(iOS 26, *) {
            // The page runs under the bar: no strip of the app's background is left behind it.
            XCTAssertEqual(m.webFrame.maxY, m.window.height, accuracy: 1, "the page runs to the screen's edge, under the bar")
            XCTAssertEqual(web(tab).obscuredContentInsets.bottom, m.window.height - glass.minY, accuracy: 1, "WebKit is told exactly the strip the bar covers")
            // WebKit fills the covered strip with the page's edge colour, so the footer's own bottom edge is read from the page (DOM) and its top from the pixels.
            XCTAssertEqual(m.webFrame.minY + m.footerRect.maxY, glass.minY, accuracy: 1, "the page's fixed footer ends where the bar starts: visible, not under it")
            XCTAssertEqual(m.drawnFooter?.lowerBound ?? 0, m.webFrame.minY + m.footerRect.minY, accuracy: 2, "the footer is drawn where the page puts it")
            // The last of the page can be scrolled clear of the bar.
            let w = web(tab)
            w.scrollView.setContentOffset(CGPoint(x: 0, y: w.scrollView.contentSize.height - w.scrollView.bounds.height + w.scrollView.adjustedContentInset.bottom), animated: false)
            settle()
            let end = drawnRows(w, (0, 255, 0)).map { ($0.lowerBound + m.webFrame.minY)...($0.upperBound + m.webFrame.minY) }
            print("STAGE2 A end marker drawn \(end.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "-") glass top \(Int(glass.minY)) footer top \(Int(m.drawnFooter?.lowerBound ?? -1)) adjusted bottom \(Int(w.scrollView.adjustedContentInset.bottom))")
            let marker = try XCTUnwrap(end, "the end of the page is not visible after scrolling to it")
            XCTAssertLessThanOrEqual(marker.upperBound, glass.minY - m.footerRect.height + 1, "after scrolling to the end, the last of the page shows above the page's footer and the bar")
        } else {
            XCTAssertEqual(glass.minY, m.webFrame.maxY, accuracy: 1, "a band between the page and the bar")
            XCTAssertEqual(m.drawnFooter?.upperBound ?? 0, m.webFrame.maxY, accuracy: 2, "the page's fixed footer sits on the bar, visible")
        }
        model.foldChrome(); settle()
        let f = measure("A bottomBar folded", tab)
        let pill = try XCTUnwrap(f.glass)
        XCTAssertEqual(pill.maxY, f.window.height - f.windowSafe.bottom - 6, accuracy: 1, "the folded capsule stays 6 pt above the home indicator")
        XCTAssertEqual(js(web(tab), "+sessionStorage.n") as? Int, 1, "folding reloaded the page")
    }

    func testCompactBottomBarLeavesNoStripEither() throws {
        let tab = start(.compactBottom)
        let m = measure("A compactBottom open", tab)
        let pills = try XCTUnwrap(m.container)
        if #available(iOS 26, *) {
            XCTAssertEqual(m.webFrame.maxY, m.window.height, accuracy: 1, "the page runs under the compact bar")
            XCTAssertEqual(m.webFrame.minY + m.footerRect.maxY, m.window.height - web(tab).obscuredContentInsets.bottom, accuracy: 1, "the fixed footer ends above the covered strip")
            XCTAssertLessThanOrEqual(m.webFrame.minY + m.footerRect.maxY, pills.minY + 1, "the fixed footer is not under the pills")
        } else {
            XCTAssertEqual(m.webFrame.maxY, pills.minY, accuracy: 1)
        }
    }

    func testTopCardAndFoldedCapsulesKeepTheirPlaces() throws {
        let tab = start(.topBar)
        let m = measure("A topBar open", tab)
        let glass = try XCTUnwrap(m.glass)
        XCTAssertEqual(glass.minY, 0, accuracy: 1, "the top bar runs up under the clock")
        XCTAssertEqual(glass.maxY, m.windowSafe.top + 134, accuracy: 1)
        model.foldChrome(); settle()
        let f = measure("A topBar folded", tab)
        XCTAssertEqual(try XCTUnwrap(f.glass).minY, f.windowSafe.top + 6, accuracy: 1)
        model.expandChrome(userRequested: true)
        model.phonePreset = .compactBottom; settle()
        let c = measure("A compactBottom open", tab)
        XCTAssertEqual(try XCTUnwrap(c.container).maxY, c.window.height - c.windowSafe.bottom - 6, accuracy: 1, "compact bar unchanged")
    }

    // MARK: Issue B investigation: which public API keeps a page's fixed header clear of the top sheet (records only)

    func testInvestigateTopSheetInsetOptions() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("obscuredContentInsets needs iOS 26") }
        for cover in [false, true] {
            model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage2-b-\(UUID().uuidString)", profile: "default")
            model.phonePreset = .topBar
            let tab = model.openTab(url: nil, isPrivate: false)
            let html = cover ? Self.fixture : Self.fixture.replacingOccurrences(of: ",viewport-fit=cover", with: "")
            tab.engine.showHTML(html, baseURL: URL(string: "https://stage2b.example.test/"))
            waitUntil(8) { !tab.isBlank && !tab.isLoading }
            host?.tearDown(); host = Host(model: model)
            waitUntil(5) { web(tab).window != nil }
            settle()
            let w = web(tab)
            let room = w.scrollView.contentInset.top, safe = w.safeAreaInsets.top
            let options: [(String, UIEdgeInsets?, CGFloat)] = [("v0 today", nil, room), ("v1 obscured=room+safe, scroll room kept", UIEdgeInsets(top: room + safe, left: 0, bottom: 0, right: 0), room),
                                                              ("v2 obscured=room+safe, scroll room 0", UIEdgeInsets(top: room + safe, left: 0, bottom: 0, right: 0), 0),
                                                              ("v3 obscured=room, scroll room 0", UIEdgeInsets(top: room, left: 0, bottom: 0, right: 0), 0)]
            for (name, obscured, scrollTop) in options {
                w.obscuredContentInsets = obscured ?? .zero
                w.scrollView.contentInset.top = scrollTop
                w.scrollView.contentOffset.y = -w.scrollView.adjustedContentInset.top
                settle()
                let m = measure("B \(cover ? "cover" : "plain") \(name)", tab)
                print("STAGE2B \(cover ? "cover" : "plain") \(name): glass bottom \(Int(m.glass?.maxY ?? -1)) header drawn \(m.drawnHeader.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "-") obscured \(Int(w.obscuredContentInsets.top)) offset \(Int(w.scrollView.contentOffset.y)) adjusted \(Int(w.scrollView.adjustedContentInset.top)) innerH \(Int(m.innerHeight)) headerDOM \(Int(m.headerRect.minY)) env \(Int(m.envTop))")
            }
            w.obscuredContentInsets = .zero
        }
    }

    // MARK: Issue C: folding and unfolding while scrolling

    /// Moves the page in steps, as a finger would. The engine reports only movement while the page is dragged or decelerating (`WebKitTab.scrolled`), which a
    /// test cannot produce, so each step also delivers the delta the engine would report, through the same call it uses (`TabController.engineScrolled`).
    private func scroll(_ tab: TabController, by total: CGFloat, step: CGFloat = 12) {
        let web = web(tab)
        let n = Int(abs(total) / step)
        for _ in 0..<n {
            let s = web.scrollView
            let before = s.contentOffset.y
            s.contentOffset.y = max(-s.adjustedContentInset.top, min(s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom, s.contentOffset.y + (total > 0 ? step : -step)))
            tab.engineScrolled(deltaY: Double(before - s.contentOffset.y))
            RunLoop.current.run(until: Date().addingTimeInterval(0.016))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    func testFoldingWhileScrollingIsStableForEveryBarLayout() throws {
        let tab = start(.bottomBar)
        let w = web(tab)
        let identity = ObjectIdentifier(w)
        for preset in [PhonePreset.bottomBar, .topBar, .compactBottom, .compactTop] {
            model.phonePreset = preset; settle()
            model.expandChrome(userRequested: true); settle()
            w.scrollView.contentOffset.y = 400; settle()
            var changes = 0
            let observer = model.$chromeCollapsed.dropFirst().sink { _ in changes += 1 }
            ViewportShadow.reset()
            // What is on screen is fixed by the web view's place and the scroll view's offset; the page's own coordinates shift with the scroll room and are not a measure.
            let frameBefore = w.convert(w.bounds, to: w.window).minY, before = w.scrollView.contentOffset.y
            scroll(tab, by: 600)                       // slow downward reading
            settle()
            let after = w.scrollView.contentOffset.y + (w.convert(w.bounds, to: w.window).minY - frameBefore)
            XCTAssertTrue(model.chromeCollapsed, "\(preset): scrolling down folded the bars")
            let writesForFold = ViewportShadow.applied
            // Content moved by the scrolling itself (600) only: anything beyond is a jump caused by the fold.
            let jump = (after - before) - 600
            scroll(tab, by: 300)                       // more reading: no change back and forth
            let foldedChanges = changes
            scroll(tab, by: -60)                       // back up a little: the bars return
            settle()
            observer.cancel()
            print("STAGE2C \(preset): fold changes \(foldedChanges) total \(changes) writes for fold \(writesForFold) shadow mismatches \(ViewportShadow.mismatches) jump \(Int(jump.rounded())) pt")
            XCTAssertEqual(foldedChanges, 1, "\(preset): the bars changed more than once while reading down (oscillation)")
            XCTAssertLessThanOrEqual(writesForFold, 2, "\(preset): folding wrote to WebKit more than twice")
            XCTAssertEqual(ViewportShadow.mismatches, 0)
            XCTAssertEqual(ViewportShadow.doubleCompensations, 0)
            XCTAssertLessThanOrEqual(abs(jump), 2, "\(preset): folding moved the page's content by \(jump) pt")
            if #available(iOS 26, *), !model.chromeCollapsed, model.phoneBarAtBottom, let glass = ViewportShadow.probes["sheet.glass"]?.frame {
                XCTAssertEqual(w.obscuredContentInsets.bottom, (host?.window.bounds.height ?? 0) - glass.minY, accuracy: 1, "\(preset): covered strip matches the bar after unfolding")
            }
        }
        XCTAssertEqual(ObjectIdentifier(w), identity)
        XCTAssertEqual(js(w, "+sessionStorage.n") as? Int, 1, "scrolling and folding reloaded the page")
    }

    func testSwitchingTabsMidScrollKeepsBothPages() throws {
        let a = start(.bottomBar)
        let b = pageTab()
        model.select(a.id); settle()
        web(a).scrollView.contentOffset.y = 300
        scroll(a, by: 200)
        model.select(b.id); settle()
        model.select(a.id); settle()
        XCTAssertEqual(web(a).scrollView.contentInset.bottom, model.phoneBottomInset, accuracy: 0.5)
        if #available(iOS 26, *) { XCTAssertEqual(web(a).obscuredContentInsets.bottom, model.phoneBottomInset, accuracy: 0.5) }
        XCTAssertEqual(js(web(a), "+sessionStorage.n") as? Int, 1)
        XCTAssertEqual(js(web(b), "+sessionStorage.n") as? Int, 1)
    }

    // MARK: Issue D: keyboard, rotation, background

    private var field: UITextField?
    /// A real keyboard: a text field in the test window takes focus, as a field in a page does, so the system raises the keyboard and the screen's keyboard safe area,
    /// notifications and layout all follow for real.
    private func keyboard(up: Bool) {
        if up {
            if field == nil, let window = host?.window {
                let f = UITextField(frame: CGRect(x: 0, y: 300, width: 10, height: 10)); f.alpha = 0.02
                window.addSubview(f); field = f
            }
            field?.becomeFirstResponder()
            waitUntil(3) { (ViewportShadow.probes["sheet.slot"]?.frame.maxY ?? .infinity) < (host?.window.bounds.height ?? 0) - 200 }
        } else {
            field?.resignFirstResponder()
            waitUntil(3) { (ViewportShadow.probes["sheet.slot"]?.frame.maxY ?? 0) > (host?.window.bounds.height ?? 0) - 100 }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    }

    /// Every bottom-bar state must have the covered strip told to WebKit equal to the strip the bar really covers, and the page's footer ending where the bar starts.
    private func assertBottomGeometry(_ label: String, _ tab: TabController, file: StaticString = #filePath, line: UInt = #line) {
        let m = measure(label, tab)
        guard let glass = m.glass, model.phoneBarAtBottom, !model.chromeCollapsed else { return }
        if #available(iOS 26, *) {
            XCTAssertEqual(web(tab).obscuredContentInsets.bottom, m.webFrame.maxY - glass.minY, accuracy: 1.5, "\(label): covered strip ≠ the part of the page the bar covers", file: file, line: line)
            XCTAssertEqual(m.webFrame.minY + m.footerRect.maxY, glass.minY, accuracy: 1.5, "\(label): footer not on the bar", file: file, line: line)
        } else {
            XCTAssertEqual(m.webFrame.maxY, glass.minY, accuracy: 1.5, "\(label): page does not meet the bar", file: file, line: line)
        }
    }

    func testAddressEditingAndKeyboardKeepTheBottomGeometryTrue() throws {
        let tab = start(.bottomBar)
        assertBottomGeometry("D open", tab)
        model.addressBar.isEditing = true; keyboard(up: true); settle()
        assertBottomGeometry("D editing, keyboard up", tab)
        model.addressBar.isEditing = false; keyboard(up: false); settle()
        assertBottomGeometry("D editing done, keyboard down", tab)
        // A keyboard raised by a field in the page (the address bar is not editing).
        keyboard(up: true); settle()
        assertBottomGeometry("D page field, keyboard up", tab)
        let b = pageTab()
        model.select(b.id); settle()
        assertBottomGeometry("D tab change with keyboard up", b)
        keyboard(up: false); settle()
        assertBottomGeometry("D keyboard down", b)
        XCTAssertEqual(js(web(tab), "+sessionStorage.n") as? Int, 1)
    }

    func testRotationFoldedAndWithKeyboardAndBackgroundKeepGeometryTrue() throws {
        let tab = start(.bottomBar)
        let identity = ObjectIdentifier(web(tab))
        guard let scene = host?.window.windowScene else { throw XCTSkip("no window scene") }
        model.foldChrome(); settle()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        try XCTSkipUnless(waitUntil(4) { scene.interfaceOrientation.isLandscape }, "this host did not rotate")
        host?.window.frame = scene.coordinateSpace.bounds; settle()
        let folded = measure("D landscape folded", tab)
        XCTAssertEqual(web(tab).minimumViewportInset.top, model.phoneTopInset + web(tab).safeAreaInsets.top, accuracy: 0.5, "stale told top after turning folded")
        XCTAssertEqual(web(tab).minimumViewportInset.bottom, model.phoneBottomInset + web(tab).safeAreaInsets.bottom, accuracy: 0.5, "stale told bottom after turning folded")
        _ = folded
        model.expandChrome(userRequested: true); keyboard(up: true); settle()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        waitUntil(4) { scene.interfaceOrientation.isPortrait }
        host?.window.frame = scene.coordinateSpace.bounds
        keyboard(up: false); settle()
        assertBottomGeometry("D portrait after turning with keyboard", tab)
        // Background and back.
        let writes = ViewportShadow.applied
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        settle()
        assertBottomGeometry("D back from background", tab)
        XCTAssertEqual(ViewportShadow.applied, writes, "returning from the background rewrote geometry that had not changed")
        XCTAssertEqual(ViewportShadow.mismatches, 0)
        XCTAssertEqual(ObjectIdentifier(web(tab)), identity)
        XCTAssertEqual(js(web(tab), "+sessionStorage.n") as? Int, 1)
    }

    // MARK: Follow-up: the dock layouts (Floating, Immersive)

    private func useDockLayout(_ name: String) {
        if name == "floating" {
            model.phoneCustomSpec = PhoneLayoutSpec(style: .floating, address: .bottom, reading: .foldsAndReturns, tabsPill: true, newTabPill: true)
            model.phonePreset = .custom
        } else {
            model.phonePreset = .immersive
        }
    }

    /// Scrolls to the very end and returns where the green end marker is drawn (window points), or nil if it is not visible.
    private func endMarkerAfterScrollingToEnd(_ tab: TabController) -> ClosedRange<CGFloat>? {
        let w = web(tab)
        w.scrollView.setContentOffset(CGPoint(x: 0, y: w.scrollView.contentSize.height - w.scrollView.bounds.height + w.scrollView.adjustedContentInset.bottom), animated: false)
        settle()
        let top = w.convert(w.bounds, to: w.window).minY
        return drawnRows(w, (0, 255, 0)).map { ($0.lowerBound + top)...($0.upperBound + top) }
    }

    func testMeasureDockLayouts() throws {
        for layout in ["floating", "immersive"] {
            for (page, html) in [("fixed-nav", Self.fixture), ("ordinary", Self.ordinary)] {
                model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage2-dock-\(UUID().uuidString)", profile: "default")
                ViewportShadow.reset()
                useDockLayout(layout)
                let tab = pageTab(html)
                host?.tearDown(); host = Host(model: model)
                waitUntil(5) { web(tab).window != nil }
                settle()
                for state in ["open", "folded"] {
                    if state == "folded" { model.foldChrome() } else { model.expandChrome(userRequested: true) }
                    settle()
                    let m = measure("DOCK \(layout) \(page) \(state)", tab)
                    let dock = ViewportShadow.probes[state == "open" ? "dock" : "dock.pill"]?.frame
                    let end = endMarkerAfterScrollingToEnd(tab)
                    var obscured: CGFloat = -1
                    if #available(iOS 26, *) { obscured = web(tab).obscuredContentInsets.bottom }
                    print("STAGE2DOCK \(layout) \(page) \(state): fixedBottom \(model.activeFixedBottom) web \(Int(m.webFrame.minY))…\(Int(m.webFrame.maxY)) dock \(dock.map { "\(Int($0.minY))…\(Int($0.maxY))" } ?? "-") strip below page \(Int(m.window.height - m.webFrame.maxY)) obscured \(Int(obscured)) scroll room \(Int(web(tab).scrollView.adjustedContentInset.bottom)) innerH \(Int(m.innerHeight)) domFooter \(Int(m.footerRect.minY))…\(Int(m.footerRect.maxY)) end marker at end \(end.map { "\(Int($0.lowerBound))…\(Int($0.upperBound))" } ?? "-")")
                }
            }
        }
    }

    func testDockLayoutsLeaveNoStripAndScrollTheEndClear() throws {
        for layout in ["floating", "immersive"] {
            for (page, html) in [("fixed-nav", Self.fixture), ("ordinary", Self.ordinary)] {
                model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage2-dock-\(UUID().uuidString)", profile: "default")
                ViewportShadow.reset()
                useDockLayout(layout)
                let tab = pageTab(html)
                host?.tearDown(); host = Host(model: model)
                waitUntil(5) { web(tab).window != nil }
                settle()
                let identity = ObjectIdentifier(web(tab))
                for state in ["open", "folded"] {
                    if state == "folded" { model.foldChrome() } else { model.expandChrome(userRequested: true) }
                    settle()
                    let label = "\(layout) \(page) \(state)"
                    let m = measure("DOCK \(label)", tab)
                    let dockTop = try XCTUnwrap(ViewportShadow.probes["dock"]?.frame.minY, "\(label): no dock probe")
                    if page == "fixed-nav" {
                        XCTAssertTrue(model.activeFixedBottom, "\(label): the page's bottom bar was not seen")
                        if #available(iOS 26, *) {
                            XCTAssertEqual(m.webFrame.maxY, m.window.height, accuracy: 1, "\(label): a strip is left below the page")
                            XCTAssertEqual(web(tab).obscuredContentInsets.bottom, 74, accuracy: 1, "\(label): covered strip")
                            XCTAssertEqual(m.webFrame.minY + m.footerRect.maxY, m.window.height - 74, accuracy: 1.5, "\(label): the page's bar ends where the covered strip starts")
                            XCTAssertLessThanOrEqual(m.webFrame.minY + m.footerRect.maxY, dockTop + 0.5, "\(label): the page's bar is under the dock")
                        } else {
                            XCTAssertLessThanOrEqual(m.webFrame.maxY, dockTop + 0.5, "\(label): before iOS 26 the page ends above the dock")
                        }
                    } else {
                        if #available(iOS 26, *) { XCTAssertEqual(web(tab).obscuredContentInsets.bottom, 0, "\(label): an ordinary page is not covered") }
                        XCTAssertEqual(m.webFrame.maxY, m.window.height, accuracy: 1, "\(label): the page runs under the floating dock")
                        let end = try XCTUnwrap(endMarkerAfterScrollingToEnd(tab), "\(label): the end of the page is not visible after scrolling to it")
                        XCTAssertLessThanOrEqual(end.upperBound, dockTop + 0.5, "\(label): the end of the page stays under the dock")
                        print("STAGE2DOCK fixed \(label): end marker \(Int(end.lowerBound))…\(Int(end.upperBound)) dock top \(Int(dockTop)) scroll room \(Int(web(tab).scrollView.adjustedContentInset.bottom))")
                    }
                }
                XCTAssertEqual(ObjectIdentifier(web(tab)), identity)
                XCTAssertEqual(js(web(tab), "+sessionStorage.n") as? Int, 1, "\(layout) \(page): reloaded")
            }
        }
    }
}
