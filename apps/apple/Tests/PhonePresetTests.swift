import XCTest
@testable import Browser_Setu

/// The iPhone's layouts are one spec of a few independent choices; presets are named specs. These pin what each means, that the choice is kept, and when folded controls
/// may open again.
@MainActor
final class PhonePresetTests: XCTestCase {
    func testEachPresetMeansWhatItSays() {
        // There is no Floating layout any more: it is not a preset, and a phone that had it gets the Bottom Bar.
        XCTAssertFalse(PhonePreset.allCases.map(\.rawValue).contains("floating"))

        // The compact layouts: one slim sheet, bottom or top.
        let cb = PhonePreset.compactBottom.spec!, ct = PhonePreset.compactTop.spec!
        XCTAssertTrue(cb.compactBar && ct.compactBar)
        XCTAssertEqual(cb.barAddress, .bottom); XCTAssertEqual(ct.barAddress, .top)
        XCTAssertFalse(cb.sticky || ct.sticky)

        let bottom = PhonePreset.bottomBar.spec!, top = PhonePreset.topBar.spec!
        XCTAssertFalse(bottom.usesDock); XCTAssertFalse(top.usesDock)
        XCTAssertEqual(bottom.barAddress, .bottom); XCTAssertEqual(top.barAddress, .top)
        XCTAssertFalse(bottom.sticky, "the bar returns when you scroll back, as Safari's does")
        XCTAssertTrue(bottom.folds)

        let immersive = PhonePreset.immersive.spec!
        XCTAssertTrue(immersive.usesDock); XCTAssertTrue(immersive.staysFolded); XCTAssertTrue(immersive.sticky)
        XCTAssertTrue(immersive.fanOut, "one address pill; + , reload and tabs fan out of it")
        XCTAssertTrue(immersive.tabsPill && immersive.newTabPill)
        XCTAssertFalse(bottom.compactBar || top.compactBar, "the regular bars are the card")
        XCTAssertNil(PhonePreset.custom.spec, "Custom's spec is the person's own")
        for preset in PhonePreset.allCases { XCTAssertFalse(preset.summary.isEmpty); XCTAssertFalse(preset.title.isEmpty) }
    }

    func testPillsOnlyAlwaysMeansFoldedWhateverElseWasChosen() {
        var spec = PhoneLayoutSpec.bottomBar
        spec.style = .pills; spec.reading = .alwaysShown
        XCTAssertEqual(spec.effectiveReading, .alwaysFolded)
        XCTAssertTrue(spec.staysFolded)
        spec.style = .floating
        XCTAssertFalse(spec.staysFolded)
        XCTAssertFalse(PhoneLayoutSpec(style: .attached, address: .top, reading: .alwaysShown, tabsPill: false, newTabPill: false).folds)
    }

    func testAnEarlierVersionsSavedNamesStillMeanWhatTheyDid() {
        XCTAssertEqual(PhonePreset(stored: "dock"), .bottomBar)
        XCTAssertEqual(PhonePreset(stored: "floating"), .bottomBar, "the removed layout reads as the Bottom Bar")
        XCTAssertEqual(PhonePreset(stored: "reading"), .immersive)
        XCTAssertEqual(PhonePreset(stored: "topBar"), .topBar)
        XCTAssertNil(PhonePreset(stored: "nonsense"))
    }

    func testTheChoiceAndACustomLayoutAreKeptAcrossARestartAndDefaultToTheBottomBar() async throws {
        let root = NSTemporaryDirectory() + "bs-phone-preset-\(UUID().uuidString)"
        let first = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await first.start()
        XCTAssertEqual(first.phonePreset, .bottomBar)
        first.phoneCustomSpec = PhoneLayoutSpec(style: .attached, address: .top, reading: .foldsAndStays, tabsPill: false, newTabPill: false)
        first.phonePreset = .custom
        let second = BrowserModel(engine: WebKitEngine(), root: root, profile: "default")
        await second.start()
        XCTAssertEqual(second.phonePreset, .custom)
        XCTAssertEqual(second.phoneSpec.style, .attached)
        XCTAssertEqual(second.phoneSpec.barAddress, .top)
        XCTAssertEqual(second.phoneSpec.reading, .foldsAndStays)
    }

    func testFoldingTheToolbarAtOnceWorksAndExpandingStillUndoesIt() {
        var chrome = ScrollChrome()
        XCTAssertFalse(chrome.collapsed)
        chrome.collapse()
        XCTAssertTrue(chrome.collapsed)
        chrome.expand()
        XCTAssertFalse(chrome.collapsed)
    }

    func testFoldedControlsOpenOnlyWhenAPersonAsksInTheStickyLayouts() {
        // Sticky layouts on the phone: automatic requests and scrolling are ignored once folded.
        XCTAssertTrue(ChromeFoldPolicy.ignoresAutomaticExpand(isPhone: true, sticky: PhoneLayoutSpec(style: .floating, address: .bottom, reading: .foldsAndStays, tabsPill: true, newTabPill: true).sticky))
        XCTAssertTrue(ChromeFoldPolicy.ignoresAutomaticExpand(isPhone: true, sticky: PhoneLayoutSpec.immersive.sticky))
        XCTAssertTrue(ChromeFoldPolicy.ignoresScroll(isPhone: true, collapsed: true, sticky: true))
        // Not before they have folded: the first scroll down must still fold them.
        XCTAssertFalse(ChromeFoldPolicy.ignoresScroll(isPhone: true, collapsed: false, sticky: true))
        // Not in the layouts that return on scroll-back (the bar layouts), nor on the iPad or the Mac.
        XCTAssertFalse(ChromeFoldPolicy.ignoresAutomaticExpand(isPhone: true, sticky: PhoneLayoutSpec.bottomBar.sticky))
        XCTAssertFalse(ChromeFoldPolicy.ignoresScroll(isPhone: true, collapsed: true, sticky: PhoneLayoutSpec.topBar.sticky))
        XCTAssertFalse(ChromeFoldPolicy.ignoresAutomaticExpand(isPhone: false, sticky: true))
        XCTAssertFalse(ChromeFoldPolicy.ignoresScroll(isPhone: false, collapsed: true, sticky: true))
    }

    func testALayoutSavedByAnEarlierVersionStillReadsAndTheNewChoicesAreOff() throws {
        let old = Data(#"{"style":"attached","address":"top","reading":"foldsAndReturns","tabsPill":false,"newTabPill":false}"#.utf8)
        let spec = try JSONDecoder().decode(PhoneLayoutSpec.self, from: old)
        XCTAssertEqual(spec.style, .attached)
        XCTAssertFalse(spec.compactBar); XCTAssertFalse(spec.fanOut)
        var chosen = spec; chosen.compactBar = true; chosen.fanOut = true
        let again = try JSONDecoder().decode(PhoneLayoutSpec.self, from: try JSONEncoder().encode(chosen))
        XCTAssertTrue(again.compactBar && again.fanOut, "the choices are saved")
    }
}
