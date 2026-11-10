import XCTest
@testable import Browser_Setu

final class FloatingPlayerLayoutTests: XCTestCase {
    private let window = CGSize(width: 1000, height: 700), panel = CGSize(width: 372, height: 300)

    func testThePanelIsAlwaysFullyInsideTheWindowWhateverIsStored() {
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.84), (0.0, 1.0), (1.0, 0.0)] {
            let o = FloatingPlayerLayout(x: x, y: y).origin(panel: panel, in: window)
            XCTAssertGreaterThanOrEqual(o.x, FloatingPlayerLayout.margin); XCTAssertGreaterThanOrEqual(o.y, FloatingPlayerLayout.margin)
            XCTAssertLessThanOrEqual(o.x + panel.width, window.width - FloatingPlayerLayout.margin + 0.001)
            XCTAssertLessThanOrEqual(o.y + panel.height, window.height - FloatingPlayerLayout.margin + 0.001)
        }
        let tiny = FloatingPlayerLayout.standard.origin(panel: panel, in: CGSize(width: 200, height: 100))
        XCTAssertEqual(tiny, CGPoint(x: 10, y: 10), "a window smaller than the panel pins it to the corner instead of pushing it out of view")
    }

    func testItKeepsItsRelativePlaceWhenTheWindowIsResized() {
        let layout = FloatingPlayerLayout.dropped(origin: CGPoint(x: 400, y: 200), panel: panel, in: window, snap: false)
        let a = layout.origin(panel: panel, in: window)
        XCTAssertEqual(a.x, 400, accuracy: 0.5); XCTAssertEqual(a.y, 200, accuracy: 0.5)
        let bigger = layout.origin(panel: panel, in: CGSize(width: 2000, height: 1400))
        XCTAssertGreaterThan(bigger.x, a.x); XCTAssertGreaterThan(bigger.y, a.y)
    }

    func testDroppingNearAnEdgeSettlesAgainstItAndFarFromOneStaysPut() {
        let m = FloatingPlayerLayout.margin
        let corner = FloatingPlayerLayout.dropped(origin: CGPoint(x: 18, y: 20), panel: panel, in: window).origin(panel: panel, in: window)
        XCTAssertEqual(corner, CGPoint(x: m, y: m))
        let right = FloatingPlayerLayout.dropped(origin: CGPoint(x: 1000 - 372 - 12, y: 300), panel: panel, in: window).origin(panel: panel, in: window)
        XCTAssertEqual(right.x, 1000 - 372 - m, accuracy: 0.5); XCTAssertEqual(right.y, 300, accuracy: 0.5)
        let middle = FloatingPlayerLayout.dropped(origin: CGPoint(x: 300, y: 150), panel: panel, in: window).origin(panel: panel, in: window)
        XCTAssertEqual(middle.x, 300, accuracy: 0.5); XCTAssertEqual(middle.y, 150, accuracy: 0.5)
        let outside = FloatingPlayerLayout.dropped(origin: CGPoint(x: -500, y: 9000), panel: panel, in: window).origin(panel: panel, in: window)
        XCTAssertEqual(outside, CGPoint(x: m, y: 700 - 300 - m), "dragged out of the window it comes to rest at the nearest edge")
    }

    func testTheStoredFormRoundTripsAndBadValuesGiveTheUsualPlace() {
        let l = FloatingPlayerLayout(x: 0.25, y: 0.5)
        XCTAssertEqual(FloatingPlayerLayout(stored: l.stored), l)
        for bad in [nil, "", "x", "0.5", "2,0.5", "-1,0", "nan,0.5", "0.1,0.2,0.3"] { XCTAssertEqual(FloatingPlayerLayout(stored: bad), .standard, "\(bad ?? "nil")") }
    }
}

final class FloatingPlayerRuleTests: XCTestCase {
    func testItOpensWhenPlaybackStartsAndOnlyThen() {
        XCTAssertTrue(FloatingPlayerRules.shouldOpen(wasPlaying: false, isPlaying: true, autoShow: true, alreadyOpen: false))
        XCTAssertFalse(FloatingPlayerRules.shouldOpen(wasPlaying: true, isPlaying: true, autoShow: true, alreadyOpen: false), "already playing: no new start")
        XCTAssertFalse(FloatingPlayerRules.shouldOpen(wasPlaying: true, isPlaying: false, autoShow: true, alreadyOpen: false), "stopping does not open it")
        XCTAssertFalse(FloatingPlayerRules.shouldOpen(wasPlaying: false, isPlaying: true, autoShow: false, alreadyOpen: false), "switched off in Settings")
        XCTAssertFalse(FloatingPlayerRules.shouldOpen(wasPlaying: false, isPlaying: true, autoShow: true, alreadyOpen: true))
    }

    func testSwitchingToATabThatIsNotPlayingClosesItButAPlayingOneKeepsIt() {
        XCTAssertTrue(FloatingPlayerRules.shouldCloseOnTabChange(open: true, newTabIsPlaying: false))
        XCTAssertFalse(FloatingPlayerRules.shouldCloseOnTabChange(open: true, newTabIsPlaying: true))
        XCTAssertFalse(FloatingPlayerRules.shouldCloseOnTabChange(open: false, newTabIsPlaying: false))
    }

    func testTextContrastFollowsThePanelColour() {
        XCTAssertTrue(FloatingPlayerRules.isDark(red: 0.05, green: 0.05, blue: 0.1))
        XCTAssertFalse(FloatingPlayerRules.isDark(red: 0.95, green: 0.95, blue: 0.9))
        XCTAssertFalse(FloatingPlayerRules.isDark(red: 0.2, green: 0.9, blue: 0.2), "a bright green is light")
    }
}

@MainActor
final class FloatingPlayerModelTests: XCTestCase {
    func testOpeningAndClosingAndTheSettingsAreKept() async {
        let root = NSTemporaryDirectory() + "bs-fp-\(UUID().uuidString)"
        let m = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        XCTAssertFalse(m.floatingPlayerOpen); XCTAssertTrue(m.autoShowPlayer, "on by default"); XCTAssertEqual(m.floatingPlayerLayout, .standard)
        m.openFloatingPlayer()
        XCTAssertTrue(m.floatingPlayerOpen); XCTAssertTrue(m.playerPanelVisible, "the controls start looking for the player at once")
        m.closeFloatingPlayer()
        XCTAssertFalse(m.floatingPlayerOpen); XCTAssertFalse(m.playerPanelVisible)
        m.autoShowPlayer = false
        m.floatingPlayerLayout = FloatingPlayerLayout(x: 0.2, y: 0.3)
        XCTAssertEqual((try? m.core.getSetting(key: "player_auto_show")) ?? nil, "0")
        XCTAssertEqual((try? m.core.getSetting(key: "player_position")) ?? nil, "0.2000,0.3000")
    }

    func testClosingItLeavesThePlayerRunningWhenPageToolsIsShowingIt() async {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-fp2-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        m.sheet = .pageTools
        m.openFloatingPlayer()
        m.closeFloatingPlayer()
        XCTAssertTrue(m.playerPanelVisible, "the Video tab in Page Tools still uses it")
    }
}
