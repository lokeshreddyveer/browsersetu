import SwiftUI

/// The iPhone page's geometry, worked out in one place from plain values. Pure: no views, no web view, no model, no observers. `PhoneRootView` takes the page's
/// geometry from it (Stage 2; Stage 1 had run it in shadow beside the screen's own formulas, with no difference in any state) and the writer
/// (`WebKitTab.setViewportInsets`) applies what the screen passes on. DEBUG builds record frames, writes and the latest sample (`ViewportShadow`).
///
/// Coordinate spaces: every length is in points. Safe-area values are the window's (screen edges). The outputs are lengths along the page area's top and bottom
/// edges. Two kinds of room, never both on one edge:
///  - overlay room: chrome floats over the page, the page view keeps its size, and WebKit is told the covered band (viewport inset and scroll inset);
///  - reserved room: the page view itself is shortened, and WebKit is told nothing for that band.
struct PhoneViewportInput: Equatable {
    enum Sheet: Equatable { case card, compact }

    /// The bar and dock sizes, read from the same constants the screen uses (`PhoneBarSheet.height`, `PhoneChrome`).
    struct Metrics: Equatable {
        var cardHeight: CGFloat
        var compactHeight: CGFloat
        /// The card's height while the address is being edited (the keyboard is up and the card shrinks to its field).
        var cardEditingHeight: CGFloat
        var dockHeight: CGFloat
        var dockLift: CGFloat
    }

    /// Window safe area, top and bottom.
    var safeTop: CGFloat
    var safeBottom: CGFloat
    var hasActiveTab: Bool
    /// The bar layouts: one sheet of glass floats over the page.
    var floatingBars: Bool
    var sheetAtBottom: Bool
    var barsHidden: Bool
    var sheet: Sheet
    var editingAddress: Bool
    /// A keyboard is up (for the address bar or for a field in the page): it hides the home indicator, so no room is kept for it.
    var keyboardUp = false
    /// The Floating layout: a dock instead of bars.
    var showsDock: Bool
    var pageHasFixedBottomBar: Bool
    var landscape: Bool
    var dockOnItsOwnStrip: Bool
    var floatingAddressVisible: Bool
    var metrics: Metrics
    /// iOS 26 and later: a bar sheet along the bottom is told to WebKit as covered (`obscuredContentInsets`) instead of shortening the page, so the page runs under
    /// it and its fixed footers sit above it. The amount is the same either way; only its kind changes. The dock's room is not affected.
    var bottomChromeOverlays = false
}

struct PhoneViewportOutput: Equatable {
    /// Overlay room told to WebKit (top and bottom of the page area).
    var overlayTop: CGFloat
    var overlayBottom: CGFloat
    /// Reserved room: the page view is shortened by this at its foot, inside the page area (a bar sheet at the bottom).
    var reservedPageBottom: CGFloat
    /// Reserved room around the whole page area (the dock over a page that has its own fixed bottom bar, before iOS 26).
    var reservedAreaBottom: CGFloat
    /// Scrolling room only, from the safe-area line (the system adds the home strip): the dock floating over an ordinary page, so the end of the page can be scrolled
    /// clear of it. Nothing is told to WebKit as covered, so the page still shows around the floating dock.
    var scrollRoomBottom: CGFloat = 0

    /// True when an edge is both reserved and told to WebKit, which would push the page's content away twice.
    var compensatesBottomTwice: Bool { overlayBottom > 0 && (reservedPageBottom > 0 || reservedAreaBottom > 0) }

    /// Equal within `tolerance` points on every value.
    func matches(_ other: PhoneViewportOutput, tolerance: CGFloat = 0.5) -> Bool {
        abs(overlayTop - other.overlayTop) <= tolerance && abs(overlayBottom - other.overlayBottom) <= tolerance
            && abs(reservedPageBottom - other.reservedPageBottom) <= tolerance && abs(reservedAreaBottom - other.reservedAreaBottom) <= tolerance
            && abs(scrollRoomBottom - other.scrollRoomBottom) <= tolerance
    }
}

