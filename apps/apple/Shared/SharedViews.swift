import SwiftUI
import UniformTypeIdentifiers

extension Color {
    /// The window's plain background: the theme's own chrome colour when a theme is in use, otherwise the system's.
    static var platformBackground: Color {
        if let chrome = ThemeState.chrome { return chrome }
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }
}

struct SheetContainer: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    let sheet: Sheet

    /// The sheets that need a navigation container: Settings pushes screens, and the lists carry a toolbar button of their own (History's Clear All) under their own large headings. The rest
    /// are plain panels, which on the Mac sit under a header of our own (title on the left, the one Done on the right) with no system title area above them.
    private var needsNavigation: Bool { [.history, .bookmarks, .downloads].contains(sheet) }

    var body: some View {
        #if os(macOS)
        Group {
            if needsNavigation {
                NavigationStack { panel.navigationTitle(title).sheetDoneToolbar { model.requestSheetDismiss() } }
            } else {
                VStack(spacing: 0) {
                    SheetHeader(title: title) { model.requestSheetDismiss() }
                    panel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        // Every form in a sheet is grouped: the plain style left separators misaligned and cut captions short.
        .formStyle(.grouped)
        // The editors are wide (a row of tools, a page, a bar of buttons): at the usual sheet width their tools and the Save button ran off the edges.
        // Page Tools has ten tools in a row: wide enough for the whole segmented control, so none is cut off.
        .frame(minWidth: sheet == .workbench ? 760 : (editsPictures ? 880 : (sheet == .pageTools ? 960 : 520)), minHeight: sheet == .workbench ? 620 : (editsPictures ? 680 : 460))
        #else
        NavigationStack { panel.navigationTitle(title).sheetDoneToolbar { model.requestSheetDismiss() } }
        #endif
    }

    @ViewBuilder private var panel: some View {
            Group {
                switch sheet {
                case .bookmarks: BookmarksPanel()
                case .bookmarkTools: BookmarkToolsView()
                case .compare: ComparePagesView()
                case .timeMachine: TimeMachineView()
                case .toolkit: ToolkitView()
                case .digest: DigestView()
                case .history: HistoryPanel()
                case .downloads: DownloadsPanel(coordinator: model.downloads)
                case .settings: SettingsView()
                case .summary: PageSummaryView()
                case .findAll: FindInAllTabsView()
                case .sessions: SavedSessionsView()
                case .timeline: TabActivityView()
                case .dashboard: PrivacyDashboardView()
                case .readingList: ReadingListView()
                case .note: PageNoteView()
                case .qr: QRCodeView()
                case .pageTools: PageToolsView()
                case .selection: SmartSelectionView()
                case .shareTabs: ShareTabsView()
                case .shopping: ShoppingView()
                case .repair: PageRepairView()
                case .webApps: Form { WebAppsSection() }.formStyle(.grouped)
                case .tools: ToolsPanel()
                case .picturesToPDF: PicturesToPDFView()
                case .screenshot: if let draft = model.screenshotDraft { ScreenshotEditorView(document: draft) }
                case .saveToResearch: if let draft = model.researchDraft { ResearchSaveView(draft: draft) }
                case .devices: DevicesView()
                case .pageSearch: PageSearchView()
                case .resources: ResourceDashboardView()
                case .style: SiteStyleView()
                case .layout: LayoutDiagnosticsView()
                case .research: ResearchView(store: model.research)
                case .sitePrivacy: SitePrivacyView()
                case .workbench: WorkbenchView()
                case .pdfEditor: if let url = model.pdfEditorURL { PDFEditorView(source: url) } else { Text("No PDF is open.").foregroundStyle(.secondary) }
                }
            }
            #if os(iOS)
            // In the dark theme the sheets are black, not grey, with the rows standing out as dark cards.
            .scrollContentBackground(scheme == .dark ? .hidden : .automatic)
            .background(model.themeIsActive ? Color.clear : (scheme == .dark ? Color.black : Color.clear))
            #endif
            .themedSurface()
            .tint(Theme.accent)
            // An editor with unsaved changes asks before Done or Escape closes the sheet; the editors inside leave out a Done of their own.
            .environment(\.sheetProvidesDone, true)
            // No scroll bars in a sheet either (a sheet does not take the window's setting; the Mac's system scrollers are removed by NoScrollBars).
            .scrollIndicators(.hidden)
    }

    private var editsPictures: Bool { sheet == .pdfEditor || sheet == .screenshot }

    private var title: String {
        switch sheet {
        // These three carry their own large heading, so the sheet's bar says nothing.
        case .bookmarks, .history, .downloads: ""
        case .settings: "Settings"
        case .summary: "Summary"
        case .bookmarkTools: "Bookmark Tools"
        case .compare: "Compare Pages"
        case .timeMachine: "Session Time Machine"
        case .toolkit: "Feeds and Tools"
        case .digest: "Daily Digest"
        case .findAll: "Find in All Tabs"
        case .sessions: "Saved Sessions"
        case .timeline: "Tab Activity"
        case .dashboard: "Privacy Dashboard"
        case .readingList: "Reading List"
        case .note: "Note"
        case .qr: "QR Code"
        case .pageTools: "Page Tools"
        case .selection: "Selection"
        case .shareTabs: "Share"
        case .shopping: "Shopping"
        case .repair: "Repair Page"
        case .webApps: "Web Apps"
        case .tools: "Tools"
        case .picturesToPDF: "Pictures to PDF"
        case .screenshot: "Screenshot"
        case .saveToResearch: "Save to Research"
        case .devices: "Devices"
        case .pageSearch: "Search My Pages"
        case .resources: "Resources"
        case .style: "Page Style"
        case .layout: "Layout"
        case .research: "Research"
        case .sitePrivacy: "Site Privacy"
        case .workbench: "Workbench"
        case .pdfEditor: "PDF"
        }
    }
}

struct BookmarksView: View {
    var embedded = false
    /// What the Library puts under its search field (the Bookmarks / History picker).
    var accessory: AnyView? = nil
    @EnvironmentObject var model: BrowserModel
    @State private var collapsed: Set<String> = []
    @State private var marked: String?
    @State private var enterList = 0
    @State private var dropTarget: String?
    @State private var query = ""
    @State private var items: [BookmarkItem] = []

    private var folders: [(name: String, rows: [BookmarkItem])] {
        var order: [String] = []
        var buckets: [String: [BookmarkItem]] = [:]
        for b in items {
            if buckets[b.folder] == nil { order.append(b.folder) }
            buckets[b.folder, default: []].append(b)
        }
        // Favorites first, unfiled last.
        let sorted = order.sorted { a, b in
            if a == BrowserModel.favoritesFolder { return true }
            if b == BrowserModel.favoritesFolder { return false }
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return sorted.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        if embedded { libraryBody } else { standardBody }
    }

    /// The Library sidebar: folders that fold, a site icon and the title on each row (the address is the tooltip), the same menus as the sheet.
    private var libraryBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(folders, id: \.name) { folder in
                    let isFavorites = folder.name == BrowserModel.favoritesFolder
                    let title = folder.name.isEmpty ? "Bookmarks" : folder.name
                    // While a search is on, matches are shown even inside a folded folder (folding is remembered and comes back with the empty query).
                    let folded = collapsed.contains(folder.name) && query.isEmpty
                    Button { if folded { collapsed.remove(folder.name) } else { collapsed.insert(folder.name) } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 12)
                            Image(systemName: isFavorites ? "star.fill" : (folder.name.isEmpty ? "bookmark" : "folder")).font(.system(size: 12)).foregroundStyle(isFavorites ? Color.yellow : Color.secondary).frame(width: 16)
                            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(folder.rows.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title), \(folder.rows.count) bookmarks, \(folded ? "closed" : "open")")
                    .accessibilityAddTraits(marked == "f:" + folder.name ? .isSelected : [])
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(marked == "f:" + folder.name ? 0.9 : 0), lineWidth: 1.5))
                    .id("f:" + folder.name)
                    // A bookmark dragged onto a folder moves into it (only its folder changes); the folder lights up while it is a valid target.
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(dropTarget == folder.name ? 0.22 : 0)))
                    .dropDestination(for: String.self) { items, _ in dropBookmarks(items, into: folder.name) } isTargeted: { on in
                        if on { dropTarget = folder.name } else if dropTarget == folder.name { dropTarget = nil }
                    }
                    .contextMenu { folderMenu(folder.name, count: folder.rows.count) }
                    if !folded {
                        ForEach(sorted(folder.rows), id: \.url) { b in LibraryRow(title: LibraryRow<EmptyView>.fallbackTitle(b.title, b.url), url: b.url, drag: "bookmark:" + b.url, marked: marked == "b:" + b.url, open: { model.open(urlString: b.url) }, menu: { bookmarkMenu(b, folderNames: folders.map(\.name)) }).id("b:" + b.url) }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .libraryKeyboard(marked: $marked, ids: keyboardIDs, parent: keyboardParent, activate: keyboardActivate, remove: keyboardRemove,
                         fold: { id, fold in let name = String(id.dropFirst(2)); if fold { collapsed.insert(name) } else { collapsed.remove(name) } },
                         isFolded: { id in collapsed.contains(String(id.dropFirst(2))) && query.isEmpty }, entry: enterList)
        .overlay { if items.isEmpty { ContentUnavailableView(query.isEmpty ? "No Bookmarks" : "No Results", systemImage: "book") } }
        .embeddedSearch(embedded: true, text: $query, prompt: "Search Bookmarks", accessory: accessory, enterList: $enterList)
        .safeAreaInset(edge: .bottom, spacing: 0) { libraryBar }
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    /// The rows the arrow keys visit: each folder, then (unless it is folded) its bookmarks in the order shown.
    private var keyboardIDs: [String] {
        folders.flatMap { folder -> [String] in
            let folded = collapsed.contains(folder.name) && query.isEmpty
            return ["f:" + folder.name] + (folded ? [] : sorted(folder.rows).map { "b:" + $0.url })
        }
    }
    private func keyboardParent(_ id: String) -> String? {
        guard id.hasPrefix("b:") else { return nil }
        let url = String(id.dropFirst(2))
        return folders.first { $0.rows.contains { $0.url == url } }.map { "f:" + $0.name }
    }
    private func keyboardActivate(_ id: String) {
        if id.hasPrefix("f:") {
            let name = String(id.dropFirst(2))
            if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
        } else {
            model.open(urlString: String(id.dropFirst(2)))
        }
    }
    /// Delete on a bookmark is the menu's Delete; on a folder it is Delete Folder…, which asks what to do with the bookmarks.
    private func keyboardRemove(_ id: String) {
        let key = String(id.dropFirst(2))
        if id.hasPrefix("b:") { if let b = items.first(where: { $0.url == key }) { remove(b) } }
        else if !key.isEmpty && key != BrowserModel.favoritesFolder, let folder = folders.first(where: { $0.name == key }) { deleteFolder(key, count: folder.rows.count) }
    }

    private func sorted(_ rows: [BookmarkItem]) -> [BookmarkItem] {
        switch model.librarySort {
        case .saved: return rows
        case .title: return rows.sorted { LibraryRow<EmptyView>.fallbackTitle($0.title, $0.url).localizedCaseInsensitiveCompare(LibraryRow<EmptyView>.fallbackTitle($1.title, $1.url)) == .orderedAscending }
        case .address: return rows.sorted { $0.url.localizedCaseInsensitiveCompare($1.url) == .orderedAscending }
        }
    }

    @State private var importing = false
    @State private var exporting = false
    @State private var transferDocument = BookmarkHTMLDocument(text: "")

    private var canBookmark: Bool { if let tab = model.active, !tab.isBlank, tab.url != nil { return true } else { return false } }

    /// The Library's own actions along its foot: add the page you are on, add it to a new folder, sort, and more (Reading List, Sessions, import and export, which Settings also offers).
    private var libraryBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
            HStack(spacing: 4) {
                barIcon("plus", "Bookmark This Page", id: "library-add") { addCurrentPage(to: "") }.disabled(!canBookmark)
                Menu {
                    Button("Add This Page to Favorites") { addCurrentPage(to: BrowserModel.favoritesFolder) }
                    Button("Add This Page to a New Folder…") { newFolderForCurrentPage() }
                } label: { barGlyph("folder.badge.plus") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .disabled(!canBookmark).help("Add this page to a folder").accessibilityLabel("Add this page to a folder").accessibilityIdentifier("library-folder")
                Spacer(minLength: 0)
                Menu {
                    Picker("Sort", selection: $model.librarySort) { ForEach(BrowserModel.LibrarySort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
                } label: { barGlyph("arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Sort bookmarks").accessibilityLabel("Sort bookmarks").accessibilityIdentifier("library-sort")
                Menu {
                    Button("Reading List…") { model.sheet = .readingList }
                    Button("Saved Sessions…") { model.sheet = .sessions }
                    Divider()
                    Button("Import Bookmarks…") { importing = true }
                    Button("Export Bookmarks…") { transferDocument = BookmarkHTMLDocument(text: model.bookmarksHTML()); exporting = true }
                } label: { barGlyph("ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More").accessibilityLabel("More Library actions").accessibilityIdentifier("library-more")
            }
            .padding(.horizontal, 12).frame(height: 38)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ImportKind.bookmarks.contentTypes) { result in
            guard case .success(let url) = result else { return }
            Task { model.notice = await ImportActions.bookmarks(from: url, model: model); reload() }
        }
        .fileExporter(isPresented: $exporting, document: transferDocument, contentType: .html, defaultFilename: "Browser Setu Bookmarks") { result in
            if case .success = result { model.notice = "Bookmarks exported." }
        }
    }

    private func barGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).frame(width: 28, height: 26).contentShape(Rectangle())
    }
    private func barIcon(_ symbol: String, _ help: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { barGlyph(symbol) }.buttonStyle(.plain).help(help).accessibilityLabel(help).accessibilityIdentifier(id)
    }

    private func addCurrentPage(to folder: String) {
        guard let tab = model.active, !tab.isBlank, let url = tab.url?.absoluteString else { return }
        // The page may already be saved (in a folder, under a title of the person's own): adding must not move it or rename it. Choosing a folder for it from the folder menu is a move, and says so.
        if let existing = ((try? model.core.listBookmarks(query: "")) ?? []).first(where: { $0.url == url }) {
            if existing.folder == folder || folder.isEmpty { model.notice = "This page is already in your bookmarks."; return }
            try? model.core.addBookmark(url: url, title: existing.title, folder: folder)
            model.refreshBookmarkState()
            reload()
            return
        }
        try? model.core.addBookmark(url: url, title: tab.displayTitle, folder: folder)
        model.refreshBookmarkState()
        reload()
    }

    /// A folder exists once it holds a bookmark, so a new one starts with the page you are on.
    private func newFolderForCurrentPage() {
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "New Folder", message: "Name the folder. This page is added to it.", placeholder: ""), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                addCurrentPage(to: name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// The menu a bookmark has in the sheet and in the Library.
    @ViewBuilder private func bookmarkMenu(_ b: BookmarkItem, folderNames: [String]) -> some View {
        Button("Open in New Tab") { model.open(urlString: b.url, newTab: true) }
        Button("Open in Background Tab") { if let url = URL(string: b.url) { model.openTab(url: url, isPrivate: false, select: false) } }
        Divider()
        Button("Rename…") { edit(b) }
        Button("Edit Address…") { editAddress(b) }
        Button("Edit Tags…") { editTags(b) }
        Button("Copy Address") { copyToPasteboard(b.url) }
        Menu("Move to Folder") {
            Button("Favorites") { move(b, to: BrowserModel.favoritesFolder) }.disabled(b.folder == BrowserModel.favoritesFolder)
            Button("No Folder") { move(b, to: "") }.disabled(b.folder.isEmpty)
            ForEach(folderNames.filter { !$0.isEmpty && $0 != BrowserModel.favoritesFolder && $0 != b.folder }, id: \.self) { f in Button(f) { move(b, to: f) } }
            Divider()
            Button("New Folder…") { newFolder(for: b) }
        }
        Divider()
        Button("Delete", role: .destructive) { remove(b) }
    }

    /// What a folder's menu offers. A folder is a name its bookmarks share: it exists while it holds a bookmark. Favorites and the unfiled list keep their names.
    @ViewBuilder private func folderMenu(_ name: String, count: Int) -> some View {
        if !name.isEmpty && name != BrowserModel.favoritesFolder {
            Button("Rename Folder…") { renameFolder(name) }
            Button("Delete Folder…", role: .destructive) { deleteFolder(name, count: count) }
        }
    }

    /// Renaming moves each of the folder's bookmarks to the new name (their addresses and titles stay); a name another folder already has is refused, not merged.
    private func renameFolder(_ old: String) {
        Task { @MainActor in
            guard let raw = await Dialogs.promptText(title: "Rename Folder", message: "New name for “\(old)”.", placeholder: old) else { return }
            let new = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !new.isEmpty, new != old else { return }
            let all = (try? model.core.listBookmarks(query: "")) ?? []
            if new == BrowserModel.favoritesFolder || all.contains(where: { $0.folder == new }) { model.notice = "There is already a folder called “\(new)”."; return }
            for b in all where b.folder == old { try? model.core.addBookmark(url: b.url, title: b.title, folder: new) }
            collapsed.remove(old)
            reload()
        }
    }

    /// Deleting a folder asks what to do with what is in it: keep the bookmarks (they go to the unfiled list) or delete them with it.
    private func deleteFolder(_ name: String, count: Int) {
        Task { @MainActor in
            let choice = await Dialogs.choose(title: "Delete the folder “\(name)”?", message: "It holds \(count) bookmark\(count == 1 ? "" : "s"). You can keep them (they move to Bookmarks, outside any folder) or delete them with the folder.",
                                              buttons: ["Keep the Bookmarks", "Delete the Bookmarks", "Cancel"])
            guard choice == 0 || choice == 1 else { return }
            for b in ((try? model.core.listBookmarks(query: "")) ?? []) where b.folder == name {
                if choice == 0 { try? model.core.addBookmark(url: b.url, title: b.title, folder: "") } else { try? model.core.removeBookmark(url: b.url) }
            }
            model.refreshBookmarkState()
            collapsed.remove(name)
            reload()
        }
    }

    /// Changing the address replaces the saved record (its title and folder stay); an address already saved is refused, and only web addresses are taken.
    private func editAddress(_ b: BookmarkItem) {
        Task { @MainActor in
            guard let raw = await Dialogs.promptText(title: "Edit Address", message: "The address of “\(b.title.isEmpty ? b.url : b.title)”.", placeholder: b.url) else { return }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != b.url else { return }
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host?.isEmpty == false else { model.notice = "That is not a web address."; return }
            if ((try? model.core.listBookmarks(query: "")) ?? []).contains(where: { $0.url == text }) { model.notice = "That address is already saved."; return }
            try? model.core.removeBookmark(url: b.url)
            try? model.core.addBookmark(url: text, title: b.title, folder: b.folder)
            model.refreshBookmarkState()
            reload()
        }
    }

    /// A bookmark dropped on a folder: only its folder changes. Anything else that is dragged (a tab, a link) is not taken.
    private func dropBookmarks(_ items: [String], into folder: String) -> Bool {
        let moved = model.dropBookmark(items, into: folder)
        if moved { reload() }
        return moved
    }

    private var standardBody: some View {
        List {
            ForEach(folders, id: \.name) { folder in
                Section(folder.name.isEmpty ? "Bookmarks" : folder.name) {
                    ForEach(folder.rows, id: \.url) { b in
                        Button { model.open(urlString: b.url) } label: {
                            VStack(alignment: .leading) {
                                Text(b.title.isEmpty ? b.url : b.title).lineLimit(1)
                                Text(b.url).settingsNote().lineLimit(1)
                                if !model.tags(forBookmark: b.url).isEmpty {
                                    Text(model.tags(forBookmark: b.url).map { "#" + $0 }.joined(separator: " ")).font(.caption2).foregroundStyle(Theme.accent).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open in New Tab") { model.open(urlString: b.url, newTab: true) }
                            Button("Edit…") { edit(b) }
                            Button("Edit Tags…") { editTags(b) }
                            Menu("Move to Folder") {
                                Button("Favorites") { move(b, to: BrowserModel.favoritesFolder) }
                                Button("No Folder") { move(b, to: "") }
                                ForEach(folders.map(\.name).filter { !$0.isEmpty && $0 != BrowserModel.favoritesFolder }, id: \.self) { f in
                                    Button(f) { move(b, to: f) }
                                }
                                Divider()
                                Button("New Folder…") { newFolder(for: b) }
                            }
                            Button("Delete", role: .destructive) { remove(b) }
                        }
                    }
                    .onDelete { idx in idx.map { folder.rows[$0] }.forEach(remove) }
                }
            }
        }
        .overlay { if items.isEmpty { ContentUnavailableView(query.isEmpty ? "No Bookmarks" : "No Results", systemImage: "book") } }
        .embeddedSearch(embedded: embedded, text: $query, prompt: "Search Library", accessory: accessory)
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    /// Matches in the title or address, and bookmarks whose tags match ("#work" or "work").
    private func reload() {
        var found = (try? model.core.listBookmarks(query: query)) ?? []
        let wanted = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        if !wanted.isEmpty {
            let have = Set(found.map(\.url))
            let tagged = ((try? model.core.listBookmarks(query: "")) ?? []).filter { !have.contains($0.url) && model.tags(forBookmark: $0.url).contains { $0.contains(wanted) } }
            found += tagged
        }
        items = found
    }

    private func editTags(_ b: BookmarkItem) {
        let model = model
        Task { @MainActor in
            let current = model.tags(forBookmark: b.url).joined(separator: ", ")
            if let text = await Dialogs.promptText(title: "Tags", message: "Separate tags with commas. Search for a tag with #.", placeholder: current) {
                model.setTags(text, forBookmark: b.url)
                reload()
            }
        }
    }

    private func remove(_ b: BookmarkItem) {
        try? model.core.removeBookmark(url: b.url)
        model.refreshBookmarkState()
        reload()
    }

    private func move(_ b: BookmarkItem, to folder: String) {
        try? model.core.addBookmark(url: b.url, title: b.title, folder: folder)
        reload()
    }

    private func edit(_ b: BookmarkItem) {
        Task { @MainActor in
            if let title = await Dialogs.promptText(title: "Edit Bookmark", message: b.url, placeholder: b.title) {
                try? model.core.addBookmark(url: b.url, title: title, folder: b.folder)
                reload()
            }
        }
    }

    private func newFolder(for b: BookmarkItem) {
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "New Folder", message: "Name the folder.", placeholder: ""), !name.isEmpty {
                move(b, to: name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

/// One saved page in the Library sidebar (a bookmark or a history entry): the site's icon and a title; the address shows as a tooltip.
struct LibraryRow<Menu: View>: View {
    let title: String
    let url: String
    /// What dragging the row carries (nil: the row cannot be dragged).
    var drag: String? = nil
    var marked = false
    let open: () -> Void
    @ViewBuilder let menu: () -> Menu
    @State private var hovering = false

    var body: some View {
        if let drag { row.draggable(drag) } else { row }
    }

    private var row: some View {
        // The second click of a double-click is not a second open (a bookmark set to open in a new tab would otherwise open twice); the system's own click count tells them apart.
        Button {
            #if os(macOS)
            if let event = NSApp.currentEvent, event.type == .leftMouseUp || event.type == .leftMouseDown, event.clickCount >= 2 { return }
            #endif
            open()
        } label: {
            HStack(spacing: 8) {
                #if os(macOS)
                if let icon = FaviconStore.shared.image(forURL: url, points: 14) { Image(nsImage: icon).frame(width: 16, height: 16) }
                else { Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16, height: 16) }
                #else
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16, height: 16)
                #endif
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 26).padding(.trailing, 8).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent.opacity(marked ? 0.9 : 0), lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(url)
        .contextMenu(menuItems: menu)
        .accessibilityLabel(title)
        .accessibilityHint(url)
        .accessibilityAddTraits(marked ? .isSelected : [])
    }

    /// A readable title when a page has none: its address without the scheme.
    static func fallbackTitle(_ title: String, _ url: String) -> String {
        if !title.isEmpty { return title }
        return url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
}

struct HistoryView: View {
    var embedded = false
    var accessory: AnyView? = nil
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var items: [HistoryItem] = []

    /// Groups entries under Today / Yesterday / full date, newest first.
    private var sections: [(title: String, rows: [HistoryItem])] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [HistoryItem]] = [:]
        for h in items {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(h.lastVisit)))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(h)
        }
        return order.map { day in
            let title: String
            if cal.isDateInToday(day) { title = "Today" }
            else if cal.isDateInYesterday(day) { title = "Yesterday" }
            else { title = day.formatted(date: .complete, time: .omitted) }
            return (title, buckets[day] ?? [])
        }
    }

    var body: some View {
        if embedded { libraryBody } else { standardBody }
    }

    @State private var confirmingClear = false
    @State private var marked: String?
    @State private var enterList = 0

    /// The Library sidebar's History: day headings, a site icon and a title on each row, and Clear History at the foot of the Library (the sheet keeps it in its own toolbar).
    private var libraryBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.title) { section in
                    Text(section.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7).foregroundStyle(.secondary.opacity(0.85))
                        .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(section.rows, id: \.url) { h in
                        LibraryRow(title: LibraryRow<EmptyView>.fallbackTitle(h.title, h.url), url: h.url, marked: marked == "h:" + h.url, open: { model.open(urlString: h.url) }) {
                            Button("Open in New Tab") { model.open(urlString: h.url, newTab: true) }
                            Button("Open in Background Tab") { if let url = URL(string: h.url) { model.openTab(url: url, isPrivate: false, select: false) } }
                            Button("Copy Address") { copyToPasteboard(h.url) }
                            Divider()
                            Button("Remove from History", role: .destructive) { remove(h) }
                        }
                        .id("h:" + h.url)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .libraryKeyboard(marked: $marked, ids: sections.flatMap { $0.rows.map { "h:" + $0.url } },
                         activate: { id in model.open(urlString: String(id.dropFirst(2))) },
                         remove: { id in if let h = items.first(where: { $0.url == String(id.dropFirst(2)) }) { remove(h) } }, entry: enterList)
        .overlay { if items.isEmpty { ContentUnavailableView(query.isEmpty ? "No History" : "No Results", systemImage: "clock") } }
        .embeddedSearch(embedded: true, text: $query, prompt: "Search History", accessory: accessory, enterList: $enterList)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 12)
                HStack {
                    Button("Clear History…", role: .destructive) { confirmingClear = true }
                        .buttonStyle(.plain).font(.system(size: 12.5)).foregroundStyle(items.isEmpty ? Color.secondary.opacity(0.5) : Color.red.opacity(0.85))
                        .disabled(items.isEmpty)
                        .accessibilityIdentifier("clear-history")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).frame(height: 38)
            }
        }
        .confirmationDialog("Clear all browsing history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { try? model.core.clearHistory(); reload() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes every entry from History. Your bookmarks, Reading List, saved sessions and open tabs are not affected.") }
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private var standardBody: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.url) { h in
                        Button { model.open(urlString: h.url) } label: {
                            VStack(alignment: .leading) {
                                Text(h.title.isEmpty ? h.url : h.title).lineLimit(1)
                                Text(displayHost(URL(string: h.url))).settingsNote().lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open in New Tab") { model.open(urlString: h.url, newTab: true) }
                            Button("Delete", role: .destructive) { remove(h) }
                        }
                    }
                    .onDelete { idx in idx.map { section.rows[$0] }.forEach(remove) }
                }
            }
        }
        .overlay { if items.isEmpty { ContentUnavailableView(query.isEmpty ? "No History" : "No Results", systemImage: "clock") } }
        .searchable(text: $query)
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Clear All", role: .destructive) {
                    try? model.core.clearHistory()
                    reload()
                }
                .disabled(items.isEmpty)
            }
        }
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private func reload() {
        items = (query.isEmpty ? try? model.core.recentHistory(limit: 400)
                               : try? model.core.searchHistory(query: query, limit: 400)) ?? []
    }

    private func remove(_ h: HistoryItem) {
        try? model.core.deleteHistoryEntry(url: h.url)
        reload()
    }
}

