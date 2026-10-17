import Foundation

/// What a keystroke in Vim mode asks the browser to do.
enum VimAction: String, CaseIterable, Codable, Identifiable {
    case scrollDown, scrollUp, scrollHalfDown, scrollHalfUp, scrollTop, scrollBottom
    case back, forward, reload
    case newTab, closeTab, reopenTab, nextTab, previousTab
    case openSwitcher, focusAddress, find, copyURL, bookmark, toggleSidebar
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scrollDown: "Scroll down"; case .scrollUp: "Scroll up"
        case .scrollHalfDown: "Half page down"; case .scrollHalfUp: "Half page up"
        case .scrollTop: "Top of page"; case .scrollBottom: "Bottom of page"
        case .back: "Back"; case .forward: "Forward"; case .reload: "Reload"
        case .newTab: "New tab"; case .closeTab: "Close tab"; case .reopenTab: "Reopen closed tab"
        case .nextTab: "Next tab"; case .previousTab: "Previous tab"
        case .openSwitcher: "Quick switcher"; case .focusAddress: "Address bar"; case .find: "Find on page"
        case .copyURL: "Copy page address"; case .bookmark: "Bookmark page"; case .toggleSidebar: "Show or hide sidebar"
        }
    }
}

/// Key sequences ("gg", "yy") mapped to actions. You can change any of them; the table is stored as plain text.
struct VimKeymap: Equatable, Codable {
    var bindings: [String: VimAction]

    static let standard = VimKeymap(bindings: [
        "j": .scrollDown, "k": .scrollUp, "d": .scrollHalfDown, "u": .scrollHalfUp, "gg": .scrollTop, "G": .scrollBottom,
        "H": .back, "L": .forward, "r": .reload,
        "t": .newTab, "x": .closeTab, "X": .reopenTab, "J": .nextTab, "K": .previousTab,
        "o": .openSwitcher, "O": .focusAddress, "/": .find, "yy": .copyURL, "m": .bookmark, "b": .toggleSidebar,
    ])

    /// Sequences that can never be bound: they would shadow another sequence or be shadowed by one.
    func conflicts(_ sequence: String) -> [String] {
        bindings.keys.filter { $0 != sequence && ($0.hasPrefix(sequence) || sequence.hasPrefix($0)) }.sorted()
    }

    /// Binds a sequence, refusing one that is empty, longer than three keys, or that clashes with another.
    @discardableResult
    mutating func bind(_ sequence: String, to action: VimAction) -> Bool {
        guard !sequence.isEmpty, sequence.count <= 3, !sequence.contains(" "), conflicts(sequence).isEmpty else { return false }
        bindings[sequence] = action
        return true
    }

    func sequence(for action: VimAction) -> String? { bindings.first { $0.value == action }?.key }

    func encoded() -> String {
        bindings.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.rawValue)" }.joined(separator: "\n")
    }

    static func decode(_ text: String) -> VimKeymap {
        var map = VimKeymap(bindings: [:])
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2, let action = VimAction(rawValue: String(parts[1])) { map.bind(String(parts[0]), to: action) }
        }
        return map.bindings.isEmpty ? .standard : map
    }
}

/// The part of Vim mode that decides: it takes keys one at a time and says what to do. It never touches the page.
struct VimMachine {
    var keymap: VimKeymap = .standard
    private(set) var pending = ""
    private(set) var count = ""

    enum Result: Equatable {
        case none
        case waiting
        case run(VimAction, times: Int)
    }

    mutating func reset() { pending = ""; count = "" }

    /// `key` is one typed character. Escape clears what is half typed.
    mutating func feed(_ key: String) -> Result {
        if key == "\u{1B}" { reset(); return .none }
        guard key.count == 1 else { return .none }
        if pending.isEmpty, key.first!.isNumber, !(key == "0" && count.isEmpty) {
            count += key
            return count.count > 3 ? { reset(); return .none }() : .waiting
        }
        pending += key
        if let action = keymap.bindings[pending] {
            let times = Int(count) ?? 1
            reset()
            return .run(action, times: max(1, min(times, 999)))
        }
        if keymap.bindings.keys.contains(where: { $0.hasPrefix(pending) }) { return .waiting }
        reset()
        return .none
    }
}
