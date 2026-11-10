import XCTest
@testable import Browser_Setu

// Unsaved-change protection, the private window's close question and tint, and the floating player across window sizes.

final class SheetDismissalRuleTests: XCTestCase {
    func testNothingUnsavedClosesAtOnceAndAnythingUnsavedAsks() {
        XCTAssertEqual(SheetDismissal.outcome(isDirty: false), .close)
        XCTAssertEqual(SheetDismissal.outcome(isDirty: true), .askFirst)
    }

    func testSaveIsOfferedOnlyWhereTheEditorHasOneDirectSave() {
        XCTAssertEqual(SheetDismissal.choices(canSave: true), ["Save", "Discard Changes", "Keep Editing"])
        XCTAssertEqual(SheetDismissal.choices(canSave: false), ["Discard Changes", "Keep Editing"])
    }
}

@MainActor
final class SheetDismissalModelTests: XCTestCase {
    private func model() async -> BrowserModel {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-sd-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        return m
    }

    func testDoneClosesASheetThatHoldsNothingAndLeavesAnEditorToAnswerForItself() async {
        let m = await model()
        m.sheet = .qr
        m.requestSheetDismiss()
        XCTAssertNil(m.sheet, "an ordinary sheet closes at once")

        m.sheet = .note
        m.sheetGuardActive = true
        let before = m.sheetDismissRequest
        m.requestSheetDismiss()
        XCTAssertEqual(m.sheet, .note, "an editor that registered answers the request itself, so the sheet is still here")
        XCTAssertEqual(m.sheetDismissRequest, before + 1)
        m.sheetGuardActive = false
        m.sheet = nil
    }

    func testEveryEditorSheetThatCanLoseWorkIsGuardedAndTheOthersAreNot() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Shared/ResearchNotes.swift", "Shared/ScreenshotEditor.swift", "Shared/PDFEditor.swift"] {
            let text = try String(contentsOf: apple.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains(".guardsUnsavedChanges("), "\(file) must ask before discarding edits")
        }
        for file in ["Shared/ScreenshotEditor.swift", "Shared/PDFEditor.swift"] {
            let text = try String(contentsOf: apple.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(text.contains("if !sheetProvidesDone"), "\(file) must not add a second Done beside the sheet's own")
        }
        let container = try String(contentsOf: apple.appendingPathComponent("Shared/SharedViews.swift"), encoding: .utf8)
        XCTAssertTrue(container.contains("requestSheetDismiss()"), "the sheet's Done and Escape go through the unsaved-changes check")
    }
}

final class PrivateWindowClosingTests: XCTestCase {
    func testItAsksOnlyWhileDownloadsAreRunningAndNeverWhenTheAppQuits() {
        XCTAssertEqual(PrivateWindowClosing.decision(activeDownloads: 0, appIsQuitting: false), .closeNow)
        XCTAssertEqual(PrivateWindowClosing.decision(activeDownloads: 2, appIsQuitting: false), .askFirst(running: 2))
        XCTAssertEqual(PrivateWindowClosing.decision(activeDownloads: 2, appIsQuitting: true), .closeNow)
    }

    func testTheMessageIsPlainAndSaysFinishedFilesStay() {
        XCTAssertTrue(PrivateWindowClosing.message(running: 1).contains("1 private download is still running"))
        XCTAssertTrue(PrivateWindowClosing.message(running: 3).contains("3 private downloads are still running"))
        XCTAssertTrue(PrivateWindowClosing.message(running: 2).contains("Files that finished downloading are not touched"))
    }

    @MainActor func testOnlyThisPrivateWindowsUnfinishedDownloadsAreCounted() async {
        let m = BrowserModel(engine: WebKitEngine(), root: NSTemporaryDirectory() + "bs-pc-\(UUID().uuidString)", profile: "default")
        m.wifiKeys = MemoryWiFiKeys()
        await m.start()
        func record(_ name: String, session: UUID?, finish: Bool) {
            let id = m.downloads.ledger.create(protocolID: .webKit, source: URL(string: "https://example.test/\(name)"), filename: name, isPrivate: session != nil).id
            m.downloads.ledger.update(id) { $0.privateSession = session }
            for e in [DownloadEvent.queued, .started, .running] { _ = m.downloads.ledger.apply(e, to: id) }
            if finish { _ = m.downloads.ledger.apply(.cancelled, to: id) }
        }
        XCTAssertEqual(m.activePrivateDownloadCount, 0, "an ordinary window has none to lose")
        m.isPrivateWindow = true
        record("mine-running", session: m.privateSessionID, finish: false)
        record("mine-done", session: m.privateSessionID, finish: true)
        record("other-window", session: UUID(), finish: false)
        record("ordinary", session: nil, finish: false)
        XCTAssertEqual(m.activePrivateDownloadCount, 1)
        for (id, r) in m.downloads.ledger.records where !r.state.isFinal { m.downloads.cancel(id) }
    }
}