// MARK: - Settings sections

struct GeneralSettingsSection: View {
    var body: some View {
        Group {
            StartupSettingsSection()
            ReaderSettingsSection()
            HistoryRetentionSection()
            SearchSettingsSection()
            SearchShortcutsSection()
        }
    }
}

struct ProfileSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var newProfile = ""

    var body: some View {
        Group {
            Section("Profiles") {
                ForEach(model.profiles, id: \.self) { name in
                    HStack(spacing: 10) {
                        Image(systemName: model.profileStyle(name).symbol)
                            .font(.system(size: 20)).foregroundStyle(model.profileStyle(name).tint ?? (name == model.profileName ? Theme.accent : Color.secondary))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name == "default" ? "Default" : name).fontWeight(.medium)
                            Text(name == model.profileName ? "In use" : (model.isTemporaryProfile(name) ? "Temporary: deleted when you leave it" : "Separate cookies, history and bookmarks")).settingsNote()
                        }
                        Spacer()
                        Menu {
                            Menu("Icon") {
                                ForEach(ProfileStyle.symbols, id: \.self) { symbol in
                                    Button { model.setProfileStyle(name, symbol: symbol) } label: { Label(symbol, systemImage: symbol) }
                                }
                            }
                            Menu("Colour") {
                                ForEach(GroupColor.allCases) { c in Button(c.title) { model.setProfileStyle(name, color: .some(c.rawValue)) } }
                                Divider()
                                Button("No Colour") { model.setProfileStyle(name, color: .some(nil)) }
                            }
                            if name != model.profileName {
                                Button("Copy Its Bookmarks Here") { model.copyBookmarks(from: name) }
                            }
                        } label: { Image(systemName: "paintpalette") }
                            .menuStyle(.borderlessButton).fixedSize().help("Icon, colour and bookmarks")
                        if name != model.profileName { Button("Switch") { model.switchProfile(name) } }
                        if name != model.profileName && name != "default" {
                            Button(role: .destructive) { Task { if await model.requireAuthentication("Delete a profile and its data") { await model.removeProfile(name) } } } label: { Image(systemName: "trash").accessibilityLabel("Delete") }
                                .buttonStyle(.borderless).help("Delete profile “\(name)”")
                        }
                    }
                }
            }
            Section {
                HStack {
                    TextField("New profile name", text: $newProfile).autocorrectionDisabled()
                    Button("Create Profile") {
                        if model.createProfile(newProfile) { model.switchProfile(newProfile); newProfile = "" }
                        else { model.notice = "Profile names use letters, numbers, - and _ (max 32)." }
                    }
                    .disabled(newProfile.isEmpty)
                }
                Button("Start a Temporary Profile") { model.startTemporaryProfile() }
                Toggle("Keep each profile's downloads in its own folder", isOn: $model.downloadsByProfile)
            } footer: {
                Text("A profile keeps its own cookies and other website data (each has its own WebKit data store), history, bookmarks, permissions, home page, search engine, appearance and extension state. A temporary profile and everything in it are deleted when you leave it or quit. Workspaces only organise tabs and share their profile's data. To move a whole profile, make an encrypted backup under Backup, switch to the other profile and restore it there; cookies, sign-ins to sites and history are not in a backup.")
            }
            if !model.siteProfiles.isEmpty {
                Section("Sites that open in a profile") {
                    ForEach(model.siteProfiles.sorted(by: { $0.key < $1.key }), id: \.key) { site, profile in
                        HStack { Text(site); Spacer(); Text(profile).foregroundStyle(.secondary); Button("Remove") { model.assignSite(host: site, to: nil) }.buttonStyle(.borderless) }
                    }
                }
            }
        }
    }
}