enum PhoneViewportGeometry {
    /// A length that is not finite or is negative (a window still being made, a value read mid-transition) counts as zero.
    static func clean(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : 0 }

    /// The room the sheet takes, with its gap.
    static func sheetRoom(_ input: PhoneViewportInput) -> CGFloat {
        switch input.sheet {
        case .card: return clean(input.metrics.cardHeight) + 4
        case .compact: return clean(input.metrics.compactHeight) + 14
        }
    }

    static func resolve(_ input: PhoneViewportInput) -> PhoneViewportOutput {
        let sheetOpen = input.floatingBars && !input.barsHidden && input.hasActiveTab
        // A sheet at the top floats over the page: overlay. A sheet at the bottom shortens the page instead, because before iOS 26 WebKit does not move a site's fixed
        // footers clear of room given only as an inset (from iOS 26 `obscuredContentInsets` does, see `bottomChromeOverlays`).
        let overlayTop = sheetOpen && !input.sheetAtBottom ? sheetRoom(input) : 0
        var reservedPageBottom: CGFloat = 0
        if sheetOpen, input.sheetAtBottom {
            // With a keyboard up the sheet sits on it, so no room is kept for the home indicator (whichever field has the keyboard).
            let home = input.keyboardUp ? 0 : clean(input.safeBottom)
            switch input.sheet {
            case .card: reservedPageBottom = (input.editingAddress ? clean(input.metrics.cardEditingHeight) : clean(input.metrics.cardHeight)) + home
            case .compact: reservedPageBottom = clean(input.metrics.compactHeight) + 6 + home
            }
        }
        // The dock (Floating and Immersive layouts) at the bottom: its height and a small gap, from the safe-area line. Kept the same when the dock folds into its pill,
        // so the page does not change size while it is scrolled.
        let dockShown = input.showsDock && !input.landscape && !input.dockOnItsOwnStrip && !input.floatingAddressVisible
        let dockRoom = dockShown ? max(0, input.metrics.dockHeight + input.metrics.dockLift + 8) : 0
        var reservedAreaBottom: CGFloat = 0, scrollRoomBottom: CGFloat = 0, overlayBottom: CGFloat = 0
        if dockRoom > 0 {
            if !input.pageHasFixedBottomBar {
                // An ordinary page runs under the floating dock and shows around it; it only needs the room to scroll its end clear of the dock.
                scrollRoomBottom = dockRoom
            } else if input.bottomChromeOverlays {
                // A page with its own bottom bar: from iOS 26 the page runs to the screen's edge under the dock and WebKit is told the covered strip (the dock's room
                // and the home strip below it), which keeps the page's bar above the dock with no dark strip behind it.
                overlayBottom = dockRoom + clean(input.safeBottom)
            } else {
                // Before iOS 26: the page area ends above the dock instead.
                reservedAreaBottom = dockRoom
            }
        }
        if input.bottomChromeOverlays {
            // The bar sheet's room becomes overlay room (the sheet and the dock are never both shown).
            overlayBottom += reservedPageBottom
            reservedPageBottom = 0
        }
        return PhoneViewportOutput(overlayTop: overlayTop, overlayBottom: overlayBottom, reservedPageBottom: reservedPageBottom, reservedAreaBottom: reservedAreaBottom,
                                   scrollRoomBottom: scrollRoomBottom)
    }

    /// What WebKit is told as the page's minimum and maximum viewport inset: the overlay room plus the web view's own safe area (the status bar or home strip the page
    /// runs under). The scroll view gets the overlay room alone, because the system already adds the safe area to scrolling. `webViewSafe*` are the web view's own
    /// `safeAreaInsets`, in its local coordinates.
    static func told(overlayTop: CGFloat, overlayBottom: CGFloat, webViewSafeTop: CGFloat, webViewSafeBottom: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        (clean(overlayTop) + clean(webViewSafeTop), clean(overlayBottom) + clean(webViewSafeBottom))
    }
}

#if DEBUG
/// One screen layout pass as the shadow sees it: the resolver's input and the screen's own answer for it.
struct ViewportShadowSample: Equatable {
    var input: PhoneViewportInput
    var legacy: PhoneViewportOutput
}

