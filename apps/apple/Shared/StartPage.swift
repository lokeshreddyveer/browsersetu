import SwiftUI

private struct StartBottomInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// Room the page leaves at its foot for a toolbar that floats over it (the iPhone's dock).
    var startBottomInset: CGFloat {
        get { self[StartBottomInsetKey.self] }
        set { self[StartBottomInsetKey.self] = newValue }
    }
}

/// The page a blank tab shows. Quiet and fast: a small greeting, one large search field, your favorites, one card to carry on where you were,
/// compact chips for places you go often, and a single honest line about protection at the bottom. It is plain SwiftUI over the browser's own
/// data (bookmarks, history, tabs); there is no web view behind it, and nothing on it is fetched from the network except site icons you allow.
struct StartPageView: View {
    @EnvironmentObject var model: BrowserModel
    let isPrivate: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.startBottomInset) private var bottomInset
    @State private var addingFavorite = false
    @State private var newURL = ""
    @State private var newName = ""

    private var accent: Color { isPrivate ? Theme.privateAccent : Theme.accent }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(spacing: 34) {
                        VStack(spacing: 22) {
                            greeting
                            heroSearch
                        }
                        if isPrivate {
                            privateNote
                        } else {
                            if model.showFavorites { FavoritesGrid(addingFavorite: $addingFavorite) }
                            if model.showContinue, let tab = model.continueTab { ContinueCard(tab: tab) }
                            if model.showFrequent || model.showRecentlyClosed { HistoryChips() }
                            if !model.inbox.isEmpty { SentToThisDevice() }
                            if !model.remoteTabs.isEmpty { OtherDeviceTabs() }
                        }
                    }
                    Spacer(minLength: 24)
                    if !isPrivate {
                        HStack(spacing: 14) {
                            PrivacyLine()
                            CustomizeMenu()
                        }
                        .padding(.top, 18)
                        .padding(.bottom, bottomInset)
                    }
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 24).padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            // One screen when it fits; it scrolls (and never clips) on a small phone, in landscape, or with large text.
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(background)
        .alert("Add Favorite", isPresented: $addingFavorite) {
            TextField("Website address", text: $newURL)
            TextField("Name (optional)", text: $newName)
            Button("Add") { model.addFavorite(address: newURL, name: newName); newURL = ""; newName = "" }
            Button("Cancel", role: .cancel) { newURL = ""; newName = "" }
        }
        .overlay { if model.startDrawerOpen, !isPrivate { StartDrawer() } }
        .accessibilityIdentifier("start-page")
    }

    // MARK: Pieces

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let word = switch hour { case 5..<12: "Good morning"; case 12..<17: "Good afternoon"; case 17..<22: "Good evening"; default: "Good night" }
        return Text(isPrivate ? "Private Browsing" : (model.showGreeting ? word : "Browser Setu"))
            .font(.system(size: 22, weight: .medium)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// On the Mac this is a real text field of its own: clicking it keeps focus and typing in the page, with suggestions right under it. The
    /// top address bar is a separate field with its own focus; both use the same search, suggestion and navigation code. On the iPhone a tap
    /// opens the search panel, which is the same thing there.
    @ViewBuilder private var heroSearch: some View {
        #if os(macOS)
        StartSearchField()
        #else
        Button { model.openSearchPanel() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
                Text("Search or enter address").font(.system(size: 16)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18).frame(height: 54)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(scheme == .dark ? Color(red: 0.110, green: 0.133, blue: 0.188) : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search or enter address")
        .accessibilityIdentifier("start-search")
        // While a search is being typed, the one real field is the only field.
        .opacity(model.floatingAddressVisible ? 0 : 1)
        .motion(.easeOut(duration: 0.18), value: model.floatingAddressVisible)
        #endif
    }

    private var privateNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Nothing here is saved", systemImage: "eye.slash").font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
            Text("This tab keeps no history, cookies or session data once closed.")
            Text("Private browsing does not hide your activity from websites, your network or your employer.").foregroundStyle(.secondary)
        }
        .scaledFont(14)
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.10)))
    }

    /// Midnight charcoal with a barely perceptible blue tint in the middle.
    private var background: some View {
        Group {
            if isPrivate { Color.platformBackground }
            else if model.themeIsActive { ThemeBackdrop(theme: model.activeTheme, photo: model.themePhoto, photoDim: model.customTheme.photoDim) }
            else if scheme == .dark {
                ZStack {
                    Color(red: 0.047, green: 0.059, blue: 0.090)                       // #0C0F17
                    RadialGradient(colors: [Color(red: 0.067, green: 0.106, blue: 0.188).opacity(0.85), .clear],   // #111B30
                                   center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: 520)
                }
            } else {
                LinearGradient(colors: [accent.opacity(0.05), Color.platformBackground], startPoint: .top, endPoint: .center).background(Color.platformBackground)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared pieces

/// A small heading over a section, centered, quiet.
private struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title).scaledFont(11, weight: .semibold).tracking(0.8).foregroundStyle(.secondary).textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Chips that wrap onto further lines and stay centered, so a long title never runs off the edge.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]], x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
            rows[rows.count - 1].append(index)
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let rows = rows(subviews, width: width)
        let height = rows.map { row in row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let sizes = row.map { subviews[$0].sizeThatFits(.unspecified) }
            let rowWidth = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(row.count - 1, 0))
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            for (offset, index) in row.enumerated() {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sizes[offset]))
                x += sizes[offset].width + spacing
            }
            y += (sizes.map(\.height).max() ?? 0) + spacing
        }
    }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var addingFavorite: Bool

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 14, alignment: .top)]
    private var tileSize: CGFloat { model.startTile.points }

    var body: some View {
        let items = Array(model.orderedFavorites.prefix(8))
        VStack(spacing: 14) {
            SectionHeading(title: "Favorites")
            if items.isEmpty {
                emptyCard.transition(.opacity)
            } else {
                // Up to eight in one centered row; more than fit across wrap into a tidy grid.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) { tiles(items) }.frame(maxWidth: .infinity)
                    LazyVGrid(columns: columns, spacing: 16) { tiles(items) }
                }
            }
        }
    }

    @ViewBuilder private func tiles(_ items: [BookmarkItem]) -> some View {
        ForEach(items, id: \.url) { favorite in tile(favorite) }
        if items.count < 8 { addTile }
    }

    private func tile(_ favorite: BookmarkItem) -> some View {
        Button { model.open(urlString: favorite.url) } label: {
            VStack(spacing: 7) {
                SiteTile(url: favorite.url, title: favorite.title, size: tileSize)
                Text(favorite.title.isEmpty ? displayHost(URL(string: favorite.url)) : favorite.title)
                    .scaledFont(12).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary.opacity(0.85)).frame(width: 76)
            }
            .frame(width: 76)
            .keyboardFocusRing(radius: 14)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .draggable(favorite.url) { SiteTile(url: favorite.url, title: favorite.title, size: tileSize) }
        .dropDestination(for: String.self) { dropped, _ in
            guard let url = dropped.first else { return false }
            model.moveFavorite(url, before: favorite.url)
            return true
        }
        .contextMenu {
            Button("Open in New Tab") { model.open(urlString: favorite.url, newTab: true) }
            Button("Remove from Favorites", role: .destructive) { model.removeFavorite(favorite.url) }
        }
        .accessibilityLabel(favorite.title.isEmpty ? displayHost(URL(string: favorite.url)) : favorite.title)
        .accessibilityAction(named: "Move earlier") { model.nudgeFavorite(favorite.url, by: -1) }
        .accessibilityAction(named: "Move later") { model.nudgeFavorite(favorite.url, by: 1) }
    }

    /// Never filled in for you: suggestions are only offered here, and nothing is added until you choose it.
    private var addTile: some View {
        addMenu {
            VStack(spacing: 7) {
                Image(systemName: "plus").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: tileSize, height: tileSize)
                    .background(RoundedRectangle(cornerRadius: tileSize * 0.26, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Text("Add").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 76)
            }
            .frame(width: 76)
            .keyboardFocusRing(radius: 14)
        }
    }

    /// With no favorites yet, one clear dashed box says what this row is for and how to fill it.
    private var emptyCard: some View {
        addMenu {
            HStack(spacing: 12) {
                Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pin your favorite sites here").scaledFont(13, weight: .medium).foregroundStyle(.primary.opacity(0.85))
                    Text("One tap away from every new tab. Nothing is added unless you choose it.").scaledFont(12).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
            .keyboardFocusRing(radius: 14)
        }
        .accessibilityLabel("Add a favorite site")
    }

    private func addMenu<Label: View>(@ViewBuilder label: () -> Label) -> some View {
        Menu {
            if let tab = model.continueTab ?? model.active, let url = tab.url?.absoluteString, !tab.isBlank, !model.isFavorite(url) {
                Button("Add “\(tab.displayTitle)”") { model.toggleFavorite(url: url, title: tab.displayTitle) }
            }
            Button("Add a Website…") { addingFavorite = true }
            let suggestions = FavoriteSuggestions.all.filter { !model.isFavorite($0.url) }
            if !suggestions.isEmpty {
                Menu("Suggestions") { ForEach(suggestions, id: \.url) { s in Button(s.title) { model.toggleFavorite(url: s.url, title: s.title) } } }
            }
        } label: {
            label()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusEffectDisabled()
        .accessibilityLabel("Add a favorite")
        .accessibilityIdentifier("add-favorite")
    }
}

enum FavoriteSuggestions {
    static let all: [(title: String, url: String)] = [
        ("Wikipedia", "https://www.wikipedia.org/"), ("YouTube", "https://www.youtube.com/"), ("GitHub", "https://github.com/"),
        ("Apple", "https://www.apple.com/"), ("Maps", "https://maps.apple.com/"), ("BBC News", "https://www.bbc.com/news"),
        ("Hacker News", "https://news.ycombinator.com/"), ("Archive", "https://archive.org/"),
    ]
}

// MARK: - Continue

private struct ContinueCard: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        VStack(spacing: 12) {
            SectionHeading(title: "Continue browsing")
            Button { model.select(tab.id) } label: {
                HStack(spacing: 12) {
                    SiteTile(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tab.displayTitle).scaledFont(14, weight: .medium).lineLimit(1)
                        Text("\(displayHost(tab.url)) · \(RelativeDateTimeFormatter().localizedString(for: tab.lastActive, relativeTo: Date()))")
                            .scaledFont(12).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
                .keyboardFocusRing(radius: 14)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .accessibilityLabel("Continue browsing: \(tab.displayTitle), \(displayHost(tab.url))")
            .accessibilityIdentifier("continue-card")
        }
    }
}

// MARK: - Chips

private struct Chip: View {
    let title: String
    let url: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary) }
                else { SiteTile(url: url, title: title, size: 16) }
                Text(title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail).frame(maxWidth: 170)
            }
            .padding(.horizontal, 11).frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .contentShape(Capsule())
            .keyboardFocusRing(radius: 15)
        }
        .buttonStyle(.plain).focusEffectDisabled()
    }
}