struct AppearanceSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            Section("Appearance") {
                Picker("Animated backdrop", selection: $model.backdropIntensity) { ForEach(BackdropIntensity.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker("Toolbar icons", selection: $model.iconWeight) { ForEach(IconWeight.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker("Site icons", selection: $model.siteIconShape) { ForEach(SiteIconShape.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Picker("Animation", selection: $model.motionStyle) { ForEach(MotionStyle.allCases) { Text($0.title).tag($0) } }
                    .settingsNoted(model.motionStyle.summary)
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Websites look", selection: $model.websiteAppearance) {
                    Text("Follow System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                    .settingsNoted("Which look websites are asked for. Theme above only changes the browser. “Follow System” lets each site choose its own design, light or dark.")
                Picker("Accent", selection: Binding(get: { model.accent }, set: { model.accent = $0; model.accentChosen = true })) {
                    ForEach(AccentChoice.allCases) { choice in
                        Label { Text(choice.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(choice.color) }.tag(choice)
                    }
                }
                Picker("Density", selection: $model.density) {
                    ForEach(InterfaceDensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.density == .compact ? "Tighter rows and tab strips: more tabs fit on screen."
                                               : "Roomier rows and tab strips: easier to read and to click.")
                    .settingsNote()
            }
            ThemesSection()
            #if os(macOS)
            ThemeScheduleSection()
            #endif
            #if os(macOS)
            Section("Layout") {
                Picker("Preset", selection: $model.layoutPreset) {
                    ForEach(LayoutPreset.Family.allCases) { family in
                        let members = LayoutPreset.allCases.filter { $0.family == family && ($0.isOffered || $0 == model.layoutPreset) }
                        if !members.isEmpty {
                            Section(family.rawValue) { ForEach(members) { Text($0.title).tag($0) } }
                        }
                    }
                }
                    .settingsNoted(model.layoutPreset.summary)
                // The toolbar is the window's own colour now, the same as the margin around the page, so there is no page tint to switch on (the stored choice is left as it was).
                Toggle("Tint the toolbar with the page’s colour", isOn: .constant(false)).disabled(true)
                Text("The toolbar now uses the window’s own colour in every layout, so it matches the margin around the page. There is no page tint to switch on.")
                    .settingsNote()
                Toggle("Fold the toolbar and tabs into a pill while reading", isOn: $model.collapseOnScroll)
                    .disabled(model.effectiveTabLayout == .sidebar && !model.topBarHidden)
                if model.effectiveTabLayout == .sidebar && !model.topBarHidden {
                    Text("Folding applies to layouts with tabs across the top. With the tabs down the side the toolbar and sidebar stay where they are.").settingsNote()
                }
                if model.layoutPreset.docksTabNavigator {
                    Text("\(model.layoutPreset.title) has its address bar in the toolbar above the page; the sidebar has none.").settingsNote()
                }
                Picker("Double-click the top bar", selection: $model.doubleClickAction) {
                    ForEach(DoubleClickAction.allCases) { Text($0.title).tag($0) }
                }
                if model.layoutPreset == .custom {
                    Toggle("Single toolbar: address bar in the sidebar, no top bar", isOn: $model.singleToolbarCustom)
                    Toggle("Reveal top toolbar at the window edge", isOn: $model.toolbarAutoHide)
                        .disabled(model.singleToolbarCustom)
                    Picker("Tab layout", selection: $model.tabLayout) {
                        ForEach(TabLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(model.singleToolbarCustom)
                    Toggle("Show sidebar", isOn: $model.sidebarVisible)
                    // What the combination does, said instead of silently overriding a choice.
                    Text(model.singleToolbarCustom
                         ? "With a single toolbar the address bar lives in the sidebar, so the tabs are always down the side and there is no top bar to reveal."
                         : model.tabLayout == .sidebar && !model.sidebarVisible
                            ? "The tabs are down the side with the sidebar hidden: they slide in when the pointer reaches the window edge."
                            : model.tabLayout == .sidebar
                                ? "Vertical tabs with a separate toolbar (the Hybrid layout has this ready-made)."
                                : "Tabs across the top with a separate toolbar.")
                        .settingsNote()
                }
                Picker("Sidebar position", selection: $model.sidebarPosition) {
                    ForEach(SidebarPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.layoutPreset.hasTabSidebar {
                    Toggle("Collapse sidebar to icons", isOn: $model.sidebarRail)
                    Toggle("Hide sidebar until the pointer touches the window edge", isOn: Binding(
                        get: { model.sidebarAutoHide }, set: { on in model.sidebarAutoHide = on; model.setSidebarShown(!on) }))
                } else {
                    // Shown, not silently missing: say why the tab-sidebar settings are not here.
                    Text(model.layoutPreset == .canvas
                         ? "Canvas has no sidebar; the Library opens from its handle or the menus. Its position and width below are kept for the Library."
                         : "\(model.layoutPreset.title) has its tabs across the top, so there is no tab sidebar to collapse or hide at the edge. Position and width apply to the Library sidebar.")
                        .settingsNote()
                }
                HStack {
                    Text("Sidebar width")
                    Slider(value: $model.sidebarWidth, in: sidebarWidthRange, step: 10)
                    Text("\(Int(model.sidebarWidth))").monospacedDigit().foregroundStyle(.secondary)
                }
                .disabled(model.sidebarRail)
                if model.sidebarRail { Text("The width applies when the sidebar is open; the icon rail has one fixed width.").settingsNote() }
                Picker("Split view direction", selection: $model.splitOrientation) {
                    Text("Side by side").tag(SplitOrientation.sideBySide)
                    Text("Stacked").tag(SplitOrientation.stacked)
                }
            }
            #else
            if UIDevice.current.userInterfaceIdiom == .pad {
                Section("Address Bar") {
                    Picker("Position", selection: $model.addressBarPosition) {
                        ForEach(AddressBarPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            #endif
            Section("Toolbar") {
                ForEach(ToolbarItemID.available) { item in
                    #if os(iOS)
                    if item != .sidebar { toolbarToggle(item) }
                    #else
                    toolbarToggle(item)
                    #endif
                }
            }
            Section {
                Button("Reset Appearance and Layout") {
                    model.appearance = .system; model.accent = .teal; model.accentChosen = false; model.density = .comfortable
                    model.sidebarWidth = sidebarStandardWidth
                    model.addressBarPosition = BrowserModel.defaultAddressBarPosition
                    // The same standard layout every other reset gives: also the pin choice, auto-hide, single toolbar, focus mode and toolbar buttons.
                    model.restoreStandardLayout()
                }
            } footer: { Text("Resets only appearance. Your tabs, bookmarks, history and profiles are not touched.") }
        }
    }

    private func toolbarToggle(_ item: ToolbarItemID) -> some View {
        Toggle(isOn: Binding(
            get: { model.toolbarItems.contains(item) },
            set: { on in
                var chosen = Set(model.toolbarItems)
                if on { chosen.insert(item) } else { chosen.remove(item) }
                model.toolbarItems = ToolbarItemID.allCases.filter { chosen.contains($0) }
            })) {
            Label(item.title, systemImage: item.symbol)
        }
    }
}

struct TabsSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            Section("Tab Overview") {
                Toggle("Show page previews", isOn: $model.tabPreviews)
                    .settingsNoted("Previews are captured only when you leave a tab or open the overview, and are kept in memory only.")
            }
            #if os(macOS)
            Section("Closing Tabs") {
                Toggle("Double-click a tab to close it", isOn: $model.doubleClickClosesTab)
                Toggle("Hide the close cross on tabs", isOn: $model.hideTabCloseButtons)
                    .settingsNoted("A middle click, the tab menu and ⌘W still close a tab.")
                Toggle("Close the window when its last tab closes", isOn: $model.closeWindowWithLastTab)
            }
            #endif
            Section {
                Toggle("Glance", isOn: $model.glanceEnabled)
                #if os(macOS)
                Picker("Open a link in Glance with", selection: $model.glanceTrigger) {
                    ForEach(GlanceTrigger.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.glanceEnabled)
                #endif
                Toggle("Use a temporary session", isOn: $model.glanceTemporarySession).disabled(!model.glanceEnabled)
            } header: { Text("Glance") } footer: {
                Text("Glance shows a link in a floating preview over the page, without leaving it. Open it as a tab, or close it and it is gone. It browses in the page’s own container (or privately if the page is private), cannot open pop-ups of its own, and a previewed page is not added to history unless you open it as a tab. A temporary session gives it storage of its own that is deleted when it closes, so it is signed in nowhere. Touch and hold a link on iPhone and choose Open in Glance; on the Mac use the link’s menu or the click chosen above.")
            }
            Section("Tab Tree") {
                Toggle("Show tabs under the tab they were opened from", isOn: $model.tabTree)
                    .settingsNoted("In the vertical tab list (the Sidebar layout), a tab opened from a link sits one step in under its parent, and the arrow beside a parent folds its branch. Closing a parent moves its tabs up a level. The horizontal strip of Classic, Minimal and One Row shows no indentation: turning this on only places each tab beside the tab it was opened from.")
            }
            Section("Tab Groups") {
                if model.groupNames.isEmpty { Text("No tab groups").foregroundStyle(.secondary) }
                ShowMoreRows(model.groupNames, id: \.self) { name in
                    HStack { Label(name, systemImage: "folder"); Spacer()
                        Button("Delete", role: .destructive) { model.deleteGroup(name) } }
                }
                Button("New Group…") { promptNewGroup(model: model) }
            }
        }
    }
}

/// Every workspace as one tidy row: its icon, its name, how many tabs it holds, and a menu for the rest. Opening a row shows the colour and layout it uses.
struct WorkspacesSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var open: String?

    var body: some View {
        Section {
            personalRow
            ForEach(model.workspaces) { ws in WorkspaceSettingsRow(workspace: ws, expanded: open == ws.name) { animated(.easeOut(duration: 0.2)) { open = open == ws.name ? nil : ws.name } } }
            Button { promptNewWorkspaceShared() } label: { Label("New Workspace…", systemImage: "plus.circle") }
            #if os(macOS)
            Toggle("Open a workspace asked for from outside in a new window", isOn: $model.spaceRequestsOpenNewWindow)
            #endif
        } header: {
            Text("Workspaces")
        } footer: {
            Text("A workspace keeps its own tabs, and can have its own accent colour and layout. Switch with the workspace button in the toolbar, the Workspace menu, or the sidebar. Deleting one keeps its tabs; they move to Personal. From outside the app: a browsersetu://space?name=… link, a Shortcuts action, or --space \"Name\" on the command line.")
        }
    }

    private var personalRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))
            VStack(alignment: .leading, spacing: 1) {
                Text("Personal").fontWeight(.medium)
                Text("The default workspace").settingsNote()
            }
            Spacer()
            TabCountBadge(count: model.workspaceTabCount(""))
        }
        .padding(.vertical, 2)
    }

    private func promptNewWorkspaceShared() {
        let model = model
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "New Workspace", message: "Name this workspace.", placeholder: ""), !name.isEmpty {
                model.createWorkspace(name)
            }
        }
    }
}

private struct TabCountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count) tab\(count == 1 ? "" : "s")").settingsNote()
            .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

private struct WorkspaceSettingsRow: View {
    @EnvironmentObject var model: BrowserModel
    let workspace: Workspace
    let expanded: Bool
    let toggle: () -> Void

    private var accent: AccentChoice? { workspace.accent.flatMap(AccentChoice.init(rawValue:)) }
    private var layout: LayoutPreset? { workspace.preset.flatMap(LayoutPreset.init(rawValue:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(Workspace.iconChoices, id: \.self) { icon in
                        Button { model.setWorkspaceIcon(workspace.name, icon: icon) } label: { Label(icon, systemImage: icon) }
                    }
                } label: {
                    WorkspaceIconTile(icon: workspace.icon, gradient: workspace.gradient, accent: accent?.color ?? Theme.accent)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Change the icon")
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name).fontWeight(.medium)
                    Text(summary).settingsNote().lineLimit(1)
                }
                Spacer()
                TabCountBadge(count: model.workspaceTabCount(workspace.name))
                Menu {
                    Button("Rename…") { rename() }
                    Button("Move Up") { model.moveWorkspace(workspace.name, by: -1) }
                    Button("Move Down") { model.moveWorkspace(workspace.name, by: 1) }
                    Divider()
                    Button("Delete Workspace", role: .destructive) {
                        #if os(macOS)
                        confirmDeleteWorkspace(model: model, name: workspace.name)
                        #else
                        model.deleteWorkspace(workspace.name)
                        #endif
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(.secondary).accessibilityLabel("More for \(workspace.name)")
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                Button(action: toggle) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 18, height: 28).contentShape(Rectangle())
                        .accessibilityLabel(expanded ? "Hide options" : "Show options")
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 2)
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Accent colour").foregroundStyle(.secondary)
                        Spacer()
                        HStack(spacing: 9) {
                            swatch(nil)
                            ForEach(AccentChoice.allCases) { swatch($0) }
                        }
                    }
                    WorkspaceThemeEditor(workspace: workspace)
                    #if os(macOS)
                    HStack {
                        Text("Layout when opened").foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(get: { layout }, set: { model.setWorkspacePreset(workspace.name, preset: $0) })) {
                            Text("Keep current").tag(LayoutPreset?.none)
                            ForEach(LayoutPreset.allCases.filter { $0.isOffered || $0 == layout }) { Text($0.title).tag(LayoutPreset?.some($0)) }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize()
                    }
                    #endif
                }
                .padding(.top, 10).padding(.leading, 42)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .motion(.easeOut(duration: 0.2), value: expanded)
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(accent.map { "\($0.title) accent" } ?? (workspace.gradient != nil ? "Gradient theme" : "Same accent as everywhere"))
        if let layout { parts.append("opens in \(layout.title)") }
        return parts.joined(separator: " · ")
    }

    private func swatch(_ choice: AccentChoice?) -> some View {
        let selected = accent == choice
        return Button { model.setWorkspaceAccent(workspace.name, accent: choice) } label: {
            ZStack {
                if let choice { Circle().fill(choice.color) } else { Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2])) }
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(choice == nil ? Color.secondary : Color.white).opacity(selected ? 1 : 0)
            }
            .frame(width: 20, height: 20)
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5).padding(-3).opacity(selected ? 1 : 0))
        }
        .buttonStyle(.plain)
        .help(choice?.title ?? "Same as everywhere")
        .accessibilityLabel((choice?.title ?? "Same as everywhere") + (selected ? ", selected" : ""))
    }

    private func rename() {
        let model = model, old = workspace.name
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "Rename Workspace", message: "New name for “\(old)”.", placeholder: old), !name.isEmpty {
                model.renameWorkspace(old, to: name)
            }
        }
    }
}

