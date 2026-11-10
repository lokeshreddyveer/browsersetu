import Foundation

/// Decides when the toolbar and tabs fold into a small pill while a page is read, and when they come back.
/// Pure: it only sees scroll movement. `delta` is positive when the page moves toward its top and negative when it
/// moves further down, the same sign the system gives a scroll event.
struct ScrollChrome: Equatable {
    /// How far the page must keep moving down before the toolbar folds away.
    static let collapseDistance: Double = 60
    /// Coming back takes less movement than leaving, so the toolbar is never hard to reach.
    static let expandDistance: Double = 24

    private(set) var collapsed = false
    private var travelled: Double = 0

    /// Feeds one scroll step. Returns true when the state changed.
    @discardableResult
    mutating func scrolled(by delta: Double) -> Bool {
        guard delta != 0 else { return false }
        // Changing direction starts the count again, so a wobble never counts as a deliberate scroll.
        if (delta < 0) != (travelled < 0) { travelled = 0 }
        travelled += delta
        if !collapsed, travelled <= -Self.collapseDistance {
            collapsed = true; travelled = 0
            return true
        }
        if collapsed, travelled >= Self.expandDistance {
            collapsed = false; travelled = 0
            return true
        }
        return false
    }

    /// Folds the toolbar at once (the Reading layout keeps it folded).
    mutating func collapse() {
        collapsed = true
        travelled = 0
    }

    /// Brings the toolbar back at once (a tab change, a click on the pill, the address bar taking focus).
    mutating func expand() {
        collapsed = false
        travelled = 0
    }
}

/// When the iPhone's folded controls may open again. Pure, so it can be tested away from the phone; `BrowserModel` asks it. `sticky` comes from the layout
/// (`PhoneLayoutSpec.sticky`): folds and stays folded, or always folded.
enum ChromeFoldPolicy {
    /// An automatic request to open the controls (a page finishing, a tab chosen from the list, the address bar taking focus) is ignored once they have folded, in a
    /// sticky layout. Only a person's own request opens them: a tap on a pill, Show Toolbar, a layout change.
    static func ignoresAutomaticExpand(isPhone: Bool, sticky: Bool) -> Bool { isPhone && sticky }

    /// Scrolling never opens controls that have folded, in a sticky layout (down or back up).
    static func ignoresScroll(isPhone: Bool, collapsed: Bool, sticky: Bool) -> Bool { isPhone && collapsed && sticky }
}
