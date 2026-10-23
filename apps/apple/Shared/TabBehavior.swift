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
    static func selectionAfterClosing(_ closing: UInt64, in order: [Entry], returnTo: UInt64?) -> UInt64? {
        let rest = order.filter { $0.id != closing }
        guard !rest.isEmpty else { return nil }
        if let returnTo, rest.contains(where: { $0.id == returnTo }) { return returnTo }
        guard let position = order.firstIndex(where: { $0.id == closing }) else { return rest.first?.id }
        return rest[min(position, rest.count - 1)].id
    }
}