struct StartPageSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Start Page") {
            Toggle("Greeting", isOn: $model.showGreeting)
            Toggle("Favorites", isOn: $model.showFavorites)
            Toggle("Frequently Visited", isOn: $model.showFrequent)
            Toggle("Recently Closed", isOn: $model.showRecentlyClosed)
            Picker("Background", selection: $model.startBackground) {
                ForEach(StartBackground.allCases) { Text($0.title).tag($0) }
            }
                .settingsNoted("Everything on this page comes from this device. Nothing is sent anywhere.")
        }
    }
}

struct PrivacySettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            VayuProtectionSection(privacy: model.privacy)
            PrivacyPresetSection()
            SecurityFactsSection()
            LinkCleaningSection()
            SiteIconsSection()
            ThreatListSection()
            ProxySection()
            PageDefensesSection()
            SitePermissionsSection()
            SafetySettingsSection()
            VayuSetuSection()
            AISettingsSection()
            PopupSettingsSection()
            WebsiteDataSection()
            BrowsingDataSection()
        }
    }
}

struct ExtensionsSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var choosing = false
    @State private var askingStore = false
    @State private var storeAddress = ""
    @State private var fetchingStore = false
    @State private var offer: ExtensionInfo?
    @State private var failure: String?
    @State private var removing: ExtensionInfo?
    @State private var reviewing: ExtensionInfo?
    /// Set while the folder being chosen is a newer version of an extension that is already installed.
    @State private var updatingID: String?

    /// Downloads the extension named by a Chrome Web Store address or id, then offers it for review like any other.
    private func addFromStore(_ input: String) {
        guard let id = ChromeWebStore.extensionID(from: input) else { failure = ChromeWebStore.Failure.noID.localizedDescription; return }
        fetchingStore = true
        Task {
            defer { fetchingStore = false }
            do {
                let package = try await ChromeWebStore.download(id: id)
                defer { try? FileManager.default.removeItem(at: package) }
                let folder = try await ExtensionPackage.unpackAsync(file: package)
                offer = try await model.extensionCenter.inspect(folder, chromeID: id)
            } catch { failure = error.localizedDescription }
        }
    }

    private var unsupportedText: String {
        #if os(macOS)
        "This version of macOS cannot run web extensions. They need macOS 15.4 or later."
        #else
        "This version of iOS cannot run web extensions. They need iOS 18.4 or later."
        #endif
    }

    var body: some View {
        Group {
            Section("Installed Extensions") {
                if model.extensionCenter.safeMode {
                    Label("Started without extensions. Quit and open the app again to turn them back on.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !model.extensionCenter.isSupported {
                    Text(unsupportedText).foregroundStyle(.secondary)
                } else if model.extensionCenter.extensions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("No extensions installed").fontWeight(.medium)
                        Text(model.extensionCenter.canInstall ? "Add an extension from a folder or file, or from its Chrome Web Store page." : "Extensions are added on a Mac.").settingsNote()
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                ForEach(model.extensionCenter.extensions) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).fontWeight(.medium)
                                if !item.version.isEmpty { Text("Version \(item.version)").settingsNote() }
                            }
                            Spacer()
                            if item.hasOptions && item.enabled { Button("Settings") { model.extensionCenter.openOptions(item.id) } }
                            Button("Permissions…") { reviewing = item }
                            Button("Update…") { Task { if await model.requireAuthentication("Update an extension") { updatingID = item.id; choosing = true } } }.help("Choose the folder of a newer version")
                            Toggle("Enabled", isOn: Binding(get: { item.enabled }, set: { on in Task { await model.extensionCenter.setEnabled(item.id, on) } }))
                                .labelsHidden()
                            Button("Remove", role: .destructive) { removing = item }
                        }
                        if !item.problems.isEmpty {
                            Label(item.problems.joined(separator: " "), systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if model.extensionCenter.canInstall {
                    Button("Add Extension…") { Task { if await model.requireAuthentication("Add an extension") { updatingID = nil; choosing = true } } }
                    Button(fetchingStore ? "Downloading…" : "Add from Chrome Web Store…") { Task { if await model.requireAuthentication("Add an extension") { updatingID = nil; storeAddress = ""; askingStore = true } } }
                }
            }
            Section {
                Text("Choose an extension folder (the one that contains manifest.json) or a .crx or .zip file, as Chrome extensions come. You review the permissions before anything runs, and extensions never run in private tabs. A folder with a manifest is not a guarantee it works: WebKit supports only part of the extension standard, and anything that can’t load is reported here.")
                    .settingsNote()
            }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder, .zip, UTType(filenameExtension: "crx") ?? .data]) { result in
            guard case .success(var folder) = result else { return }
            Task {
                do {
                    // A .crx (as Chrome packs it) or .zip is unpacked into a temporary folder first; a folder is used as it is.
                    if (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { folder = try await ExtensionPackage.unpackAsync(file: folder) }
                    let info = try await model.extensionCenter.inspect(folder, replacing: updatingID)
                    // An update must be the same extension, not a different one dropped over it.
                    if let id = updatingID, let installed = model.extensionCenter.extensions.first(where: { $0.id == id }), installed.name != info.name {
                        updatingID = nil
                        failure = "That folder holds “\(info.name)”, not “\(installed.name)”. Use Add Extension to install a different one."
                        return
                    }
                    offer = info
                } catch { updatingID = nil; failure = error.localizedDescription }
            }
        }
        .alert("Add from Chrome Web Store", isPresented: $askingStore) {
            TextField("Store address or extension id", text: $storeAddress)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") { addFromStore(storeAddress) }
        } message: { Text("Paste the extension’s page address from chromewebstore.google.com, or its id. Browser Setu contacts Google once, to download it, and you review its permissions before it runs.") }
        .sheet(item: $reviewing) { ExtensionPermissionsSheet(info: $0) }
        .sheet(item: $offer) { info in
            ExtensionApprovalSheet(info: info, isUpdate: updatingID != nil) {
                let replacing = updatingID
                updatingID = nil
                Task {
                    do { try await model.extensionCenter.installPending(replacing: replacing, token: info.approvalToken) }
                    catch { failure = error.localizedDescription }
                }
            }
        }
        .alert("Extension", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let item = removing { Task { if await model.requireAuthentication("Remove an extension") { await model.extensionCenter.remove(item.id) } } }
                removing = nil
            }
        } message: { Text("Its files and the data it saved are deleted.") }
    }
}

