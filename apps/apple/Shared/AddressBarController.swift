import SwiftUI

struct Suggestion: Identifiable, Equatable {
    enum Kind { case go, search, suggestion, bookmark, history, openTab, command, page }
    /// The same result keeps the same id from one keystroke to the next, so rows that stay are not redrawn and the list changes smoothly.
    var id: String { "\(kind)|\(target)|\(tabID ?? 0)" }
    let kind: Kind
    let title: String
    let subtitle: String
    /// What to load, or the tab id for `.openTab`.
    let target: String
    var tabID: UInt64?
    /// For a command: what to do when it is chosen.
    var action: (@MainActor () -> Void)?

    static func == (a: Suggestion, b: Suggestion) -> Bool { a.id == b.id && a.title == b.title && a.subtitle == b.subtitle }

    var symbol: String {
        switch kind {
        case .go: "arrow.right.circle"
        case .search, .suggestion: "magnifyingglass"
        case .command: "command"
        case .bookmark: "star.fill"
        case .history: "clock"
        case .page: "doc.text.magnifyingglass"
        case .openTab: "square.on.square"
        }
    }
}

/// Address bar text, focus and suggestions. The profile's own tabs, bookmarks and history are suggested locally. If the user has
/// allowed it, the search engine's own suggestions are added once the typing pauses (never in a private tab).
@MainActor
final class AddressBarController: ObservableObject {
    @Published var text = ""
    @Published var isEditing = false
    @Published private(set) var suggestions: [Suggestion] = []
    /// Highlighted suggestion for keyboard navigation (nil = none; Return then submits the typed text).
    @Published var selection: Int?

    private var local: [Suggestion] = []
    private var remote: [Suggestion] = []
    private var remoteTask: Task<Void, Never>?

    func refresh(model: BrowserModel) {
        remoteTask?.cancel()
        remote = []
        let query = text.trimmingCharacters(in: .whitespaces)
        // Opening the field fills it with the page's own address. That is not a search: nothing is suggested until the person types.
        let isCurrentAddress = query == model.active?.url?.absoluteString
        guard isEditing, !query.isEmpty, !isCurrentAddress else {
            local = []
            suggestions = []
            selection = nil
            return
        }
        var result: [Suggestion] = []
        if let hit = SearchShortcuts.resolve(query, custom: model.customSearchShortcuts) {
            // "g something", "yt something": the keyword picks the search engine for this one search.
            result.append(Suggestion(kind: .search, title: "Search for “\(hit.query)”", subtitle: "Search with \(hit.name)", target: hit.url))
        } else if let resolved = resolveInput(input: query, searchTemplate: model.searchTemplate) {
            switch resolved {
            case .url(let url): result.append(Suggestion(kind: .go, title: "Go to \(query)", subtitle: url, target: url))
            case .search(let url): result.append(Suggestion(kind: .search, title: "Search for “\(query)”", subtitle: "", target: url))
            }
        }
        for tab in model.tabs where !tab.isBlank && tab.id != model.activeID {
            let url = tab.url?.absoluteString ?? ""
            if tab.title.localizedCaseInsensitiveContains(query) || url.localizedCaseInsensitiveContains(query) {
                result.append(Suggestion(kind: .openTab, title: tab.displayTitle, subtitle: "Switch to tab", target: url, tabID: tab.id))
                if result.count >= 3 { break }
            }
        }
        var seen = Set<String>()
        for b in ((try? model.core.listBookmarks(query: query)) ?? []).prefix(3) {
            seen.insert(b.url)
            result.append(Suggestion(kind: .bookmark, title: b.title.isEmpty ? b.url : b.title, subtitle: b.url, target: b.url))
        }
        if !model.activeIsPrivate {
            for h in ((try? model.core.searchHistory(query: query, limit: 8)) ?? []) where !seen.contains(h.url) {
                result.append(Suggestion(kind: .history, title: h.title.isEmpty ? h.url : h.title, subtitle: h.url, target: h.url))
                if result.count >= 9 { break }
            }
        }
        // Words inside pages the person chose to keep a searchable copy of. At most three, after history, and never for private tabs.
        if model.indexPages, !model.activeIsPrivate, query.count >= 3, !query.hasPrefix(">") {
            for hit in (model.pageIndex?.search(query, limit: 3) ?? []) where !seen.contains(hit.url) {
                result.append(Suggestion(kind: .page, title: hit.title.isEmpty ? hit.url : hit.title, subtitle: "In your pages · " + hit.snippet, target: hit.url))
            }
        }
        // Commands: after ">" every command that matches; otherwise only the ones whose name contains what was typed.
        let isCommandQuery = query.hasPrefix(">")
        let commandText = (isCommandQuery ? String(query.dropFirst()) : query).trimmingCharacters(in: .whitespaces)
        if isCommandQuery || commandText.count >= 3 {
            let wanted = commandText.lowercased()
            let commands = model.paletteItems(query: commandText).filter { item in
                !item.id.hasPrefix("tab-") && !item.id.hasPrefix("bm-") && !item.title.contains("://") && (isCommandQuery || item.title.lowercased().contains(wanted))
            }
            if isCommandQuery { result.removeAll() }
            for item in commands.prefix(isCommandQuery ? 8 : 2) {
                result.append(Suggestion(kind: .command, title: item.title, subtitle: item.subtitle, target: item.id, action: item.run))
            }
        }
        local = result
        suggestions = result
        selection = nil
        startRemote(query: query, model: model)
    }