#if os(macOS)
final class PrivateWindowTintTests: XCTestCase {
    func testTheWashIsQuietAndStrongerInTheDark() {
        let light = PrivateWindowTintLayer.opacity(dark: false), dark = PrivateWindowTintLayer.opacity(dark: true)
        XCTAssertGreaterThan(dark, light)
        XCTAssertLessThan(dark, 0.3, "never enough to tint the controls' own colours"); XCTAssertGreaterThan(light, 0.05, "still visible in the light")
    }
}
#endif

final class FloatingPlayerResizeTests: XCTestCase {
    private let panel = CGSize(width: 372, height: 300)

    func testShrinkingAndRegrowingTheWindowBringsThePanelBackToWhereItWas() {
        let layout = FloatingPlayerLayout.dropped(origin: CGPoint(x: 900, y: 500), panel: panel, in: CGSize(width: 1400, height: 900), snap: false)
        let big = layout.origin(panel: panel, in: CGSize(width: 1400, height: 900))
        for small in [CGSize(width: 500, height: 350), CGSize(width: 200, height: 100)] {
            let squeezed = layout.origin(panel: panel, in: small)
            XCTAssertGreaterThanOrEqual(squeezed.x, FloatingPlayerLayout.margin); XCTAssertGreaterThanOrEqual(squeezed.y, FloatingPlayerLayout.margin)
        }
        let again = layout.origin(panel: panel, in: CGSize(width: 1400, height: 900))
        XCTAssertEqual(again.x, big.x, accuracy: 0.001); XCTAssertEqual(again.y, big.y, accuracy: 0.001)
        XCTAssertEqual(layout, FloatingPlayerLayout.dropped(origin: CGPoint(x: 900, y: 500), panel: panel, in: CGSize(width: 1400, height: 900), snap: false), "looking at a smaller window does not change what is stored")
    }

    func testFullScreenAndAnyDisplaySizeKeepThePanelInsideAndThePositionIsRelativeToTheWindowNotTheScreen() {
        let layout = FloatingPlayerLayout(x: 0.9, y: 0.9)
        for size in [CGSize(width: 1710, height: 1112), CGSize(width: 1920, height: 1080), CGSize(width: 3840, height: 2160), CGSize(width: 1280, height: 720)] {
            let o = layout.origin(panel: panel, in: size)
            XCTAssertLessThanOrEqual(o.x + panel.width, size.width - FloatingPlayerLayout.margin + 0.001, "\(size)")
            XCTAssertLessThanOrEqual(o.y + panel.height, size.height - FloatingPlayerLayout.margin + 0.001, "\(size)")
            XCTAssertGreaterThanOrEqual(o.x, FloatingPlayerLayout.margin); XCTAssertGreaterThanOrEqual(o.y, FloatingPlayerLayout.margin)
        }
        // The layout is a pair of fractions of the window: nothing in it refers to a screen, so moving the window to another display (x of 1815 on a second one) changes nothing.
        XCTAssertEqual(FloatingPlayerLayout(stored: layout.stored), layout)
    }
}

#if os(macOS)
import AppKit