/// What an extension is asking for, shown before anything is installed.
struct ExtensionApprovalSheet: View {
    let info: ExtensionInfo
    var isUpdate = false
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isUpdate ? "Update “\(info.name)” to version \(info.version)?" : "Add “\(info.name)”?").font(.headline)
            if info.manifestVersion > 0 { Text("Manifest V\(info.manifestVersion) extension").settingsNote() }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let cautions = ExtensionRisk.warnings(for: info.permissions + info.sites)
                    if !cautions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Be careful", systemImage: "exclamationmark.shield").font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                            ForEach(cautions, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.red) }
                            Text("Only add extensions from people you trust.").settingsNote()
                        }
                    }
                    group("It will be able to", info.permissions, empty: "Nothing beyond the pages you allow below.")
                    group("On these websites it can read and change what you see", info.sites, empty: "No websites.")
                    if !info.addedPermissions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("New in this version", systemImage: "plus.circle").font(.subheadline.weight(.semibold))
                            ForEach(info.addedPermissions, id: \.self) { Text("• \($0)").font(.callout) }
                        }
                    }
                    if !info.compatibility.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Might not fully work", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                            ForEach(info.compatibility, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.orange) }
                        }
                    }
                    if !info.problems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("WebKit reports").font(.subheadline.weight(.semibold))
                            ForEach(info.problems, id: \.self) { Text("• \($0)").font(.callout).foregroundStyle(.orange) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isUpdate ? "Update" : "Add Extension") { install(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 380)
    }

    private func group(_ title: String, _ items: [String], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            if items.isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { Text("• \($0)").font(.callout) }
        }
    }
}

