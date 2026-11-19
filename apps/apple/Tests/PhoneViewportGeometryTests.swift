import XCTest
@testable import Browser_Setu

/// Stage 1: the pure iPhone viewport resolver. Expected values are the screen's own formulas (`PhoneRootView.floatingInsets`, `pageBottomRoom`, `pageReservedBottom`)
/// worked by hand with the real bar sizes, so a change to either side shows here.
final class PhoneViewportGeometryTests: XCTestCase {
    /// The values `PhoneRootView` passes in: `PhoneBarSheet.height(.card)` 134, `.compact` 48, the editing card 72, `PhoneChrome.height` 40, `PhoneChrome.dockLift` −8.
    private let metrics = PhoneViewportInput.Metrics(cardHeight: 134, compactHeight: 48, cardEditingHeight: 72, dockHeight: 40, dockLift: -8)

    private func input(safeTop: CGFloat = 59, safeBottom: CGFloat = 34, active: Bool = true, floatingBars: Bool = true, atBottom: Bool = false, hidden: Bool = false,
                       sheet: PhoneViewportInput.Sheet = .card, editing: Bool = false, keyboard: Bool? = nil, dock: Bool = false, fixedBottom: Bool = false,
                       landscape: Bool = false, dockStrip: Bool = false, floatingAddress: Bool = false) -> PhoneViewportInput {
        // Editing the address normally raises the keyboard; `keyboard` says otherwise (a hardware keyboard) or raises it for a field in the page.
        PhoneViewportInput(safeTop: safeTop, safeBottom: safeBottom, hasActiveTab: active, floatingBars: floatingBars, sheetAtBottom: atBottom, barsHidden: hidden,
                           sheet: sheet, editingAddress: editing, keyboardUp: keyboard ?? editing, showsDock: dock, pageHasFixedBottomBar: fixedBottom, landscape: landscape,
                           dockOnItsOwnStrip: dockStrip, floatingAddressVisible: floatingAddress, metrics: metrics)
    }

    private func out(_ top: CGFloat = 0, _ bottom: CGFloat = 0, page: CGFloat = 0, area: CGFloat = 0, scroll: CGFloat = 0) -> PhoneViewportOutput {
        PhoneViewportOutput(overlayTop: top, overlayBottom: bottom, reservedPageBottom: page, reservedAreaBottom: area, scrollRoomBottom: scroll)
    }

    // MARK: overlay versus reserved chrome