    /// The engine's suggestions go right after the first row ("Go to…" or "Search for…"), ahead of the local ones.
    private func merged() -> [Suggestion] {
        guard !remote.isEmpty else { return local }
        var out = local
        let first = out.first.map { $0.kind == .go || $0.kind == .search } ?? false
        out.insert(contentsOf: remote, at: first ? 1 : 0)
        return out
    }

    private func startRemote(query: String, model: BrowserModel) {
        // While a proxy is on, nothing typed is sent to a search engine: that request would not use the proxy.
        guard model.searchSuggestionsEnabled, !ProxyState.active, !model.activeIsPrivate, SearchSuggestions.shouldAsk(for: query),
              let endpoint = SearchSuggestions.endpoint(forSearchTemplate: model.searchTemplate) else { return }
        let template = model.searchTemplate
        remoteTask = Task { [weak self] in
            // Wait for a pause in the typing, so a fast typist sends one request, not one per letter.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let words = await SearchSuggestions.fetch(endpoint: endpoint, query: query)
            guard !Task.isCancelled, let self, self.isEditing,
                  self.text.trimmingCharacters(in: .whitespaces) == query else { return }
            self.applyRemote(words, query: query, searchTemplate: template)
        }
    }

    /// Adds the engine's suggestions. Not while the user is choosing with the arrow keys: the list must not shift under them.
    func applyRemote(_ words: [String], query: String, searchTemplate: String) {
        remote = words.filter { $0.caseInsensitiveCompare(query) != .orderedSame }.prefix(5).compactMap { word in
            guard let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))) else { return nil }
            return Suggestion(kind: .suggestion, title: word, subtitle: "", target: searchTemplate.replacingOccurrences(of: "{}", with: encoded))
        }
        if selection == nil { suggestions = merged() }
    }

    func moveSelection(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (selection ?? (delta > 0 ? -1 : suggestions.count)) + delta
        selection = min(max(next, 0), suggestions.count - 1)
    }

    func clear() {
        remoteTask?.cancel()
        local = []; remote = []
        suggestions = []
        selection = nil
    }

    var selectedSuggestion: Suggestion? { selection.flatMap { suggestions.indices.contains($0) ? suggestions[$0] : nil } }
}