struct DownloadsSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Group {
        Section("Downloads") {
            LabeledContent("Saved to", value: DownloadCoordinator.directory.path)
            Picker("Downloads at a time", selection: $model.maxDownloads) { ForEach(DownloadQueueRules.maxConcurrentChoices, id: \.self) { Text("\($0)").tag($0) } }
                .settingsNoted("The rest wait their turn, and you can move one to the front. Speed limits are under “Speed and network” below.")
            Toggle("Sort downloads into folders by kind", isOn: $model.organizeDownloads)
            if model.organizeDownloads {
                Text("New downloads go into Images, Documents, Archives, Audio, Video, Installers or Other inside that folder.").settingsNote()
            }
            Toggle("Download big files in several pieces at once", isOn: $model.fasterDownloads)
                .settingsNoted("For files of 8 MB or more from sites that allow it. Faster where a site slows each connection; it does nothing if your own connection is the limit. Large downloads from sites you must sign in to use the normal way.")
            Toggle("Sort downloads into folders by website", isOn: $model.organizeByDomain)
                .settingsNoted("Used when no rule or kind folder applies first: each site gets its own folder, such as example.com.")
                .settingsNoted("Only when Browser Setu is in the background.")
            Picker("When a file with that name is already there", selection: $model.duplicatePolicy) { ForEach(DuplicatePolicy.allCases) { Text($0.title).tag($0) } }
                .settingsNoted(model.duplicatePolicy == .replace ? "The old file is moved to the Trash, so it can be put back." : model.duplicatePolicy == .ask ? "You are asked each time. If you do not answer, both are kept." : model.duplicatePolicy == .skip ? "The download is not started, and the list tells you why." : "The new file gets a number: “name (1).pdf”. Nothing is overwritten.")
            TextField("Name template", text: $model.downloadNameTemplate).autocorrectionDisabled()
            if let problem = DownloadCoordinator.templateProblem(model.downloadNameTemplate) {
                Text("\(problem) Downloads keep the name the site gave until this is fixed.").font(.caption).foregroundStyle(.orange)
            } else {
                Text("{name} is the name the site gave (without its ending), {site} the website, {type} the kind of file, {date} and {time} when it was fetched. Slashes make folders inside Downloads, up to three deep. Example: “{site}/{date}/{name}”. The ending, such as .pdf, is kept.")
                    .settingsNote()
                Text("Example: \(NamingTemplate.preview(model.downloadNameTemplate))").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Files are never opened automatically.").settingsNote()
            Button("Clear Download History") {
                try? model.core.clearDownloads()
                model.downloads.clearCompleted()
            }
        }
        DownloadNetworkSettingsSection()
        TorrentSettingsSection()
        ED2KSettingsSection()
        DownloadExtensionsSettingsSection()
        #if os(macOS)
        LinkDetectionSettingsSection()          // defined with the Mac's Link Grabber
        #endif
        DownloadNotificationSettingsSection()
        DownloadAutomationSettingsSection()
        #if os(macOS)
        RemoteDevicesSettingsSection()
        ProviderSettingsSection()
        MediaSettingsSection()
        AccountsSettingsSection()
        #endif
        }
    }
}