    func testFloatingTopSheetIsOverlayRoomOnly() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(sheet: .card)), out(138))       // 134 + 4
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(sheet: .compact)), out(62))     // 48 + 14
    }

    func testBottomSheetShortensThePageAndTellsWebKitNothing() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .card)), out(page: 168))       // 134 + home 34
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .compact)), out(page: 88))     // 48 + 6 + 34
    }

    func testEditingTheAddressDropsTheHomeStripAndUsesTheShortCard() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .card, editing: true)), out(page: 72))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .compact, editing: true)), out(page: 54))
        // Editing does not change a sheet at the top.
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(sheet: .card, editing: true)), out(138))
    }

    /// The home strip goes with the keyboard, not with editing: the keyboard hides the home indicator whichever field has it.
    func testTheHomeStripFollowsTheKeyboardNotTheAddressBar() {
        // A field in the page has the keyboard: full card or compact bar, no home strip.
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .card, keyboard: true)), out(page: 134))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .compact, keyboard: true)), out(page: 54))
        // Editing with no on-screen keyboard (a hardware keyboard): the short card, and the home indicator still shows.
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, sheet: .card, editing: true, keyboard: false)), out(page: 106))
    }

    func testNoVisibleChromeMeansNoRoom() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(hidden: true)), out())
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(atBottom: true, hidden: true)), out())
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(active: false)), out())
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(floatingBars: false)), out())
    }

    func testDockReservesRoomOnlyOverAPageWithItsOwnBottomBar() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(floatingBars: false, dock: true, fixedBottom: true)), out(area: 40))   // 40 − 8 + 8
        // An ordinary page runs under the floating dock and gets only the room to scroll its end clear of it.
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(floatingBars: false, dock: true, fixedBottom: false)), out(scroll: 40))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(floatingBars: false, dock: true, fixedBottom: true, landscape: true)), out())
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(floatingBars: false, dock: true, fixedBottom: true, dockStrip: true)), out())
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(floatingBars: false, dock: true, fixedBottom: true, floatingAddress: true)), out())
    }

    // MARK: safe areas, orientation, sizes

    func testSafeAreaOnlyAffectsTheHomeStripOfABottomSheet() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeTop: 0, safeBottom: 0, atBottom: true)), out(page: 134))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeTop: 0, safeBottom: 0)), out(138))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeTop: 47, safeBottom: 21, atBottom: true, sheet: .compact)), out(page: 75))
    }

    func testLandscapeUsesTheCompactSheet() {
        // The screen passes `.compact` in landscape; with no bottom home strip on its side.
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeTop: 0, safeBottom: 21, sheet: .compact, landscape: true)), out(62))
    }

    func testInvalidAndTransientValuesCountAsZero() {
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeBottom: .nan, atBottom: true)), out(page: 134))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeBottom: -20, atBottom: true)), out(page: 134))
        XCTAssertEqual(PhoneViewportGeometry.resolve(input(safeBottom: .infinity, atBottom: true)), out(page: 134))
        var zero = metrics; zero.cardHeight = 0
        var i = input(); i.metrics = zero
        XCTAssertEqual(PhoneViewportGeometry.resolve(i), out(4))
    }

    // MARK: rules that must hold for every input

    func testNoEdgeIsEverReservedAndToldToWebKitAndNothingIsNegative() {
        var count = 0
        let flags = 11
        for mask in 0..<(1 << flags) {
            func bit(_ n: Int) -> Bool { mask & (1 << n) != 0 }
            for sheet in [PhoneViewportInput.Sheet.card, .compact] {
                for safe in [(0.0, 0.0), (59.0, 34.0), (0.0, 21.0)] {
                    let i = input(safeTop: safe.0, safeBottom: safe.1, active: bit(0), floatingBars: bit(1), atBottom: bit(2), hidden: bit(3), sheet: sheet, editing: bit(4),
                                  dock: bit(5), fixedBottom: bit(6), landscape: bit(7), dockStrip: bit(8), floatingAddress: bit(9))
                    let o = PhoneViewportGeometry.resolve(i)
                    XCTAssertFalse(o.compensatesBottomTwice, "\(i)")
                    XCTAssertEqual(o.overlayBottom, 0, "a bottom bar is never told to WebKit as an inset")
                    XCTAssertFalse(o.overlayTop > 0 && o.reservedPageBottom > 0, "one sheet is either at the top or at the bottom: \(i)")
                    for v in [o.overlayTop, o.overlayBottom, o.reservedPageBottom, o.reservedAreaBottom] { XCTAssertTrue(v.isFinite && v >= 0) }
                    count += 1
                }
            }
        }
        XCTAssertEqual(count, 2048 * 2 * 3)
    }

    // MARK: iOS 26 and later: a bottom sheet overlays the page instead of shortening it

    func testOverlayModeMovesTheBottomSheetsRoomFromReservedToOverlay() {
        var card = input(atBottom: true, sheet: .card); card.bottomChromeOverlays = true
        XCTAssertEqual(PhoneViewportGeometry.resolve(card), out(0, 168))
        var compact = input(atBottom: true, sheet: .compact); compact.bottomChromeOverlays = true
        XCTAssertEqual(PhoneViewportGeometry.resolve(compact), out(0, 88))
        var editing = input(atBottom: true, sheet: .card, editing: true); editing.bottomChromeOverlays = true
        XCTAssertEqual(PhoneViewportGeometry.resolve(editing), out(0, 72))
        // A top sheet and the dock are not affected.
        var top = input(sheet: .card); top.bottomChromeOverlays = true
        XCTAssertEqual(PhoneViewportGeometry.resolve(top), out(138))
        // The dock over a page with its own bottom bar: covered strip from the screen's edge (dock room 40 + home strip 34); an ordinary page keeps scroll room only.
        var dock = input(floatingBars: false, dock: true, fixedBottom: true); dock.bottomChromeOverlays = true
        XCTAssertEqual(PhoneViewportGeometry.resolve(dock), out(0, 74))
        var ordinary = input(floatingBars: false, dock: true, fixedBottom: false); ordinary.bottomChromeOverlays = true
        XCTAssertEqual(PhoneViewportGeometry.resolve(ordinary), out(scroll: 40))
    }

    func testOverlayModeKeepsEveryAmountAndNeverCompensatesTwice() {
        for mask in 0..<(1 << 10) {
            func bit(_ n: Int) -> Bool { mask & (1 << n) != 0 }
            // The bar sheet (Attached style) and the dock (Floating / Pills styles) are different layout styles, never on together.
            if bit(1) && bit(5) { continue }
            for sheet in [PhoneViewportInput.Sheet.card, .compact] {
                var i = input(active: bit(0), floatingBars: bit(1), atBottom: bit(2), hidden: bit(3), sheet: sheet, editing: bit(4), dock: bit(5),
                              fixedBottom: bit(6), landscape: bit(7), dockStrip: bit(8), floatingAddress: bit(9))
                let reserved = PhoneViewportGeometry.resolve(i)
                i.bottomChromeOverlays = true
                let overlay = PhoneViewportGeometry.resolve(i)
                // Same room, other kind: the sheet's room as it was; the dock's room plus the home strip (the page now reaches the screen's edge).
                XCTAssertEqual(overlay.overlayBottom, reserved.reservedPageBottom + (reserved.reservedAreaBottom > 0 ? reserved.reservedAreaBottom + i.safeBottom : 0), "\(i)")
                XCTAssertEqual(overlay.reservedPageBottom, 0)
                XCTAssertEqual(overlay.reservedAreaBottom, 0)
                XCTAssertEqual(overlay.scrollRoomBottom, reserved.scrollRoomBottom)
                XCTAssertEqual(overlay.overlayTop, reserved.overlayTop)
                XCTAssertFalse(overlay.compensatesBottomTwice, "\(i)")
            }
        }
    }

    func testRepeatedInputGivesTheSameOutput() {
        let i = input(atBottom: true, sheet: .compact)
        let first = PhoneViewportGeometry.resolve(i)
        for _ in 0..<1000 { XCTAssertEqual(PhoneViewportGeometry.resolve(i), first) }
    }

    // MARK: what WebKit is told

    func testToldIsOverlayRoomPlusTheWebViewsOwnSafeArea() {
        let told = PhoneViewportGeometry.told(overlayTop: 138, overlayBottom: 0, webViewSafeTop: 59, webViewSafeBottom: 34)
        XCTAssertEqual(told.top, 197); XCTAssertEqual(told.bottom, 34)
        let clean = PhoneViewportGeometry.told(overlayTop: .nan, overlayBottom: -3, webViewSafeTop: 0, webViewSafeBottom: 0)
        XCTAssertEqual(clean.top, 0); XCTAssertEqual(clean.bottom, 0)
    }

    func testMatchingUsesAHalfPointTolerance() {
        XCTAssertTrue(out(138).matches(out(138.4)))
        XCTAssertFalse(out(138).matches(out(139)))
    }

    // MARK: Stage 1 budget: under 1 ms p95 per calculation

    func testResolverCostIsFarUnderOneMillisecond() {
        let inputs = [input(), input(atBottom: true), input(atBottom: true, editing: true), input(floatingBars: false, dock: true, fixedBottom: true), input(hidden: true)]
        var samples: [UInt64] = []
        samples.reserveCapacity(20_000)
        var sink: CGFloat = 0
        for n in 0..<20_000 {
            let start = DispatchTime.now().uptimeNanoseconds
            let o = PhoneViewportGeometry.resolve(inputs[n % inputs.count])
            samples.append(DispatchTime.now().uptimeNanoseconds - start)
            sink += o.overlayTop
        }
        samples.sort()
        let p50 = samples[samples.count / 2], p95 = samples[samples.count * 95 / 100], p99 = samples[samples.count * 99 / 100]
        print("STAGE1 resolver ns n=\(samples.count) p50=\(p50) p95=\(p95) p99=\(p99) max=\(samples.last!) (sink \(sink))")
        XCTAssertLessThan(p95, 1_000_000, "p95 must stay under 1 ms")
    }
}