/// Dropdown shown under the address bar while typing: one glass panel, a tile for every result, the words you typed
/// picked out in bold, and the keys that work.
struct SuggestionsList: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var address: AddressBarController
    /// Drawn inside another panel (the search panel), so it brings no card, border or shadow of its own.
    var embedded = false
    /// The highlight is one shape that slides from row to row, rather than a fill that switches off and on.
    @Namespace private var highlight

    private var tokens: [String] { address.text.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var engineName: String { SearchEngines.preset(for: model.searchTemplate)?.name ?? "your search engine" }

    /// The iPhone's list is plain: no section headings and a handful of single-line rows.
    private var minimal: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    private var rows: [(offset: Int, element: Suggestion)] {
        Array(address.suggestions.prefix(minimal ? 8 : 9).enumerated())
    }

    private func header(for kind: Suggestion.Kind) -> String? {
        if minimal { return nil }
        switch kind {
        case .go, .search, .suggestion, .command: return nil
        case .openTab: return "Open Tabs"
        case .bookmark: return "Bookmarks"
        case .history: return "History"
        case .page: return "In Your Pages"
        }
    }

    var body: some View {
        if !address.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows, id: \.element.id) { index, s in
                    if let title = header(for: s.kind), index == 0 || header(for: address.suggestions[index - 1].kind) != title {
                        Text(title).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary).textCase(.uppercase)
                            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 2)
                            .transition(.opacity)
                    }
                    Button { model.accept(s) } label: {
                        SuggestionRow(suggestion: s, selected: address.selection == index, tokens: tokens, engineName: engineName)
                            .background {
                                if address.selection == index {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.accent.opacity(0.92))
                                        .matchedGeometryEffect(id: "highlight", in: highlight)
                                        .padding(.horizontal, 6)
                                }
                            }
                    }
                    .buttonStyle(SuggestionPressStyle())
                    .accessibilityLabel(s.title)
                    .transition(.opacity)
                }
                #if os(macOS)
                KeyHints()
                #endif
            }
            .padding(.vertical, 6)
            // Arrow keys glide the highlight; results arriving fade in rather than jump, and the card eases to its new height.
            .motion(.spring(response: 0.28, dampingFraction: 0.9), value: address.selection)
            .motion(.easeInOut(duration: 0.2), value: address.suggestions.map(\.id))
            .modifier(SuggestionsCard(embedded: embedded))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("suggestions")
        }
    }
}

/// The card around the list: glass, rounded, with a border and a soft shadow. Inside the search panel the panel is the card.
private struct SuggestionsCard: ViewModifier {
    let embedded: Bool

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .environment(\.colorScheme, .dark)
                .background(Obsidian.fill.opacity(0.96))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Obsidian.edge, lineWidth: 0.6))
                .shadow(color: .black.opacity(0.32), radius: 40, y: 22)
                .transition(.opacity)
        }
    }
}