final class NoScrollBarsTests: XCTestCase {
    @MainActor func testAScrollViewLosesItsScrollersAfterItLaysOutButStillScrolls() {
        NoScrollBars.install()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
        scroll.documentView = document
        scroll.tile()
        XCTAssertFalse(scroll.hasVerticalScroller, "no vertical scroll bar"); XCTAssertFalse(scroll.hasHorizontalScroller, "no horizontal scroll bar")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 300))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 300, accuracy: 0.5, "it still scrolls")
        NoScrollBars.install()          // installing again changes nothing (no second swap that would undo the first)
        scroll.hasVerticalScroller = true; scroll.tile()
        XCTAssertFalse(scroll.hasVerticalScroller)
    }

    func testTheSheetsAndTheWindowAreSetUpWithoutScrollBarsOrAStrayDoneBar() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let containers = try String(contentsOf: apple.appendingPathComponent("Shared/SharedViews.swift"), encoding: .utf8)
        XCTAssertTrue(containers.contains("SheetHeader(title: title)"), "a plain Mac sheet has its title and its one Done in a header")
        XCTAssertTrue(containers.contains("needsNavigation"), "only the sheets that push screens or carry toolbar buttons keep a navigation container")
        let app = try String(contentsOf: apple.appendingPathComponent("macOS/BrowserSetuMacApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("NoScrollBars.install()")); XCTAssertTrue(app.contains(".scrollIndicators(.hidden)"))
        for file in ["Shared", "macOS"] {
            let dir = apple.appendingPathComponent(file)
            let sources = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            for source in sources {
                let text = try String(contentsOf: source, encoding: .utf8)
                XCTAssertFalse(text.contains("scrollIndicators(.visible)") || text.contains("showsIndicators: true"), "\(source.lastPathComponent) turns scroll bars on")
            }
        }
    }
}
#endif

#if os(macOS)
final class NoScrollBarsRuleTests: XCTestCase {
    func testScrollBarsAreRemovedOnlyFromTheAppsOwnSurfaces() {
        func hide(panel: Bool = false, assistive: Bool = false, web: Bool = false, wantsBars: Bool = false) -> Bool {
            NoScrollBars.shouldHide(isSystemPanel: panel, assistiveTechnologyRunning: assistive, insideWebView: web, personWantsScrollBars: wantsBars)
        }
        XCTAssertTrue(hide(), "the app's own lists, forms and tables")
        XCTAssertFalse(hide(panel: true), "not in the system's Open and Save panels")
        XCTAssertFalse(hide(assistive: true), "not while VoiceOver or Switch Control is running")
        XCTAssertFalse(hide(web: true), "not inside a web view")
        XCTAssertFalse(hide(wantsBars: true), "not for a person who asked for the bars back")
    }

    @MainActor func testTheOptOutBringsTheScrollersBack() {
        NoScrollBars.install()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: NoScrollBars.showScrollBarsKey)
        defer { defaults.removeObject(forKey: NoScrollBars.showScrollBarsKey) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 900))
        scroll.tile()
        XCTAssertTrue(scroll.hasVerticalScroller, "with the opt-out set, the scroller stays")
        defaults.removeObject(forKey: NoScrollBars.showScrollBarsKey)
        scroll.tile()
        XCTAssertFalse(scroll.hasVerticalScroller)
    }
}

final class DownloadRowDetailTests: XCTestCase {
    func testADownloadingRowInTheTableShowsOnlyHowMuchHasArrived() {
        let long = "1.2 MB of 8.4 MB · 150 KB/s · about 48 s left"
        XCTAssertEqual(DownloadNameCell.detail(for: long, downloading: true, inTable: true), "1.2 MB of 8.4 MB", "speed and time left have their own columns")
        XCTAssertEqual(DownloadNameCell.detail(for: long, downloading: true, inTable: false), long, "the popover has no such columns")
        XCTAssertEqual(DownloadNameCell.detail(for: "2 MB · Nov 7, 2026 at 5:07 PM", downloading: false, inTable: true), "2 MB · Nov 7, 2026 at 5:07 PM", "a finished row keeps its date")
        XCTAssertEqual(DownloadNameCell.detail(for: "Waiting for a free place", downloading: false, inTable: true), "Waiting for a free place")
        XCTAssertEqual(DownloadNameCell.detail(for: "", downloading: true, inTable: true), "")
    }
}
#endif

final class FloatingPlayerSurfaceTests: XCTestCase {
    func testTheSurfaceIsFullyOpaqueSoNothingOfThePageCanInterfereWithTheControls() {
        XCTAssertEqual(FloatingPlayerLayout.surfaceOpacity, 1.0, "readability comes before transparency; the colour still follows the theme and the page")
    }
}
