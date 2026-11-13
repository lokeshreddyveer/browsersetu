import Foundation

/// The decisions the Mac tab chips make, as plain functions so they can be checked without a window: what a tab shows for closing and locking, which tab an arrow key moves to,
/// what a screen reader is told about a tab's state, and whether a delayed hover preview may still appear.
enum TabChipRules {
    /// A locked tab cannot be closed (BrowserModel.closeTab refuses it), so it shows a lock mark and no Close control. `hide_tab_close` is applied by TabCloseButton itself.
    static func showsCloseButton(locked: Bool, selected: Bool, hovering: Bool) -> Bool { !locked && (selected || hovering) }

    enum Direction { case previous, next, first, last }

    /// The tab that an arrow (or Home/End) key moves to, in the strip's order. No wrap-around, so the ends are clear; nil when there is nowhere to go.
    static func neighbor(of id: UInt64, in ids: [UInt64], _ direction: Direction) -> UInt64? {
        guard let index = ids.firstIndex(of: id) else { return nil }
        let target: Int
        switch direction {
        case .previous: target = index - 1
        case .next: target = index + 1
        case .first: target = 0
        case .last: target = ids.count - 1
        }
        guard ids.indices.contains(target), target != index else { return nil }
        return ids[target]
    }

    /// The state words a screen reader adds after a tab's title; nil when there are none.
    static func spokenState(locked: Bool, pinned: Bool, playing: Bool, muted: Bool, asleep: Bool = false, isPrivate: Bool = false) -> String? {
        var parts: [String] = []
        if isPrivate { parts.append("Private") }
        if pinned { parts.append("Pinned") }
        if locked { parts.append("Locked") }
        if muted { parts.append("Muted") } else if playing { parts.append("Playing sound") }
        if asleep { parts.append("Asleep, reloads when opened") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Whether a hover preview whose delay has run out may still be shown: the setting is on, the tab is still there and eligible, the pointer is still on it, the app is in front, no drag is under way, and nothing of higher priority (the command palette, the tab overview, a sheet) is open.
    static func previewMayAppear(settingOn: Bool, tabExists: Bool, isInternalPage: Bool, pointerInside: Bool, appActive: Bool, dragging: Bool, modalUIVisible: Bool = false) -> Bool {
        settingOn && tabExists && !isInternalPage && pointerInside && appActive && !dragging && !modalUIVisible
    }
}