/// Stage 1 shadow mode, DEBUG builds only. Compares the resolver with the screen's own values and with what the writer tells WebKit, and counts how often geometry is
/// applied. It only reads and counts: it never applies insets, changes a frame or an offset, or loads anything. Counts and numbers only, in memory: no address and no
/// page content. `enabled = false` turns it off without touching the legacy path.
@MainActor
enum ViewportShadow {
    static var enabled = true
    private(set) static var samples = 0
    private(set) static var mismatches = 0
    private(set) static var lastMismatch: String?
    /// The latest screen sample (input and the screen's own answer), for hosted tests.
    private(set) static var lastSample: ViewportShadowSample?
    private(set) static var doubleCompensations = 0
    /// The writer: calls, calls that changed what WebKit was told, calls dropped as unchanged, and "told" values that differ from the resolver's.
    private(set) static var writerCalls = 0
    private(set) static var applied = 0
    private(set) static var unchanged = 0
    private(set) static var toldMismatches = 0
    /// Time spent in the resolver (nanoseconds, total), for the Stage 1 budget.
    private(set) static var resolveNanos: UInt64 = 0
    /// Stage 2: where named views really are (window coordinates) and the safe area each one sees, recorded by `viewportProbe`. Numbers only.
    private(set) static var probes: [String: (frame: CGRect, safe: EdgeInsets)] = [:]
    static func probe(_ name: String, _ geometry: GeometryProxy) {
        guard enabled else { return }
        probes[name] = (geometry.frame(in: .global), geometry.safeAreaInsets)
    }

    static func reset() {
        samples = 0; mismatches = 0; lastMismatch = nil; lastSample = nil; doubleCompensations = 0
        writerCalls = 0; applied = 0; unchanged = 0; toldMismatches = 0; resolveNanos = 0; probes = [:]
    }

    /// One screen layout pass: the screen's own values against the resolver's for the same input.
    static func compare(_ input: PhoneViewportInput, legacy: PhoneViewportOutput) {
        guard enabled else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        let proposed = PhoneViewportGeometry.resolve(input)
        resolveNanos &+= DispatchTime.now().uptimeNanoseconds &- start
        samples += 1
        lastSample = ViewportShadowSample(input: input, legacy: legacy)
        if proposed.compensatesBottomTwice || legacy.compensatesBottomTwice { doubleCompensations += 1 }
        guard !proposed.matches(legacy) else { return }
        mismatches += 1
        lastMismatch = "legacy \(legacy) proposed \(proposed) input \(input)"
        debugLog("VIEWPORT-SHADOW mismatch #\(mismatches): \(lastMismatch ?? "")")
    }

    /// One writer call: what the legacy code tells WebKit against the resolver's formula, and whether it changed anything.
    static func writer(overlayTop: CGFloat, overlayBottom: CGFloat, webViewSafeTop: CGFloat, webViewSafeBottom: CGFloat, told: (top: CGFloat, bottom: CGFloat), changed: Bool) {
        guard enabled else { return }
        writerCalls += 1
        if changed { applied += 1 } else { unchanged += 1 }
        let proposed = PhoneViewportGeometry.told(overlayTop: overlayTop, overlayBottom: overlayBottom, webViewSafeTop: webViewSafeTop, webViewSafeBottom: webViewSafeBottom)
        if abs(proposed.top - told.top) > 0.5 || abs(proposed.bottom - told.bottom) > 0.5 {
            toldMismatches += 1
            debugLog("VIEWPORT-SHADOW told mismatch: legacy \(told) proposed \(proposed)")
        }
    }
}

extension View {
    /// DEBUG only: records this view's frame in the window and the safe area it sees, under `name`, whenever it moves. Changes nothing on screen.
    func viewportProbe(_ name: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear
                .onAppear { ViewportShadow.probe(name, geometry) }
                .onChange(of: geometry.frame(in: .global)) { _, _ in ViewportShadow.probe(name, geometry) }
                .onChange(of: geometry.safeAreaInsets) { _, _ in ViewportShadow.probe(name, geometry) }
        })
    }
}
#endif