/// Places you go often, and tabs you just closed: a few chips each, no repeats, and nothing that is already a favorite or the continue card.
private struct HistoryChips: View {
    @EnvironmentObject var model: BrowserModel
    @State private var often: [OftenSite] = []
    @State private var showAllOften = false

    struct OftenSite: Identifiable { let id: String; let title: String; let url: String; let isLocal: Bool }

    private func isLocal(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }

    /// One chip per page (no repeats), local development addresses folded into a single "Local" chip, readable titles.
    private func load() {
        guard model.showFrequent else { often = []; return }
        let favorites = Set(model.favorites.map(\.url))
        var seen = Set<String>(), titles = Set<String>(), result: [OftenSite] = [], localCount = 0, firstLocal: OftenSite?
        for site in model.frequentSites(limit: 24) where !favorites.contains(site.url) {
            let url = URL(string: site.url)
            let key = (url?.host ?? "") + (url?.path ?? "")
            guard seen.insert(key).inserted else { continue }
            let title = site.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let readable = title.isEmpty || title == site.url ? displayHost(url) : title
            if isLocal(url?.host) {
                localCount += 1
                if firstLocal == nil { firstLocal = OftenSite(id: "local", title: "", url: site.url, isLocal: true) }
            } else if titles.insert(readable.lowercased()).inserted {      // two pages with the same title are one chip
                result.append(OftenSite(id: site.url, title: readable, url: site.url, isLocal: false))
            }
        }
        if let firstLocal { result.append(OftenSite(id: "local", title: localCount == 1 ? "Local page" : "Local pages (\(localCount))", url: firstLocal.url, isLocal: true)) }
        often = result
    }

