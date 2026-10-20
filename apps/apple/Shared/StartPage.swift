import SwiftUI

private struct StartBottomInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
    /// Room the page leaves at its foot for a toolbar that floats over it (the iPhone's dock).
    var startBottomInset: CGFloat {
        get { self[StartBottomInsetKey.self] }
        set { self[StartBottomInsetKey.self] = newValue }
    }
}

/// The page a blank tab shows. Quiet and fast: the day and a greeting, one large search field, your favorites as cards, one card to carry on where you
/// were, the places you go often, and a single honest line about protection at the foot. Long lists show a few and say how many more there are. It is plain
/// SwiftUI over the browser's own data (bookmarks, history, tabs); there is no web view behind it, and nothing on it is fetched from the network except site
/// icons you allow.
struct StartPageView: View {
    @EnvironmentObject var model: BrowserModel
    let isPrivate: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.startBottomInset) private var bottomInset
    @State private var addingFavorite = false
    @State private var newURL = ""
    @State private var newName = ""
    #if os(iOS)
    @StateObject private var voice = VoiceSearch()
    #endif

    /// The Customize size choice scales the greeting and the search box as well as the site tiles.
    private var startScale: CGFloat { model.startTile.points / 52 }

    private var accent: Color { isPrivate ? Theme.privateAccent : Theme.accent }

    #if os(macOS)
    private var contentWidth: CGFloat { 720 * model.startWidth.factor }
    #else
    private var contentWidth: CGFloat { 640 * model.startWidth.factor }
    #endif

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                if model.newTabMode == .blank && !isPrivate {
                    Color.clear.frame(height: geo.size.height).accessibilityHidden(true)
                } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 28)
                    VStack(spacing: 30) {
                        VStack(spacing: 24) {
                            greeting
                            heroSearch
                        }
                        .startEntrance(0)
                        // Above everything below it: the suggestions open over the favorites and the cards, and they were being drawn under them.
                        .zIndex(10)
                        if isPrivate {
                            privateNote
                        } else {
                            if model.showFavorites { FavoritesGrid(addingFavorite: $addingFavorite).startEntrance(1) }
                            if model.showContinue, let tab = model.continueTab { ContinueCard(tab: tab).startEntrance(2) }
                            if model.showFrequent || model.showRecentlyClosed { HistoryChips().startEntrance(3) }
                            if !model.inbox.isEmpty { SentToThisDevice() }
                            if !model.remoteTabs.isEmpty { OtherDeviceTabs() }
                        }
                    }
                    Spacer(minLength: 28)
                    if !isPrivate {
                        HStack(spacing: 10) {
                            PrivacyLine()
                            CustomizeMenu()
                        }
                        .startEntrance(4)
                        .padding(.top, 20)
                        .padding(.bottom, bottomInset)
                    }
                }
                .frame(maxWidth: contentWidth)
                .padding(.horizontal, 24).padding(.vertical, 18)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
            // One screen when it fits; it scrolls (and never clips) on a small phone, in landscape, or with large text.
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(background)
        .motion(.easeOut(duration: 0.25), value: model.startBackground)
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
        let custom = model.startTitle.trimmingCharacters(in: .whitespaces)
        let title = isPrivate ? "Private Browsing" : (!custom.isEmpty ? custom : (model.showGreeting ? word : "Browser Setu"))
        return VStack(spacing: 6) {
            if !isPrivate, model.showGreeting {
                Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12, weight: .semibold)).tracking(0.9).textCase(.uppercase).foregroundStyle(accent.opacity(0.9))
            }
            Text(title)
                .font(.system(size: 34 * startScale, weight: .semibold, design: model.startFont.design)).foregroundStyle(.primary.opacity(0.92))
                .minimumScaleFactor(0.7).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .motion(.easeOut(duration: 0.2), value: model.startTile)
    }

    /// On the Mac this is a real text field of its own: clicking it keeps focus and typing in the page, with suggestions right under it. The
    /// top address bar is a separate field with its own focus; both use the same search, suggestion and navigation code. On the iPhone a tap
    /// opens the search panel, which is the same thing there.
    @ViewBuilder private var heroSearch: some View {
        #if os(macOS)
        StartSearchField()
        #else
        HStack(spacing: 8) {
        Button { model.openSearchPanel() } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 17 * startScale, weight: .medium)).foregroundStyle(accent)
                Text("Search or enter address").font(.system(size: 16 * startScale)).foregroundStyle(.secondary)
                Spacer()
                EngineBadge()
            }
            .padding(.horizontal, 18).frame(height: 56)
            .startField(radius: model.startSearchStyle.radius)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search or enter address")
        .accessibilityIdentifier("start-search")
        VoiceButton(voice: voice, round: true)
        }
        .onAppear { voice.onFinish = { words in model.navigate(input: words) } }
        .onChange(of: voice.problem) { _, message in if let message { model.notice = message; voice.problem = nil } }
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
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(accent.opacity(0.25), lineWidth: 0.5))
    }

    /// Midnight charcoal with a barely perceptible blue tint in the middle.
    private var background: some View {
        Group {
            if isPrivate { Color.platformBackground }
            else if model.startBackground == .image {
                if let data = model.startImageData, let image = Image(platformData: data) {
                    Color.clear.overlay(image.resizable().scaledToFill().blur(radius: model.startImageBlur).overlay(Color.black.opacity(model.startImageDim))).clipped()
                } else if scheme == .dark { Color(red: 0.047, green: 0.059, blue: 0.090) } else { Color.platformBackground }
            }
            else if model.startBackground == .color { StartColor.color(model.startColorA) }
            else if model.startBackground == .blend {
                LinearGradient(colors: [StartColor.color(model.startColorA), StartColor.color(model.startColorB, fallback: StartColor.defaultB)], startPoint: .top, endPoint: .bottom)
            }
            else if model.startBackground == .plain {
                // Plain: one flat colour, no glow, decoration or photo.
                if model.themeIsActive { model.activeTheme.top.color } else if scheme == .dark { Color(red: 0.047, green: 0.059, blue: 0.090) } else { Color.platformBackground }
            }
            else if model.themeIsActive { ThemeBackdrop(theme: model.activeTheme, photo: model.themePhoto, photoDim: model.customTheme.photoDim) }
            else if scheme == .dark {
                ZStack {
                    Color(red: 0.047, green: 0.059, blue: 0.090)                       // #0C0F17
                    RadialGradient(colors: [StartTone.glow().opacity(0.85), .clear],   // #111B30
                                   center: .init(x: 0.5, y: 0.42), startRadius: 0, endRadius: 520)
                }
            } else {
                LinearGradient(colors: [accent.opacity(0.05), Color.platformBackground], startPoint: .top, endPoint: .center).background(Color.platformBackground)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared style

/// The card every block of the page sits on: the theme's raised colour when a theme is in use, otherwise a soft tint of the text colour, with a hairline edge.
private struct StartCardStyle: ViewModifier {
    var radius: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(ThemeState.raised?.opacity(0.62) ?? Color.primary.opacity(scheme == .dark ? 0.075 : 0.05)))
            .overlay(shape.strokeBorder(Color.primary.opacity(scheme == .dark ? 0.09 : 0.07), lineWidth: 0.5))
    }
}

/// The large search field's surface: slightly brighter than a card, with a soft shadow, so it is the first thing the eye lands on.
private struct StartFieldStyle: ViewModifier {
    var radius: CGFloat = 28
    var focused = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(shape.fill(ThemeState.raised?.opacity(0.85) ?? (scheme == .dark ? Color(red: 0.115, green: 0.138, blue: 0.195) : Color.white.opacity(0.9))))
            .overlay(shape.strokeBorder(focused ? Theme.accent.opacity(0.85) : Color.primary.opacity(scheme == .dark ? 0.10 : 0.08), lineWidth: focused ? 1.5 : 0.5))
            .shadow(color: focused ? Theme.accent.opacity(0.25) : .black.opacity(scheme == .dark ? 0.30 : 0.08), radius: focused ? 14 : 10, y: 3)
    }
}