/// A row gives a little under the finger or pointer when pressed.
private struct SuggestionPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
    let selected: Bool
    let tokens: [String]
    let engineName: String

    @State private var hovering = false
    /// Rows for things you already have are slim; the "open this address" and "search" rows stay roomy.
    private var compact: Bool {
        #if os(iOS)
        true
        #else
        switch suggestion.kind { case .go, .search: false; default: true }
        #endif
    }
    /// The iPhone's rows are one plain line: no "Open this address" or site underneath.
    private var showsSubtitle: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }
    private var tileSize: CGFloat { 22 }
    private var primary: Color { selected ? .white : .primary }
    private var secondary: Color { selected ? .white.opacity(0.78) : .secondary }

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            tile
            if compact {
                // History, bookmarks, tabs and engine suggestions: the title and the site on one line.
                HStack(spacing: 8) {
                    titleText.lineLimit(1)
                    if showsSubtitle, let line = subtitle { Text(line).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1).layoutPriority(-1) }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    titleText.lineLimit(1)
                    if let line = subtitle { Text(line).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1) }
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, compact ? 4 : 6)
        .frame(minHeight: compact ? 34 : 42)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering && !selected ? Color.primary.opacity(0.07) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .motion(.easeOut(duration: 0.12), value: hovering)
        .motion(.easeOut(duration: 0.14), value: selected)
        #if os(macOS)
        .onHover { hovering = $0 }
        #endif
    }

    // MARK: Pieces

    @ViewBuilder private var tile: some View {
        switch suggestion.kind {
        case .go: symbolTile("arrow.right", fill: AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.7)], startPoint: .top, endPoint: .bottom)), color: .white)
        case .search, .suggestion: symbolTile("magnifyingglass", fill: AnyShapeStyle(Color.primary.opacity(selected ? 0.25 : 0.1)), color: selected ? .white : .primary)
        case .command: symbolTile("command", fill: AnyShapeStyle(Color.purple.opacity(0.85)), color: .white)
        case .openTab: symbolTile("macwindow", fill: AnyShapeStyle(Color.teal.opacity(0.9)), color: .white)
        case .bookmark, .history, .page: SiteTile(url: suggestion.target, title: suggestion.title, size: tileSize)
        }
    }

    private func symbolTile(_ name: String, fill: AnyShapeStyle, color: Color) -> some View {
        Image(systemName: name).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .frame(width: tileSize, height: tileSize)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder private var titleText: some View {
        switch suggestion.kind {
        case .go:
            // The host stands out; the rest of a long address is quieter.
            let parts = Self.split(suggestion.target)
            (Text(parts.host).font(.system(size: 14, weight: .semibold)).foregroundColor(primary)
             + Text(parts.rest).font(.system(size: 14)).foregroundColor(secondary))
        case .search:
            Text("Search ").font(.system(size: 14)).foregroundColor(secondary)
                + Text("“\(Self.query(from: suggestion.title))”").font(.system(size: 14, weight: .semibold)).foregroundColor(primary)
        default:
            Text(Self.highlight(suggestion.title, tokens: tokens)).font(.system(size: 14)).foregroundStyle(primary)
        }
    }

    private var subtitle: String? {
        switch suggestion.kind {
        case .go: "Open this address"
        case .search: suggestion.subtitle.isEmpty ? "Search with \(engineName)" : suggestion.subtitle
        case .suggestion: nil
        case .command: "Command"
        case .openTab: "Switch to this tab"
        case .bookmark, .history: displayHost(URL(string: suggestion.target))
        case .page: suggestion.subtitle
        }
    }

    @ViewBuilder private var trailing: some View {
        switch suggestion.kind {
        case .openTab:
            Text("Switch").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(selected ? Color.white.opacity(0.25) : Color.teal.opacity(0.2)))
                .foregroundStyle(selected ? .white : Color.teal)
        case .bookmark:
            Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(selected ? .white : .yellow)
        case .history:
            #if os(macOS)
            Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(secondary)
            #else
            EmptyView()
            #endif
        default:
            if selected { Text("↩").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)) }
        }
    }

    // MARK: Text helpers

    /// The words typed, in bold wherever they appear.
    static func highlight(_ text: String, tokens: [String]) -> AttributedString {
        var result = AttributedString(text)
        for token in tokens where !token.isEmpty {
            var from = result.startIndex
            while from < result.endIndex, let found = result[from...].range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) {
                result[found].inlinePresentationIntent = .stronglyEmphasized
                from = found.upperBound
            }
        }
        return result
    }

    /// The host of an address and everything after it, so a long link reads as "youtube.com" then the rest.
    static func split(_ address: String) -> (host: String, rest: String) {
        guard let url = URL(string: address), let host = url.host else { return (address, "") }
        let shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        var rest = url.path == "/" ? "" : url.path
        if let query = url.query { rest += "?" + query }
        return (shown, rest)
    }

    /// The typed words out of the model's "Search for “…”" title.
    static func query(from title: String) -> String {
        guard let open = title.firstIndex(of: "“"), let close = title.lastIndex(of: "”"), open < close else { return title }
        return String(title[title.index(after: open)..<close])
    }
}

#if os(macOS)
/// The keys that work in the list, in small keycaps.
private struct KeyHints: View {
    var body: some View {
        HStack(spacing: 14) {
            hint("↑↓", "to choose")
            hint("↩", "to open")
            hint("esc", "to close")
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 4)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).padding(.horizontal, 12) }
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.1)))
            Text(text).font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }
}
#endif

/// Observes the address bar directly so the dropdown redraws as suggestions change
/// (the model only holds the controller, it does not republish its changes).
struct SuggestionsOverlay: View {
    @ObservedObject var address: AddressBarController
    /// Inside the search panel: a divider above, and no card of its own.
    var embedded = false
    var body: some View {
        Group {
            if address.isEditing && !address.suggestions.isEmpty {
                if embedded {
                    VStack(spacing: 0) {
                        Divider().opacity(0.5).padding(.horizontal, 14)
                        SuggestionsList(address: address, embedded: true)
                    }
                } else {
                    SuggestionsList(address: address)
                }
            }
        }
        .motion(.spring(response: 0.3, dampingFraction: 0.86), value: address.isEditing && !address.suggestions.isEmpty)
    }
}
