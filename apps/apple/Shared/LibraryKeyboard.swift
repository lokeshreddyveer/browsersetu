import SwiftUI

/// Keyboard navigation for the Library's lists (Bookmarks, History): the list takes keyboard focus like any other control (Tab / Shift-Tab reach it from Search and the section picker),
/// then ↑ ↓ move between the visible rows, ← → fold and unfold a folder (← on a bookmark goes to its folder), Return opens, Delete removes through the row's own action and Escape clears the
/// marked row. Typing in Search or a rename field never reaches here, because those fields hold the focus then.
struct LibraryKeyboard: ViewModifier {
    @Binding var marked: String?
    /// The visible rows, top to bottom. A row id begins with its kind: "f:" a folder, anything else a leaf.
    let ids: [String]
    var parent: (String) -> String? = { _ in nil }
    let activate: (String) -> Void
    let remove: (String) -> Void
    var fold: (String, Bool) -> Void = { _, _ in }
    var isFolded: (String) -> Bool = { _ in false }
    /// Counts the times ↓ was pressed in the Library's search field: each one moves the keyboard into the list and marks its first row.
    var entry = 0
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onChange(of: focused) { _, now in if now && marked == nil { marked = ids.first } }
                .onChange(of: marked) { _, id in if let id { proxy.scrollTo(id) } }
                .onChange(of: entry) { _, _ in focused = true; if marked == nil || !ids.contains(marked ?? "") { marked = ids.first } }
                .onKeyPress(phases: [.down, .repeat]) { press in handle(press.key) }
        }
    }

    private func handle(_ key: KeyEquivalent) -> KeyPress.Result {
        let index = marked.flatMap { ids.firstIndex(of: $0) }
        switch key {
        case .downArrow:
            guard !ids.isEmpty else { return .ignored }
            marked = index.map { ids[min($0 + 1, ids.count - 1)] } ?? ids.first
            return .handled
        case .upArrow:
            guard !ids.isEmpty else { return .ignored }
            marked = index.map { ids[max($0 - 1, 0)] } ?? ids.last
            return .handled
        case .rightArrow:
            guard let id = marked, id.hasPrefix("f:") else { return .ignored }
            if isFolded(id) { fold(id, false) } else if let i = index, i + 1 < ids.count, !ids[i + 1].hasPrefix("f:") { marked = ids[i + 1] }
            return .handled
        case .leftArrow:
            guard let id = marked else { return .ignored }
            if id.hasPrefix("f:") { if !isFolded(id) { fold(id, true) } } else if let p = parent(id) { marked = p }
            return .handled
        case .return:
            guard let id = marked else { return .ignored }
            activate(id)
            return .handled
        case .escape:
            guard marked != nil else { return .ignored }
            marked = nil
            return .handled
        default:
            // Delete is matched by its character: the Backspace key arrives as U+007F, which KeyEquivalent.delete does not equal.
            guard Self.deleteKeys.contains(key.character) else { return .ignored }
            guard let id = marked else { return .ignored }
            // The next row takes the mark so the list can be cleared with the key held down.
            if let i = index { let rest = ids.filter { $0 != id }; marked = rest.isEmpty ? nil : rest[min(i, rest.count - 1)] }
            remove(id)
            return .handled
        }
    }

    private static let deleteKeys: Set<Character> = ["\u{7F}", "\u{8}", "\u{F728}"]
}

extension View {
    func libraryKeyboard(marked: Binding<String?>, ids: [String], parent: @escaping (String) -> String? = { _ in nil }, activate: @escaping (String) -> Void,
                         remove: @escaping (String) -> Void, fold: @escaping (String, Bool) -> Void = { _, _ in }, isFolded: @escaping (String) -> Bool = { _ in false }, entry: Int = 0) -> some View {
        modifier(LibraryKeyboard(marked: marked, ids: ids, parent: parent, activate: activate, remove: remove, fold: fold, isFolded: isFolded, entry: entry))
    }
}
