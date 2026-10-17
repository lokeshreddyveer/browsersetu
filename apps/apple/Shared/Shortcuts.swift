import SwiftUI

/// A key with modifiers, written "cmd+shift+t".
struct KeyCombo: Equatable, Hashable {
    var key: String               // one character, or a name: return, tab, space, delete, escape, up, down, left, right
    var command = false, shift = false, option = false, control = false

    static let names: [String: KeyEquivalent] = [
        "return": .return, "tab": .tab, "space": .space, "delete": .delete, "escape": .escape,
        "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
    ]

    var keyEquivalent: KeyEquivalent? {
        if let named = Self.names[key] { return named }
        guard key.count == 1, let ch = key.first else { return nil }
        return KeyEquivalent(ch)
    }

    var modifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// A shortcut must not be a bare letter: it would stop that letter being typed.
    var isUsable: Bool { keyEquivalent != nil && (command || control || option) }

    var stored: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("opt") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.lowercased(); self.command = command; self.shift = shift; self.option = option; self.control = control
    }

    init?(stored: String) {
        let parts = stored.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        var combo = KeyCombo(key: last)
        for part in parts.dropLast() {
            switch part {
            case "cmd": combo.command = true
            case "shift": combo.shift = true
            case "opt": combo.option = true
            case "ctrl": combo.control = true
            default: return nil
            }
        }
        guard combo.isUsable else { return nil }
        self = combo
    }

    /// "⇧⌘T"
    var display: String {
        let symbols: [String: String] = ["return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "⎋",
                                         "up": "↑", "down": "↓", "left": "←", "right": "→"]
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (symbols[key] ?? key.uppercased())
    }
}

/// Everything the menu bar can do that has a shortcut a person may change.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case newTab, newPrivateTab, openLocation, commandPalette, closeTab, reopenClosedTab
    case print, back, forward, reload, stop, nextTab, previousTab
    case pasteAndGo, find, findNext, findPrevious
    case bookmarkPage, showBookmarks, showHistory, showDownloads
    case toggleSidebar, tabOverview, searchTabs, focusMode, zoomIn, zoomOut, actualSize, sharePage, readerMode, findAllTabs, restoreLayout

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newPrivateTab: "New Private Tab"
        case .openLocation: "Open Location"
        case .commandPalette: "Command Palette"
        case .closeTab: "Close Tab"
        case .reopenClosedTab: "Reopen Closed Tab"
        case .print: "Print"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .stop: "Stop"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .pasteAndGo: "Paste and Go"
        case .find: "Find in Page"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .bookmarkPage: "Bookmark This Page"
        case .showBookmarks: "Show Bookmarks"
        case .showHistory: "Show History"
        case .showDownloads: "Show Downloads"
        case .toggleSidebar: "Toggle Sidebar"
        case .tabOverview: "Show Tab Overview"
        case .searchTabs: "Search Tabs"
        case .sharePage: "Share Page"
        case .readerMode: "Reader"
        case .findAllTabs: "Find in All Tabs"
        case .restoreLayout: "Restore Standard Layout"
        case .focusMode: "Focus Mode"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .actualSize: "Actual Size"
        }
    }

    var group: String {
        switch self {
        case .newTab, .newPrivateTab, .closeTab, .reopenClosedTab, .nextTab, .previousTab, .tabOverview, .searchTabs: "Tabs"
        case .openLocation, .commandPalette, .pasteAndGo, .find, .findNext, .findPrevious, .findAllTabs: "Address and Search"
        case .back, .forward, .reload, .stop: "Navigation"
        case .bookmarkPage, .showBookmarks, .showHistory, .showDownloads, .print, .sharePage, .readerMode: "Library"
        case .toggleSidebar, .focusMode, .zoomIn, .zoomOut, .actualSize, .restoreLayout: "View"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .newTab: KeyCombo(key: "t", command: true)
        case .newPrivateTab: KeyCombo(key: "n", command: true, shift: true)
        case .openLocation: KeyCombo(key: "l", command: true)
        case .commandPalette: KeyCombo(key: "k", command: true)
        case .closeTab: KeyCombo(key: "w", command: true)
        case .reopenClosedTab: KeyCombo(key: "t", command: true, shift: true)
        case .print: KeyCombo(key: "p", command: true)
        case .back: KeyCombo(key: "[", command: true)
        case .forward: KeyCombo(key: "]", command: true)
        case .reload: KeyCombo(key: "r", command: true)
        case .stop: KeyCombo(key: ".", command: true)
        case .nextTab: KeyCombo(key: "]", command: true, shift: true)
        case .previousTab: KeyCombo(key: "[", command: true, shift: true)
        case .pasteAndGo: KeyCombo(key: "v", command: true, shift: true)
        case .find: KeyCombo(key: "f", command: true)
        case .findNext: KeyCombo(key: "g", command: true)
        case .findPrevious: KeyCombo(key: "g", command: true, shift: true)
        case .bookmarkPage: KeyCombo(key: "d", command: true)
        case .showBookmarks: KeyCombo(key: "b", command: true, shift: true)
        case .showHistory: KeyCombo(key: "y", command: true)
        case .showDownloads: KeyCombo(key: "j", command: true, shift: true)
        case .toggleSidebar: KeyCombo(key: "l", command: true, shift: true)
        case .tabOverview: KeyCombo(key: "\\", command: true, shift: true)
        case .searchTabs: KeyCombo(key: "a", command: true, shift: true)
        case .sharePage: KeyCombo(key: "s", command: true, shift: true)
        case .readerMode: KeyCombo(key: "r", command: true, shift: true)
        case .findAllTabs: KeyCombo(key: "f", command: true, shift: true)
        case .focusMode: KeyCombo(key: "f", command: true, option: true)
        case .restoreLayout: KeyCombo(key: "0", command: true, shift: true, option: true)
        case .zoomIn: KeyCombo(key: "+", command: true)
        case .zoomOut: KeyCombo(key: "-", command: true)
        case .actualSize: KeyCombo(key: "0", command: true)
        }
    }
}

