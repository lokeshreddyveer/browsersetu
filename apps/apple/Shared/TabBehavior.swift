import Foundation

/// Where a new tab goes and which tab comes forward when one closes. These follow what Chromium and Firefox do (and Safari, as far as it documents it), so the
/// strip behaves the way a person who uses any other browser expects. Pure functions on a list, so every rule can be tested.
///
/// Reference: Chromium's `TabStripModelOrderController` (`DetermineInsertionIndex`, `DetermineNewSelectedIndex`) and Firefox's
/// `browser.tabs.insertRelatedAfterCurrent` and `browser.tabs.selectOwnerOnClose`.
enum TabBehavior {
    struct Entry: Equatable {
        var id: UInt64
        /// The tab this one was opened from, if it was opened from a page.
        var opener: UInt64?
        var pinned: Bool
    }

    /// The place in `order` (the strip as the person sees it, without the new tab) for a new tab.
    ///
    /// * Opened from a page (a link, a script): next to the tab that opened it. In front, straight after it; in the background, after the tabs it has already
    ///   opened, so several tabs opened in a row stay in the order they were opened in.
    /// * Opened by itself (New Tab, a typed address, a link from another app): at the end of the strip.
    /// * Never among the pinned tabs, which always come first.
    @inline(never)
    static func insertionIndex(in order: [Entry], opener: UInt64?, foreground: Bool) -> Int {
        let firstUnpinned = order.firstIndex(where: { !$0.pinned }) ?? order.count
        guard let opener, let at = order.firstIndex(where: { $0.id == opener }) else { return order.count }
        var index = at + 1
        if !foreground, let lastSibling = order.indices.last(where: { $0 > at && order[$0].opener == opener }) { index = lastSibling + 1 }
        return max(index, firstUnpinned)
    }

    /// The tab to bring forward when the selected tab `closing` closes.
    ///
    /// * If it was opened from a tab and you have not looked at any other tab since, back to that tab (Firefox "select owner on close", Chromium's opener rule).
    /// * Otherwise the tab that slides into its place, which is the one on its right; if it was the last, the one on its left.
    /// Nil when it was the only tab.
    @inline(never)
    static func selectionAfterClosing(_ closing: UInt64, in order: [Entry], returnTo: UInt64?) -> UInt64? {
        let rest = order.filter { $0.id != closing }
        guard !rest.isEmpty else { return nil }
        if let returnTo, rest.contains(where: { $0.id == returnTo }) { return returnTo }
        guard let position = order.firstIndex(where: { $0.id == closing }) else { return rest.first?.id }
        return rest[min(position, rest.count - 1)].id
    }
}


/// Which tab was in front when, most recent first, and the walk down that list that Control-Tab makes. A walk is a run of presses close together: it steps through the order as
/// it was when the run began (so tabs passed on the way do not reshuffle it), and only when the run ends does the tab it stopped on become the most recent.
struct TabRecency {
    private(set) var order: [UInt64] = []
    private var walk: (base: [UInt64], index: Int, at: Date)?
    /// How long after one press the next still counts as the same walk.
    static let walkWindow: TimeInterval = 1.5

    var isWalking: Bool { walk != nil }

    /// A tab came to the front by any other means: it is now the most recent, and a walk in progress is over.
    mutating func noteSelected(_ id: UInt64) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        walk = nil
    }

    mutating func forget(_ id: UInt64) { order.removeAll { $0 == id } }

    /// The tab one step further back (`direction` 1) or forward again (-1) in the walk, among `available` (the tabs that may be chosen right now, in the order they are listed: the
    /// ones the current window and privacy context show). Tabs never seen in front come after the ones that were. Nil when there is nowhere to go.
    mutating func step(_ direction: Int, current: UInt64?, available: [UInt64], now: Date = Date()) -> UInt64? {
        let usable = Set(available)
        var base: [UInt64]
        var index: Int
        if let walk, now.timeIntervalSince(walk.at) < Self.walkWindow {
            base = walk.base.filter { usable.contains($0) }
            index = min(walk.index, max(0, base.count - 1))
        } else {
            let seen = order.filter { usable.contains($0) }
            base = seen + available.filter { !seen.contains($0) }
            if let current, usable.contains(current) {
                base.removeAll { $0 == current }; base.insert(current, at: 0)
                index = 0
            } else {
                // In front is a page that is in no list (an Essential's): the first press goes to the most recent listed tab, Shift to the oldest.
                index = direction > 0 ? -1 : 0
            }
        }
        guard base.count > 1 else { walk = nil; return nil }
        index = ((index + direction) % base.count + base.count) % base.count
        walk = (base, index, now)
        return base[index]
    }

    /// The walk is over (no press for a while): the tab it stopped on becomes the most recent.
    mutating func endWalk(on id: UInt64?) {
        if let id { noteSelected(id) } else { walk = nil }
    }
}