private extension View {
    func startCard(radius: CGFloat = 16) -> some View { modifier(StartCardStyle(radius: radius)) }
    func startField(radius: CGFloat = 28, focused: Bool = false) -> some View { modifier(StartFieldStyle(radius: radius, focused: focused)) }
}

/// A button that rises slightly under the pointer.
private struct HoverLift: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.035 : 1)
            .offset(y: hovering ? -2 : 0)
            .motion(.spring(response: 0.25, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
    }
}

private extension View { func hoverLift() -> some View { modifier(HoverLift()) } }

/// The name of the search engine in use, as a small capsule at the end of the search field.
private struct EngineBadge: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Text(SearchEngines.preset(for: model.searchTemplate)?.name ?? "Search")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).frame(height: 22)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

/// A heading over a section, at its leading edge, with the number of items and an optional action at the other end.
private struct SectionHeader: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).scaledFont(12, weight: .semibold).tracking(0.7).foregroundStyle(.secondary).textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            if let count, count > 0 { Text("\(count)").scaledFont(11, weight: .medium).foregroundStyle(.tertiary) }
            Spacer(minLength: 0)
        }
    }
}

/// "Show 8 more" / "Show less": every long list on the page ends with one.
private struct ShowMoreButton: View {
    @Binding var expanded: Bool
    let hidden: Int

