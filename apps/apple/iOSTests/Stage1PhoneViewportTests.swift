import XCTest
import SwiftUI
import UIKit
import WebKit
@testable import Browser_Setu

/// Stage 1: the iPhone viewport resolver in shadow mode, checked with the real `PhoneRootView` hosted in a real `UIWindow` of the app's scene (not an offscreen web view).
/// For each case: the screen's own values stay in charge; the resolver must agree with them (`ViewportShadow`), no edge may be compensated twice, what the web view
/// actually has must equal what the screen asked for, no web view may be replaced except by a deliberate discard, and no page may reload. Throwaway profile per test.
@MainActor
final class Stage1PhoneViewportTests: XCTestCase {
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

    private var host: Host?
    private var model: BrowserModel!

    override func setUpWithError() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the Stage 1 iPhone tests need an iPhone simulator or device")
        ViewportShadow.reset()
        ViewportShadow.enabled = true
        model = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-stage1-\(UUID().uuidString)", profile: "default")
    }

    override func tearDown() {
        host?.tearDown(); host = nil; model = nil
        super.tearDown()
    }

    // MARK: helpers

    @discardableResult
    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    /// Lets layout, the 0.25 s inset animation and the 350 ms re-application finish.
    private func settle() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let web = activeWeb else { return }
        waitUntil(3) { abs(web.scrollView.contentInset.top - model.phoneTopInset) < 0.5 && abs(web.scrollView.contentInset.bottom - model.phoneBottomInset) < 0.5 }
    }

    /// A page with a fixed header and footer, a sticky heading and long content. `sessionStorage.n` counts its loads, so a reload shows up as 2.
    private static func html(_ label: String) -> String {
        """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"><style>
        body{margin:0;font:16px -apple-system} header,footer{position:fixed;left:0;right:0;height:44px;background:#ccc} header{top:0} footer{bottom:0}
        h2{position:sticky;top:0;background:#eee;margin:0} main{height:4000px;padding-top:44px}
        </style></head><body><header id="h">\(label)</header><main><h2>sticky</h2><p>content</p></main><footer id="f">foot</footer>
        <script>sessionStorage.n=(+sessionStorage.n||0)+1</script></body></html>
        """
    }

    private func pageTab(_ label: String, isPrivate: Bool = false, select: Bool = true) -> TabController {
        let tab = model.openTab(url: nil, isPrivate: isPrivate, select: select)
        tab.engine.showHTML(Self.html(label), baseURL: URL(string: "https://\(label).example.test/"))
        waitUntil(8) { !tab.isBlank && !tab.isLoading }
        return tab
    }

    private func web(_ tab: TabController) -> WKWebView { (tab.engine as! WebKitTab).webView }
    private var activeWeb: WKWebView? { model.active.map(web) }

    private func loads(_ tab: TabController) -> Int {
        var result = -1
        web(tab).evaluateJavaScript("+sessionStorage.n") { value, _ in result = (value as? Int) ?? -2 }
        waitUntil(3) { result != -1 }
        return result
    }

    /// What a real keyboard does when it rises or falls: the screen hears its frame (KeyboardLift) and lays out again. The field focus itself is not driven here.
    private func keyboard(up: Bool) {
        let screen = host?.window.windowScene?.screen.bounds ?? UIScreen.main.bounds
        let frame = up ? CGRect(x: 0, y: screen.height - 336, width: screen.width, height: 336) : CGRect(x: 0, y: screen.height, width: screen.width, height: 336)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: frame, UIResponder.keyboardAnimationDurationUserInfoKey: 0.25])
    }

    /// A window-only picture of the hosted screen, attached to the result bundle (never the whole device screen).
    private func picture(_ name: String) {
        guard let window = host?.window else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "layout-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func start(_ preset: PhonePreset) -> TabController {
        model.phonePreset = preset
        let tab = pageTab("first")
        host = Host(model: model)
        waitUntil(5) { activeWeb?.window != nil }
        settle()
        return tab
    }

    /// The checks every settled state must pass.
    private func assertConsistent(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(ViewportShadow.mismatches, 0, "\(label): resolver and screen disagree: \(ViewportShadow.lastMismatch ?? "")", file: file, line: line)
        XCTAssertEqual(ViewportShadow.doubleCompensations, 0, "\(label): an edge was reserved and told to WebKit", file: file, line: line)
        XCTAssertEqual(ViewportShadow.toldMismatches, 0, "\(label): the told formula differs", file: file, line: line)
        guard let web = activeWeb, let sample = ViewportShadow.lastSample else { return XCTFail("\(label): nothing hosted or sampled", file: file, line: line) }
        // What the web view has is what the screen asked for.
        XCTAssertEqual(web.scrollView.contentInset.top, model.phoneTopInset, accuracy: 0.5, "\(label): applied top", file: file, line: line)
        XCTAssertEqual(web.scrollView.contentInset.bottom, model.phoneBottomInset, accuracy: 0.5, "\(label): applied bottom", file: file, line: line)
        XCTAssertEqual(model.phoneTopInset, sample.legacy.overlayTop, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(web.minimumViewportInset.top, model.phoneTopInset + web.safeAreaInsets.top, accuracy: 0.5, "\(label): told top", file: file, line: line)
        XCTAssertEqual(web.minimumViewportInset.bottom, model.phoneBottomInset + web.safeAreaInsets.bottom, accuracy: 0.5, "\(label): told bottom", file: file, line: line)
        // A reserved bottom edge really shortens the page view, and is then not told to WebKit.
        if let window = web.window, sample.legacy.reservedPageBottom > 0 {
            let frame = web.convert(web.bounds, to: window)
            XCTAssertEqual(window.bounds.height - frame.maxY, sample.legacy.reservedPageBottom + sample.legacy.reservedAreaBottom, accuracy: 1.5, "\(label): reserved room", file: file, line: line)
            XCTAssertEqual(web.scrollView.contentInset.bottom, 0, accuracy: 0.5, file: file, line: line)
        }
        print("STAGE1 \(label): legacy \(sample.legacy) webFrameInWindow \(web.window.map { web.convert(web.bounds, to: $0) } ?? .zero) contentInset \(web.scrollView.contentInset.top)/\(web.scrollView.contentInset.bottom) told \(web.minimumViewportInset.top)/\(web.minimumViewportInset.bottom) safe \(web.safeAreaInsets.top)/\(web.safeAreaInsets.bottom) writer \(ViewportShadow.writerCalls)/applied \(ViewportShadow.applied)/unchanged \(ViewportShadow.unchanged) samples \(ViewportShadow.samples)")
    }

    // MARK: basic geometry, every preset

    func testEveryPresetAgreesWithTheResolverKeepsTheWebViewAndDoesNotReload() {
        let tab = start(.bottomBar)
        let identity = ObjectIdentifier(web(tab))
        assertConsistent("bottomBar")
        for preset in [PhonePreset.topBar, .compactBottom, .compactTop, .immersive, .bottomBar] {
            let before = (ViewportShadow.writerCalls, ViewportShadow.applied)
            model.phonePreset = preset
            settle()
            assertConsistent("\(preset)")
            picture("\(preset)")
            print("STAGE1 transition to \(preset): writer calls \(ViewportShadow.writerCalls - before.0), applied \(ViewportShadow.applied - before.1)")
            XCTAssertEqual(ObjectIdentifier(web(tab)), identity, "\(preset): the web view was replaced")
        }
        XCTAssertEqual(loads(tab), 1, "a layout change reloaded the page")
    }

    func testTopSheetIsOverlayAndThePageRunsUnderIt() {
        let tab = start(.topBar)
        assertConsistent("topBar")
        let w = web(tab)
        XCTAssertGreaterThan(w.scrollView.contentInset.top, 0)
        XCTAssertEqual(w.convert(w.bounds, to: w.window).minY, 0, accuracy: 0.5, "the page runs to the top edge, under the sheet")
    }

    // MARK: rapid changes

    func testRapidPresetChangesEndOnTheLatestState() {
        let tab = start(.topBar)
        let identity = ObjectIdentifier(web(tab))
        // Five changes inside one run-loop turn.
        for preset in [PhonePreset.bottomBar, .compactTop, .topBar, .immersive, .compactBottom] { model.phonePreset = preset }
        settle()
        assertConsistent("rapid → compactBottom")
        XCTAssertEqual(model.phoneTopInset, 0, "the latest state (a bottom sheet) has no top overlay")
        XCTAssertEqual(ViewportShadow.lastSample?.input.sheetAtBottom, true)
        for preset in [PhonePreset.compactBottom, .bottomBar, .compactTop] { model.phonePreset = preset }
        settle()
        assertConsistent("rapid → compactTop")
        XCTAssertEqual(model.phoneTopInset, 62, accuracy: 0.5)
        XCTAssertEqual(ObjectIdentifier(web(tab)), identity)
        XCTAssertEqual(loads(tab), 1)
    }

    func testRapidTabSwitchesKeepEveryWebViewAndTheFrontTabGetsTheCurrentGeometry() {
        let a = start(.topBar)
        let b = pageTab("second"), c = pageTab("third")
        let identities = [a, b, c].map { ObjectIdentifier(web($0)) }
        for tab in [a, b, c, a, b] { model.select(tab.id) }
        settle()
        XCTAssertEqual(model.activeID, b.id)
        assertConsistent("tabs → b")
        XCTAssertEqual([a, b, c].map { ObjectIdentifier(web($0)) }, identities, "switching tabs replaced a web view")
        // Every tab, shown or not, holds the same room (the model applies it to all of them).
        for tab in [a, b, c] { XCTAssertEqual(web(tab).scrollView.contentInset.top, model.phoneTopInset, accuracy: 0.5) }
        XCTAssertEqual([a, b, c].map(loads), [1, 1, 1], "switching tabs reloaded a page")
    }

    func testRepeatedIdenticalGeometryIsAppliedOnce() {
        let tab = start(.topBar)
        ViewportShadow.reset()
        for _ in 0..<20 { tab.applyBottomInset() }
        XCTAssertEqual(ViewportShadow.writerCalls, 20)
        XCTAssertEqual(ViewportShadow.applied, 0, "re-sending the same room must not touch WebKit again")
        XCTAssertEqual(ViewportShadow.unchanged, 20)
    }

    func testFoldingTheBarsAndEditingTheAddress() {
        let tab = start(.topBar)
        model.foldChrome(); settle()
        assertConsistent("topBar folded")
        picture("topBar-folded")
        XCTAssertEqual(model.phoneTopInset, 0)
        model.expandChrome(userRequested: true); settle()
        assertConsistent("topBar open")
        XCTAssertGreaterThan(model.phoneTopInset, 0)
        model.phonePreset = .bottomBar; settle()
        picture("bottomBar-open")
        model.foldChrome(); settle()
        assertConsistent("bottomBar folded")
        picture("bottomBar-folded")
        model.expandChrome(userRequested: true); settle()
        model.addressBar.isEditing = true; keyboard(up: true); settle()
        assertConsistent("bottomBar editing")
        picture("bottomBar-editing")
        XCTAssertEqual(ViewportShadow.lastSample?.legacy.reservedPageBottom ?? 0, 72, accuracy: 0.5, "editing card, no home strip")
        model.addressBar.isEditing = false; keyboard(up: false); settle()
        assertConsistent("bottomBar not editing")
        XCTAssertEqual(loads(tab), 1)
    }

    func testFixedFooterEndsAboveABottomSheet() {
        let tab = start(.bottomBar)
        assertConsistent("bottomBar footer")
        var footerBottom: Double = -1, viewport: Double = -1
        web(tab).evaluateJavaScript("[document.getElementById('f').getBoundingClientRect().bottom, window.innerHeight]") { value, _ in
            let pair = value as? [Double] ?? [-2, -2]; footerBottom = pair[0]; viewport = pair[1]
        }
        waitUntil(3) { footerBottom != -1 }
        XCTAssertEqual(footerBottom, viewport, accuracy: 1, "the fixed footer sits at the foot of the page view, which ends above the sheet")
    }

    // MARK: lifecycle

    func testPrivateAndRestoredTabsGetTheCurrentGeometry() {
        let first = start(.topBar)
        let other = pageTab("other")
        let priv = pageTab("private", isPrivate: true)
        settle()
        assertConsistent("private tab")
        XCTAssertEqual(web(priv).scrollView.contentInset.top, model.phoneTopInset, accuracy: 0.5)
        // A discarded tab gets a new web view by design (TabLifecycle); when it is shown again it must get the current room.
        model.select(first.id); settle()
        let otherBefore = ObjectIdentifier(web(other))
        other.discard(reason: "Stage 1 test")
        XCTAssertTrue(other.isDiscarded)
        model.select(other.id)
        waitUntil(8) { !other.isDiscarded && !other.isLoading }
        settle()
        assertConsistent("restored tab")
        XCTAssertNotEqual(ObjectIdentifier(web(other)), otherBefore, "restoring replaces the web view, as the lifecycle intends")
        XCTAssertEqual(web(other).scrollView.contentInset.top, model.phoneTopInset, accuracy: 0.5)
    }

    // MARK: orientation

    func testLandscapeIfTheHostCanRotate() throws {
        let tab = start(.topBar)
        let identity = ObjectIdentifier(web(tab))
        guard let scene = host?.window.windowScene else { throw XCTSkip("no window scene") }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        let rotated = waitUntil(4) { scene.interfaceOrientation.isLandscape }
        try XCTSkipUnless(rotated, "this test host did not rotate; landscape is not covered by this run")
        host?.window.frame = scene.coordinateSpace.bounds
        settle()
        assertConsistent("landscape")
        picture("landscape-topBar")
        XCTAssertEqual(ViewportShadow.lastSample?.input.sheet, .compact, "on its side every bar layout is the compact bar")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        waitUntil(4) { scene.interfaceOrientation.isPortrait }
        host?.window.frame = scene.coordinateSpace.bounds
        settle()
        assertConsistent("portrait again")
        XCTAssertEqual(ObjectIdentifier(web(tab)), identity)
        XCTAssertEqual(loads(tab), 1)
    }
}