struct PerformanceSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            MemorySettingsSection()
            NeverSleepSection()
            ResourceMonitorSection()
            SmoothnessSection()
            Section("Split View") {
                Text(model.splitTabID == nil ? "Split view is closed." : "Split view keeps two pages live at once, which uses more memory.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AdvancedSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Engine", value: model.engine.name)
            LabeledContent("Profile", value: model.profileName)
                .settingsNoted("Diagnostics stay on this device. Nothing is collected or sent.")
        }
    }
}

/// All settings in one form (iOS and sheets). The Mac Settings window splits these into tabs.
#if os(iOS)
/// Settings on the iPhone: a short list of topics, each opening its own page, instead of one very long form.
struct SettingsView: View {
    private struct Topic: Identifiable {
        let id: String, title: String, symbol: String, tint: Color
    }

    private let topics: [Topic] = [
        Topic(id: "general", title: "General", symbol: "gearshape", tint: .gray),
        Topic(id: "interface", title: "Toolbar and Appearance", symbol: "rectangle.bottomthird.inset.filled", tint: .blue),
        Topic(id: "privacy", title: "Privacy and Security", symbol: "hand.raised.fill", tint: .indigo),
        Topic(id: "sync", title: "Sync and Backup", symbol: "arrow.triangle.2.circlepath", tint: .teal),
        Topic(id: "performance", title: "Performance and Pages", symbol: "gauge.with.dots.needle.50percent", tint: .green),
        Topic(id: "extensions", title: "Extensions and Scripts", symbol: "puzzlepiece.extension", tint: .orange),
        Topic(id: "advanced", title: "Advanced", symbol: "wrench.and.screwdriver", tint: .brown),
        Topic(id: "about", title: "About", symbol: "info.circle", tint: .secondary),
    ]

    @State private var query = ""

    private func title(forTopic id: String) -> String { topics.first { $0.id == id }?.title ?? "Settings" }

    var body: some View {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { topicList } else { results }
        }
        .searchable(text: $query, prompt: "Search Settings")
        .themedSurface()
    }

    private var results: some View {
        let found = SettingsIndex.search(query)
        return List {
            if found.isEmpty { Text("No settings match “\(query)”.").foregroundStyle(.secondary) }
            ForEach(found) { entry in
                NavigationLink {
                    SettingsPage(title: title(forTopic: entry.phone)) { page(entry.phone) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                        Text(title(forTopic: entry.phone)).settingsNote()
                    }
                }
            }
        }
        .accessibilityIdentifier("settings-search-results")
    }

    private var topicList: some View {
        List(topics) { topic in
            NavigationLink {
                SettingsPage(title: topic.title) { page(topic.id) }
            } label: {
                Label {
                    Text(topic.title)
                } icon: {
                    Image(systemName: topic.symbol).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(topic.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .accessibilityIdentifier("settings-topic-" + topic.id)
        }
        .accessibilityIdentifier("settings-list")
    }

    @ViewBuilder private func page(_ id: String) -> some View {
        switch id {
        case "general":
            DefaultBrowserSection()
            GeneralSettingsSection()
            ProfileSettingsSection()
            StartPageSettingsSection()
            DownloadsSettingsSection()
        case "interface":
            PhoneInterfaceSection()
            AppearanceSettingsSection()
            TabsSettingsSection()
            GesturesSection()
            SiteZoomSection()
            GlobalStyleSection()
        case "privacy":
            PrivacySettingsSection()
            SensitiveLockSection()
            ClearOnQuitSection()
            SecurityEventsSection()
            PermissionActivitySection()
            SavedSignInsSection()
            PasswordsInfoSection()
            AddressesSection()
            SearchableCopySection()
            PageMemorySection()
        case "sync":
            SyncSection()
            BookmarkTransferSection()
            ImportExportSection()
            BackupSection()
            RecoverySection()
        case "performance":
            PerformanceSettingsSection()
            MediaCompatibilitySection()
            HealthCheckSection()
        case "extensions":
            ExtensionsSettingsSection()
            RemoteExtensionsSection()
            UserScriptsSection()
            SponsorBlockSection()
            WebAppsSection()
            EnhancementsSection()
        case "advanced":
            AdvancedSettingsSection()
        default:
            AboutSection()
        }
    }
}

/// One page of Settings, styled like the sheet it sits in (black behind the cards in the dark theme).
struct SettingsPage<Content: View>: View {
    @EnvironmentObject var model: BrowserModel
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollContentBackground(scheme == .dark ? .hidden : .automatic)
            .background(model.themeIsActive ? Color.clear : (scheme == .dark ? Color.black : Color.clear))
            .themedSurface()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
#else
struct SettingsView: View {
    var body: some View {
        Form {
            #if os(iOS)
            PhoneInterfaceSection()
            #endif
            DefaultBrowserSection()
            GeneralSettingsSection()
            ProfileSettingsSection()
            AppearanceSettingsSection()
            TabsSettingsSection()
            #if os(macOS)
            WorkspacesSettingsSection()
            FocusScheduleSection()
            #endif
            StartPageSettingsSection()
            PrivacySettingsSection()
            SensitiveLockSection()
            ClearOnQuitSection()
            GesturesSection()
            PageMemorySection()
            SearchableCopySection()
            SavedSignInsSection()
            PasswordsInfoSection()
            AddressesSection()
            SecurityEventsSection()
            PermissionActivitySection()
            SiteZoomSection()
            GlobalStyleSection()
            DownloadsSettingsSection()
            PerformanceSettingsSection()
            #if os(iOS)
            ExtensionsSettingsSection()
            RemoteExtensionsSection()
            UserScriptsSection()
            SponsorBlockSection()
            WebAppsSection()
            EnhancementsSection()
            #endif
            AdvancedSettingsSection()
            HealthCheckSection()
            MediaCompatibilitySection()
            BookmarkTransferSection()
            ImportExportSection()
            SyncSection()
            BackupSection()
            RecoverySection()
            AboutSection()
        }
        .formStyle(.grouped)
    }
}
#endif

/// On a Chrome Web Store page, one tap fetches that extension. It is offered like any other: its permissions are shown first.
struct WebStoreBanner: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if let id = model.storePageExtensionID {
            // The same pill as the rest of the browser: deep black, white text, a light along the top edge, a soft shadow.
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("Add this extension?").font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Button { model.addFromChromeWebStore(id: id) } label: {
                    Text(model.storeBusy ? "Adding…" : "Add")
                        .scaledFont(12, weight: .semibold).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 22)
                        .background(Capsule(style: .continuous).fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .disabled(model.storeBusy)
                .opacity(model.storeBusy ? 0.6 : 1)
                .accessibilityLabel("Add to Browser Setu")
                .accessibilityIdentifier("web-store-add")
            }
            .padding(.leading, 12).padding(.trailing, 4)
            .frame(height: 30)
            .environment(\.colorScheme, .dark)
            .background(Capsule(style: .continuous).fill(Obsidian.fill.opacity(0.96)))
            .overlay(Capsule(style: .continuous).strokeBorder(Obsidian.edge, lineWidth: 0.6).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.38), radius: 9, y: 3)
            .fixedSize()
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .alert("Extension", isPresented: Binding(get: { model.storeFailure != nil }, set: { if !$0 { model.storeFailure = nil } })) {
                Button("OK") { model.storeFailure = nil }
            } message: { Text(model.storeFailure ?? "") }
        }
    }
}