    var body: some View {
        Button { animated(.easeOut(duration: 0.22)) { expanded.toggle() } } label: {
            HStack(spacing: 5) {
                Text(expanded ? "Show less" : "Show \(hidden) more")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .scaledFont(12, weight: .medium).foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Theme.accent.opacity(0.12)))
            .contentShape(Capsule())
            .keyboardFocusRing(radius: 14)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel(expanded ? "Show fewer" : "Show \(hidden) more")
    }
}

/// One place as a card: its icon, its name and its site; used for the pages you visit often, tabs on other devices and tabs sent to this one.
private struct SiteCard: View {
    let title: String
    let detail: String
    let url: String
    var symbol: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.14)))
                } else {
                    SiteTile(url: url, title: title, size: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaledFont(13, weight: .medium).foregroundStyle(.primary.opacity(0.9)).lineLimit(1).truncationMode(.tail)
                    if !detail.isEmpty { Text(detail).scaledFont(11).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .startCard(radius: 12)
            .contentShape(Rectangle())
            .keyboardFocusRing(radius: 12)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .hoverLift()
    }
}

/// Cards in two columns on a phone and three on a wide window.
private struct CardGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content
    #if os(macOS)
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 10)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    #endif
    var body: some View { LazyVGrid(columns: columns, spacing: 10, content: content) }
}

// MARK: - Favorites