/// Shortcuts the user has changed, on top of the defaults. An entry of "none" turns a shortcut off.
struct ShortcutMap: Equatable {
    private(set) var overrides: [String: String] = [:]

    init(overrides: [String: String] = [:]) { self.overrides = overrides }

    init(json: String?) {
        guard let data = json?.data(using: .utf8), let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        overrides = dict.filter { ShortcutAction(rawValue: $0.key) != nil && ($0.value == "none" || KeyCombo(stored: $0.value) != nil) }
    }

    var json: String {
        (try? String(data: JSONEncoder().encode(overrides), encoding: .utf8)) ?? "{}"
    }

    func combo(for action: ShortcutAction) -> KeyCombo? {
        switch overrides[action.rawValue] {
        case "none": nil
        case let stored?: KeyCombo(stored: stored) ?? action.defaultCombo
        case nil: action.defaultCombo
        }
    }

    func isCustom(_ action: ShortcutAction) -> Bool { overrides[action.rawValue] != nil }

    /// The other action that already uses `combo`, if any.
    func conflict(for combo: KeyCombo, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0 != action && self.combo(for: $0) == combo }
    }

    /// Fixed shortcuts that the menus use and that cannot be changed.
    static func isReserved(_ combo: KeyCombo) -> Bool {
        if combo.command, !combo.shift, !combo.option, !combo.control, combo.key.count == 1, "123456789qhm,".contains(combo.key) { return true }
        return false
    }

    mutating func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if let combo {
            if combo == action.defaultCombo { overrides[action.rawValue] = nil } else { overrides[action.rawValue] = combo.stored }
        } else {
            overrides[action.rawValue] = "none"
        }
    }

    mutating func reset(_ action: ShortcutAction) { overrides[action.rawValue] = nil }
    mutating func resetAll() { overrides = [:] }
}

extension View {
    /// Applies the user's shortcut for `action`, or none if they turned it off.
    @ViewBuilder func shortcut(_ action: ShortcutAction, _ map: ShortcutMap) -> some View {
        if let combo = map.combo(for: action), let key = combo.keyEquivalent {
            keyboardShortcut(key, modifiers: combo.modifiers)
        } else {
            self
        }
    }
}