    var body: some View {
        #if os(iOS)
        let limit = 4
        #else
        let limit = 6
        #endif
        let shown = showAllOften ? often : Array(often.prefix(limit))
        let continueURL = model.continueTab?.url?.absoluteString
        let closed = model.showRecentlyClosed
            ? Array(model.closedTabs.enumerated().reversed().filter { $0.element.url.absoluteString != continueURL }.prefix(3))
            : []
        VStack(spacing: 30) {
            if !shown.isEmpty {
                VStack(spacing: 12) {
                    SectionHeading(title: "Often visited")
                    WrapLayout {
                        ForEach(shown) { site in
                            Chip(title: site.title, url: site.url, symbol: site.isLocal ? "laptopcomputer" : nil) { model.open(urlString: site.url) }
                        }
                        if often.count > limit, !showAllOften { Chip(title: "More", url: "", symbol: "ellipsis") { showAllOften = true } }
                    }
                }
            }
            if !closed.isEmpty {
                VStack(spacing: 12) {
                    SectionHeading(title: "Recently closed")
                    WrapLayout {
                        ForEach(closed, id: \.offset) { index, tab in
                            Chip(title: tab.title.isEmpty ? displayHost(tab.url) : tab.title, url: tab.url.absoluteString, symbol: "arrow.uturn.backward") { model.reopenClosedTab(at: index) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }
}

private struct SentToThisDevice: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 12) {
            SectionHeading(title: "Sent to this device")
            WrapLayout {
                ForEach(model.inbox.prefix(6)) { item in
                    Chip(title: (item.title.isEmpty ? displayHost(URL(string: item.url)) : item.title) + " · " + item.fromName, url: item.url) { model.openSentTab(item) }
                        .contextMenu { Button("Dismiss") { model.dismissSentTab(item) } }
                }
            }
        }
        .transition(.opacity)
    }
}

private struct OtherDeviceTabs: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 20) {
            ForEach(model.remoteTabs.prefix(2)) { device in
                VStack(spacing: 12) {
                    SectionHeading(title: "On \(device.device)")
                    WrapLayout {
                        ForEach(device.tabs.prefix(6), id: \.url) { tab in
                            Chip(title: tab.title.isEmpty ? displayHost(URL(string: tab.url)) : tab.title, url: tab.url) { model.open(urlString: tab.url, newTab: true) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Protection line and customizing

/// Only facts the browser can measure: that protection is on, how many rules are loaded, how many tracking links were cleaned. WebKit's
/// content blockers do not report how many requests they stopped, so no such number is shown, and the line is hidden if there is nothing to say.
private struct PrivacyLine: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let rules = model.privacy.snapshot?.totalRules ?? 0
        if rules > 0 {
            let cleaned = model.strippedLinkCount
            Button { model.sheet = .dashboard } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield").font(.system(size: 11))
                    Text("Protection on · \(rules.formatted()) rules" + (cleaned > 0 ? " · \(cleaned) tracking link\(cleaned == 1 ? "" : "s") cleaned" : ""))
                        .font(.system(size: 11.5)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Protection is on with \(rules) rules. Open the privacy dashboard.")
            .accessibilityIdentifier("privacy-line")
        }
    }
}

/// Which parts of the page show. Changes apply at once and are kept.
private struct CustomizeMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button { animated(.easeOut(duration: 0.22)) { model.startDrawerOpen = true } } label: {
            Label("Customize", systemImage: "slider.horizontal.3").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .keyboardFocusRing(radius: 6)
        .fixedSize()
        .accessibilityIdentifier("customize-start")
    }
}

#if os(macOS)
// MARK: - The search field in the middle of the page (Mac)

/// An independent text field: its own focus, its own text, its own suggestions. It shares the browser's search engine, suggestion provider,
/// address parser and navigation, but never hands focus to, or takes it from, the address bar in the toolbar.
private struct StartSearchField: View {
    @EnvironmentObject var model: BrowserModel
    @StateObject private var address = AddressBarController()
    @FocusState private var focused: Bool
    @State private var overList = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
            TextField("Search or enter address", text: $address.text)
                .textFieldStyle(.plain).font(.system(size: 16))
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.downArrow) { address.moveSelection(1); return .handled }
                .onKeyPress(.upArrow) { address.moveSelection(-1); return .handled }
                .onKeyPress(.escape) { escape(); return .handled }
                .accessibilityLabel("Search or enter address")
                .accessibilityIdentifier("start-search")
            if !address.text.isEmpty {
                Button { address.text = ""; address.clear(); focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain).accessibilityLabel("Clear")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 18).frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(scheme == .dark ? Color(red: 0.110, green: 0.133, blue: 0.188) : Color.primary.opacity(0.06)))
        .motion(.easeOut(duration: 0.15), value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Suggestions open straight under this field, over the rest of the page.
        .overlay(alignment: .top) {
            if focused || overList {
                SuggestionsList(address: address)
                    // Solid, so the page behind it never shows through the list.
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(red: 0.075, green: 0.090, blue: 0.135)))
                    .padding(.top, 62)
                    .onHover { overList = $0 }
            }
        }
        .zIndex(10)
        .onChange(of: address.text) { _, _ in
            address.isEditing = true
            address.refresh(model: model)
        }
        .onChange(of: focused) { _, now in
            address.isEditing = now
            if now { address.refresh(model: model) }
        }
        // A new blank tab opens with this field ready for typing; ⌘L still goes to the address bar, whatever has focus.
        .onChange(of: model.startFocusTick) { _, _ in focused = true }
        .onAppear { DispatchQueue.main.async { if model.active?.isBlank ?? false { focused = true } } }
    }

    private func submit() {
        let text = address.text
        if let picked = address.selectedSuggestion {
            reset()
            model.accept(picked)
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            reset()
            model.navigate(input: text)
        }
    }

    /// Escape closes the suggestions first; a second press clears what was typed and lets go of the field.
    private func escape() {
        if !address.suggestions.isEmpty { address.selection = nil; address.clear() }
        else { address.text = ""; focused = false }
    }

    private func reset() { address.clear(); address.text = ""; address.isEditing = false; focused = false }
}
#endif