private struct FavoritesGrid: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var addingFavorite: Bool

    private var tileSize: CGFloat { model.startTile.points }
    private let capacity = 12
    @State private var showAll = false
    @State private var editing: BookmarkItem?
    @State private var editURL = ""
    @State private var editName = ""
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 12, alignment: .top)]

    var body: some View {
        let all = model.orderedFavorites
        let limit = 8
        let items = showAll ? Array(all.prefix(capacity)) : Array(all.prefix(limit))
        VStack(spacing: 12) {
            SectionHeader(title: "Favorites", count: all.count)
            if all.isEmpty {
                emptyCard.transition(.opacity)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items, id: \.url) { favorite in tile(favorite) }
                    if all.count < capacity || showAll { addTile }
                }
                if all.count > limit { ShowMoreButton(expanded: $showAll, hidden: min(all.count, capacity) - limit) }
            }
        }
        .motion(.easeOut(duration: 0.2), value: all.map(\.url))
        .alert("Edit Favorite", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Website address", text: $editURL)
            TextField("Name", text: $editName)
            Button("Save") { if let old = editing?.url { model.editFavorite(old, address: editURL, name: editName) }; editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
    }

    private func tile(_ favorite: BookmarkItem) -> some View {
        Button { model.open(urlString: favorite.url) } label: {
            VStack(spacing: 8) {
                SiteTile(url: favorite.url, title: favorite.title, size: tileSize)
                    .frame(width: tileSize + 22, height: tileSize + 22)
                    .startCard(radius: (tileSize + 22) * 0.28)
                Text(favorite.title.isEmpty ? displayHost(URL(string: favorite.url)) : favorite.title)
                    .scaledFont(12).lineLimit(1).truncationMode(.tail).foregroundStyle(.primary.opacity(0.85)).frame(maxWidth: 92)
            }
            .frame(maxWidth: .infinity)
            .keyboardFocusRing(radius: 14)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .hoverLift()
        .draggable(favorite.url) { SiteTile(url: favorite.url, title: favorite.title, size: tileSize) }
        .dropDestination(for: String.self) { dropped, _ in
            guard let url = dropped.first else { return false }
            model.moveFavorite(url, before: favorite.url)
            return true
        }
        .contextMenu {
            Button("Open in New Tab") { model.open(urlString: favorite.url, newTab: true) }
            Button("Edit…") { editURL = favorite.url; editName = favorite.title; editing = favorite }
            Button("Remove from Favorites", role: .destructive) { model.removeFavorite(favorite.url) }
        }
        .accessibilityLabel(favorite.title.isEmpty ? displayHost(URL(string: favorite.url)) : favorite.title)
        .accessibilityAction(named: "Move earlier") { model.nudgeFavorite(favorite.url, by: -1) }
        .accessibilityAction(named: "Move later") { model.nudgeFavorite(favorite.url, by: 1) }
    }

    /// Never filled in for you: suggestions are only offered here, and nothing is added until you choose it.
    private var addTile: some View {
        addMenu {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 18, weight: .regular)).foregroundStyle(.secondary)
                    .frame(width: tileSize + 22, height: tileSize + 22)
                    .background(RoundedRectangle(cornerRadius: (tileSize + 22) * 0.28, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                Text("Add").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
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
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
            .keyboardFocusRing(radius: 16)
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
        VStack(spacing: 10) {
            SectionHeader(title: "Continue browsing")
            Button { model.select(tab.id) } label: {
                HStack(spacing: 14) {
                    if let data = tab.snapshot, let image = Image(platformData: data) {
                        Color.clear.frame(width: 96, height: 62)
                            .overlay(alignment: .top) { image.resizable().scaledToFill() }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    } else {
                        SiteTile(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, size: 44)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tab.displayTitle).scaledFont(15, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                        Text("\(displayHost(tab.url)) · \(RelativeDateTimeFormatter().localizedString(for: tab.lastActive, relativeTo: Date()))")
                            .scaledFont(12).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.accent.opacity(0.14)))
                }
                .padding(12)
                .startCard(radius: 18)
                .contentShape(Rectangle())
                .keyboardFocusRing(radius: 18)
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .hoverLift()
            .accessibilityLabel("Continue browsing: \(tab.displayTitle), \(displayHost(tab.url))")
            .accessibilityIdentifier("continue-card")
        }
    }
}

// MARK: - Places you go often, and tabs you just closed

private struct HistoryChips: View {
    @EnvironmentObject var model: BrowserModel
    @State private var often: [OftenSite] = []
    @State private var showAllOften = false
    @State private var showAllClosed = false

    struct OftenSite: Identifiable { let id: String; let title: String; let url: String; let isLocal: Bool }

    private func isLocal(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.")
    }

    /// One card per page (no repeats), local development addresses folded into a single "Local" card, readable titles.
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
            } else if titles.insert(readable.lowercased()).inserted {      // two pages with the same title are one card
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
        let shown = !model.showFrequent ? [] : (showAllOften ? often : Array(often.prefix(limit)))
        let continueURL = model.continueTab?.url?.absoluteString
        let allClosed = model.showRecentlyClosed
            ? Array(model.closedTabs.enumerated().reversed().filter { $0.element.url.absoluteString != continueURL })
            : []
        let closed = showAllClosed ? Array(allClosed.prefix(10)) : Array(allClosed.prefix(3))
        VStack(spacing: 28) {
            if !shown.isEmpty {
                VStack(spacing: 10) {
                    SectionHeader(title: "Often visited", count: often.count)
                    CardGrid {
                        ForEach(shown) { site in
                            SiteCard(title: site.title, detail: site.isLocal ? "On this computer" : displayHost(URL(string: site.url)), url: site.url, symbol: site.isLocal ? "laptopcomputer" : nil) { model.open(urlString: site.url) }
                        }
                    }
                    if often.count > limit { ShowMoreButton(expanded: $showAllOften, hidden: often.count - limit) }
                }
            }
            if !closed.isEmpty {
                VStack(spacing: 10) {
                    SectionHeader(title: "Recently closed", count: allClosed.count)
                    CardGrid {
                        ForEach(closed, id: \.offset) { index, tab in
                            SiteCard(title: tab.title.isEmpty ? displayHost(tab.url) : tab.title, detail: displayHost(tab.url), url: tab.url.absoluteString, symbol: "arrow.uturn.backward") { model.reopenClosedTab(at: index) }
                        }
                    }
                    if allClosed.count > 3 { ShowMoreButton(expanded: $showAllClosed, hidden: min(allClosed.count, 10) - 3) }
                }
            }
        }
        .onAppear(perform: load)
        // The list is read when the switch changes, not only when the section first appears; and it follows the favorites, which it leaves out.
        .onChange(of: model.showFrequent) { _, _ in load() }
        .onChange(of: model.favorites.map(\.url)) { _, _ in load() }
        .motion(.easeOut(duration: 0.2), value: model.showFrequent)
    }
}

private struct SentToThisDevice: View {
    @EnvironmentObject var model: BrowserModel
    @State private var showAll = false

    var body: some View {
        let items = Array(model.inbox.prefix(showAll ? 12 : 4))
        VStack(spacing: 10) {
            SectionHeader(title: "Sent to this device", count: model.inbox.count)
            CardGrid {
                ForEach(items) { item in
                    SiteCard(title: item.title.isEmpty ? displayHost(URL(string: item.url)) : item.title, detail: "From \(item.fromName)", url: item.url) { model.openSentTab(item) }
                        .contextMenu { Button("Dismiss") { model.dismissSentTab(item) } }
                }
            }
            if model.inbox.count > 4 { ShowMoreButton(expanded: $showAll, hidden: min(model.inbox.count, 12) - 4) }
        }
        .transition(.opacity)
    }
}

private struct OtherDeviceTabs: View {
    @EnvironmentObject var model: BrowserModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 24) {
            ForEach(model.remoteTabs.prefix(3)) { device in
                let isOpen = expanded.contains(device.device)
                let tabs = Array(device.tabs.prefix(isOpen ? 12 : 4))
                VStack(spacing: 10) {
                    SectionHeader(title: "On \(device.device)", count: device.tabs.count)
                    CardGrid {
                        ForEach(tabs, id: \.url) { tab in
                            SiteCard(title: tab.title.isEmpty ? displayHost(URL(string: tab.url)) : tab.title, detail: displayHost(URL(string: tab.url)), url: tab.url) { model.open(urlString: tab.url, newTab: true) }
                        }
                    }
                    if device.tabs.count > 4 {
                        ShowMoreButton(expanded: Binding(get: { isOpen }, set: { if $0 { expanded.insert(device.device) } else { expanded.remove(device.device) } }),
                                       hidden: min(device.tabs.count, 12) - 4)
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
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(Theme.accent)
                    Text("Protection on · \(rules.formatted()) rules" + (cleaned > 0 ? " · \(cleaned) tracking link\(cleaned == 1 ? "" : "s") cleaned" : ""))
                        .font(.system(size: 11.5)).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
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
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .keyboardFocusRing(radius: 14)
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
    @StateObject private var voice = VoiceSearch()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 17, weight: .medium)).foregroundStyle(focused ? Theme.accent : Color.secondary)
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
            } else {
                EngineBadge()
            }
            VoiceButton(voice: voice)
        }
        .padding(.horizontal, 18).frame(height: 56)
        .startField(radius: model.startSearchStyle.radius, focused: focused)
        .onAppear { voice.onFinish = { words in address.text = words; submit() } }
        .onChange(of: voice.transcript) { _, heard in if voice.listening { address.text = heard } }
        .onChange(of: voice.problem) { _, message in if let message { model.notice = message; voice.problem = nil } }
        .motion(.easeOut(duration: 0.18), value: focused)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Suggestions open straight under this field, over the rest of the page.
        .overlay(alignment: .top) {
            if focused || overList {
                SuggestionsList(address: address)
                    // Solid, so the page behind it never shows through the list; in the theme's own colour when one is in use.
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(ThemeState.raised ?? Color(red: 0.075, green: 0.090, blue: 0.135)))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .padding(.top, 64)
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


/// Each part of the start page rises into place a moment after the one above it. Without motion (Reduce Motion) it simply appears.
private struct StartEntrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(.easeOut(duration: 0.5).delay(Double(index) * 0.07), value: shown)
            .onAppear { shown = true }
    }
}

private extension View { func startEntrance(_ index: Int) -> some View { modifier(StartEntrance(index: index)) } }

/// The glow behind the start page leans warm in the morning, cool by day, violet in the evening and deep blue at night.
enum StartTone {
    static func glow(hour: Int = Calendar.current.component(.hour, from: Date())) -> Color {
        switch hour {
        case 5..<9: Color(red: 0.20, green: 0.13, blue: 0.08)
        case 9..<17: Color(red: 0.07, green: 0.16, blue: 0.21)
        case 17..<21: Color(red: 0.17, green: 0.10, blue: 0.23)
        default: Color(red: 0.067, green: 0.106, blue: 0.188)
        }
    }
}