/// What an installed extension is allowed to do, one switch each. Turning one off takes effect at once and lasts until it is turned back on.
struct ExtensionPermissionsSheet: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    let info: ExtensionInfo
    @State private var rows: [ExtensionPermissionRow] = []
    @State private var access = ExtensionSiteAccess.specific
    @State private var history: [String] = []
    @State private var newSite = ""
    @State private var siteProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(info.name)” permissions").font(.headline)
            if rows.contains(where: \.isSite) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Website access").font(.subheadline.weight(.semibold))
                    Picker("Website access", selection: Binding(get: { access }, set: { mode in
                        model.extensionCenter.setSiteAccess(info.id, mode)
                        refresh()
                    })) { ForEach(ExtensionSiteAccess.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            if rows.isEmpty { Text("It holds no special permissions.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("What it can do", rows.filter { !$0.isSite })
                    section("Websites it can read and change", rows.filter(\.isSite))
                    if !history.isEmpty {
                        Text("Recent changes").font(.subheadline.weight(.semibold))
                        ForEach(history, id: \.self) { Text($0).settingsNote() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("A rule for one website").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("example.com or *.example.com", text: $newSite).textFieldStyle(.roundedBorder).onSubmit { addRule(allow: true) }
                    Button("Allow") { addRule(allow: true) }.disabled(newSite.isEmpty)
                    Button("Block") { addRule(allow: false) }.disabled(newSite.isEmpty)
                }
                if let siteProblem { Text(siteProblem).font(.caption).foregroundStyle(.red) }
            }
            Text("Turning something off can stop parts of the extension from working. It stays off until you turn it on again.")
                .settingsNote()
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 460, height: 480)
        .onAppear { refresh() }
    }

    private func addRule(allow: Bool) {
        if model.extensionCenter.addSiteRule(info.id, host: newSite, allow: allow) { newSite = ""; siteProblem = nil; refresh() }
        else { siteProblem = "Use a website name such as example.com." }
    }

    private func refresh() {
        rows = model.extensionCenter.permissionRows(info.id)
        access = model.extensionCenter.siteAccess(info.id)
        history = Array(model.extensionCenter.permissionHistory(info.id).prefix(8))
    }

    @ViewBuilder private func section(_ title: String, _ list: [ExtensionPermissionRow]) -> some View {
        if !list.isEmpty {
            Text(title).font(.subheadline.weight(.semibold))
            ForEach(list) { row in
                HStack {
                    Toggle(row.title, isOn: Binding(get: { row.granted }, set: { on in
                        model.extensionCenter.setPermission(info.id, key: row.key, isSite: row.isSite, granted: on)
                        refresh()
                    }))
                    if row.custom { Button(role: .destructive) { model.extensionCenter.removeSiteRule(info.id, key: row.key); refresh() } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless) }
                }
            }
        }
    }
}

/// Approval sheet for an extension fetched from the store, shown wherever the user is.
struct StoreOfferSheet: View {
    @EnvironmentObject var model: BrowserModel
    let info: ExtensionInfo

    var body: some View {
        ExtensionApprovalSheet(info: info) {
            Task {
                do { try await model.extensionCenter.installPending(token: info.approvalToken) }
                catch { model.storeFailure = error.localizedDescription }
            }
        }
    }
}

struct RecoveryBanner: View {
    @EnvironmentObject var model: BrowserModel
    @State private var confirm = false

    var body: some View {
        if let state = model.recovery {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(state.detail).font(.callout)
                Spacer(minLength: 8)
                Button("Start New Profile…") { confirm = true }
            }
            .padding(10)
            .background(.yellow.opacity(0.18))
            .accessibilityIdentifier("recovery-banner")
            .confirmationDialog("Start a new profile?", isPresented: $confirm) {
                Button("Move old data aside and start new", role: .destructive) { model.resetUnreadableProfile() }
            } message: {
                Text("Open tabs will close. Your unreadable data is kept in the app’s “recovered” folder, not deleted.")
            }
        }
    }
}


extension View {
    /// Sheets use the system search field. Inside the sidebar a system search field would add a native toolbar row to the
    /// window, so there it is a plain field above the list.
    @ViewBuilder func embeddedSearch(embedded: Bool, text: Binding<String>, prompt: String = "Search", accessory: AnyView? = nil, enterList: Binding<Int>? = nil) -> some View {
        if embedded {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField(prompt, text: text).textFieldStyle(.plain).font(.system(size: 13))
                        // ↓ in the field moves the keyboard into the list below it (the Library's rows are reached with the arrow keys).
                        .onKeyPress(.downArrow) { if let enterList { enterList.wrappedValue += 1; return .handled } else { return .ignored } }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                .padding(.horizontal, 12)
                if let accessory { accessory.padding(.horizontal, 12) }
                self
            }
        } else {
            self.searchable(text: text)
        }
    }
}

// MARK: - Health check

struct HealthCheckSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var items: [HealthItem] = []
    @State private var running = false

    var body: some View {
        Section("Health Check") {
            Button(running ? "Checking…" : "Run Health Check") {
                running = true
                Task {
                    items = await HealthCheck.run(model: model)
                    running = false
                }
            }
            .disabled(running)
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.status == .ok ? Color.green : (item.status == .warning ? Color.orange : Color.red))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(item.detail).settingsNote()
                    }
                }
            }
            Text("Everything is checked on this device. Nothing is uploaded.").settingsNote()
        }
    }
}

// MARK: - Website data

struct SiteDataSheet: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var sites: [SiteDataInfo] = []
    @State private var query = ""
    @State private var loading = true

    private var shown: [SiteDataInfo] {
        query.isEmpty ? sites : sites.filter { $0.host.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Website Data").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            TextField("Search sites", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal)
            if loading {
                ProgressView().padding(40)
            } else if shown.isEmpty {
                Text(sites.isEmpty ? "No website has stored data in this profile." : "No matching sites.")
                    .foregroundStyle(.secondary).padding(40)
            } else {
                List(shown) { site in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(site.host)
                            Text(site.kinds.joined(separator: ", ")).settingsNote()
                        }
                        Spacer()
                        Button("Remove") {
                            Task {
                                await model.removeSiteData(host: site.host)
                                await reload()
                            }
                        }
                    }
                }
            }
            Text("Removing a site signs you out of it and clears what it saved here. Your history and bookmarks are not touched.")
                .settingsNote().padding()
        }
        .frame(minWidth: 420, minHeight: 420)
        .task { await reload() }
    }

    private func reload() async {
        sites = await model.siteData()
        loading = false
    }
}


/// Extensions installed on the person's other devices, as a reminder: sync never installs an extension, because each one must be reviewed on the device that runs it.
struct RemoteExtensionsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        let mine = Set(model.extensionCenter.extensions.map(\.name))
        let others = model.remoteExtensions.sorted { $0.key < $1.key }.map { device, list in (device, list.filter { !mine.contains($0.name) }) }.filter { !$0.1.isEmpty }
        if !others.isEmpty {
            Section {
                ForEach(others, id: \.0) { device, list in
                    LabeledContent(device, value: list.map(\.name).joined(separator: ", "))
                }
            } header: { Text("On Your Other Devices") } footer: {
                Text("These extensions are installed on your other devices but not here. Sync never installs one for you: add it from its own page, so you review what it asks for on this device.")
            }
        }
    }
}
