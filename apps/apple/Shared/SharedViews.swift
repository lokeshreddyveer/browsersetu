import SwiftUI
import UniformTypeIdentifiers

extension Color {
    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

struct SheetContainer: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.colorScheme) private var scheme
    let sheet: Sheet

    var body: some View {
        NavigationStack {
            Group {
                switch sheet {
                case .bookmarks: BookmarksView()
                case .history: HistoryView()
                case .downloads: DownloadsView()
                case .settings: SettingsView()
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
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // Escape closes the sheet as well as the button.
                    Button("Done") { model.sheet = nil }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("sheet-done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 460)
        #endif
    }

    private var title: String {
        switch sheet {
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .downloads: "Downloads"
        case .settings: "Settings"
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
    @EnvironmentObject var model: BrowserModel
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
        List {
            ForEach(folders, id: \.name) { folder in
                Section(folder.name.isEmpty ? "Bookmarks" : folder.name) {
                    ForEach(folder.rows, id: \.url) { b in
                        Button { model.open(urlString: b.url) } label: {
                            VStack(alignment: .leading) {
                                Text(b.title.isEmpty ? b.url : b.title).lineLimit(1)
                                Text(b.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .embeddedSearch(embedded: embedded, text: $query)
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

struct HistoryView: View {
    var embedded = false
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
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.url) { h in
                        Button { model.open(urlString: h.url) } label: {
                            VStack(alignment: .leading) {
                                Text(h.title.isEmpty ? h.url : h.title).lineLimit(1)
                                Text(displayHost(URL(string: h.url))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
        .embeddedSearch(embedded: embedded, text: $query)
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

struct DownloadsView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        DownloadsList(coordinator: model.downloads)
    }
}

private struct DownloadsList: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: DownloadCoordinator
    @State private var items: [DownloadItem] = []

    var body: some View {
        List {
            DownloadQueueControls(coordinator: coordinator)
            if !coordinator.active.isEmpty {
                Section("In Progress") {
                    ForEach(Array(coordinator.active.values)) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.filename)
                                ProgressView(value: d.fraction)
                                Text("\(Int(d.fraction * 100))%").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Cancel") { coordinator.cancel(d.id) }
                        }
                    }
                }
            }
            if !coordinator.interrupted.isEmpty {
                Section("Interrupted") {
                    ForEach(Array(coordinator.interrupted.values)) { d in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.filename)
                                Text("Stopped part-way. Resuming works if the website allows it.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") { coordinator.resume(d.id) }
                            Button("Remove") { coordinator.dismissInterrupted(d.id) }
                        }
                    }
                }
            }
            Section("Completed") {
                ForEach(items, id: \.created) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.filename)
                            Text(d.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        // Preview, share and show-in-Finder, for files that are still where they were saved.
                        if let file = DownloadCoordinator.locate(filename: d.filename) { DownloadFileActions(url: file) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button("Clear Completed", role: .destructive) {
                    try? model.core.clearDownloads()
                    coordinator.clearCompleted()
                    reload()
                }
                .disabled(items.isEmpty)
            }
        }
        .overlay { if items.isEmpty && coordinator.active.isEmpty && coordinator.interrupted.isEmpty { ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle") } }
        .onChange(of: coordinator.completed) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private func reload() { items = (try? model.core.listDownloads(limit: 200)) ?? [] }
}

// MARK: - Settings sections

struct GeneralSettingsSection: View {
    var body: some View {
        Group {
            StartupSettingsSection()
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
                        Image(systemName: name == model.profileName ? "person.crop.circle.fill" : "person.crop.circle")
                            .font(.system(size: 20)).foregroundStyle(name == model.profileName ? Theme.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name == "default" ? "Default" : name).fontWeight(.medium)
                            Text(name == model.profileName ? "In use" : "Separate cookies, history and bookmarks").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if name != model.profileName { Button("Switch") { model.switchProfile(name) } }
                        if name != model.profileName && name != "default" {
                            Button(role: .destructive) { Task { if await model.requireAuthentication("Delete a profile and its data") { await model.removeProfile(name) } } } label: { Image(systemName: "trash") }
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
            } footer: {
                Text("A profile keeps its own cookies, history, bookmarks and permissions. Workspaces only organise tabs and share their profile's data.")
            }
        }
    }
}

struct AppearanceSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            Section("Appearance") {
                Picker("Theme", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Websites look", selection: $model.websiteAppearance) {
                    Text("Follow System").tag(AppearanceMode.system)
                    Text("Light").tag(AppearanceMode.light)
                    Text("Dark").tag(AppearanceMode.dark)
                }
                Text("Which look websites are asked for. Theme above only changes the browser. “Follow System” lets each site choose its own design, light or dark.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Accent", selection: $model.accent) {
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
                    .font(.caption).foregroundStyle(.secondary)
            }
            ThemesSection()
            #if os(macOS)
            Section("Layout") {
                Picker("Preset", selection: $model.layoutPreset) {
                    ForEach(LayoutPreset.allCases) { Text($0.title).tag($0) }
                }
                Text(model.layoutPreset.summary).font(.caption).foregroundStyle(.secondary)
                Toggle("Tint the toolbar with the page’s colour", isOn: $model.tintToolbar)
                Toggle("Fold the toolbar and tabs into a pill while reading", isOn: $model.collapseOnScroll)
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
                }
                Picker("Sidebar position", selection: $model.sidebarPosition) {
                    ForEach(SidebarPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Collapse sidebar to icons", isOn: $model.sidebarRail)
                Toggle("Hide sidebar until the pointer touches the window edge", isOn: Binding(
                    get: { model.sidebarAutoHide }, set: { on in model.sidebarAutoHide = on; if on { model.sidebarVisible = false } else { model.sidebarVisible = true } }))
                HStack {
                    Text("Sidebar width")
                    Slider(value: $model.sidebarWidth, in: sidebarWidthRange, step: 10)
                    Text("\(Int(model.sidebarWidth))").monospacedDigit().foregroundStyle(.secondary)
                }
                .disabled(model.sidebarRail)
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
                ForEach(ToolbarItemID.allCases) { item in
                    #if os(iOS)
                    if item != .sidebar { toolbarToggle(item) }
                    #else
                    toolbarToggle(item)
                    #endif
                }
            }
            Section {
                Button("Reset Appearance and Layout") {
                    model.appearance = .system; model.accent = .teal; model.density = .comfortable
                    model.layoutPreset = .classic; model.tabLayout = .separate; model.sidebarPosition = .left
                    model.sidebarWidth = 250; model.sidebarRail = false; model.addressBarPosition = .bottom
                    model.toolbarItems = ToolbarItemID.defaults
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
                Text("Previews are captured only when you leave a tab or open the overview, and are kept in memory only.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tab Groups") {
                if model.groupNames.isEmpty { Text("No tab groups").foregroundStyle(.secondary) }
                ForEach(model.groupNames, id: \.self) { name in
                    HStack { Label(name, systemImage: "folder"); Spacer()
                        Button("Delete", role: .destructive) { model.deleteGroup(name) } }
                }
                Button("New Group…") { promptNewGroup(model: model) }
            }
        }
    }
}

struct WorkspacesSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section("Workspaces") {
            HStack {
                Label("Personal", systemImage: "person")
                Spacer()
                Text("\(model.workspaceTabCount(""))").foregroundStyle(.secondary)
            }
            ForEach(model.workspaces) { ws in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Menu {
                            ForEach(Workspace.iconChoices, id: \.self) { icon in
                                Button { model.setWorkspaceIcon(ws.name, icon: icon) } label: { Label(icon, systemImage: icon) }
                            }
                        } label: { Image(systemName: ws.icon).foregroundStyle(Theme.accent) }
                            .menuStyle(.borderlessButton).fixedSize()
                        Text(ws.name)
                        Spacer()
                        Text("\(model.workspaceTabCount(ws.name))").foregroundStyle(.secondary)
                        Button { model.moveWorkspace(ws.name, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless)
                        Button { model.moveWorkspace(ws.name, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                        Button("Rename") { rename(ws.name) }.buttonStyle(.borderless)
                        Button("Delete", role: .destructive) { model.deleteWorkspace(ws.name) }.buttonStyle(.borderless)
                    }
                    Picker("Accent colour", selection: Binding(
                        get: { ws.accent.flatMap(AccentChoice.init(rawValue:)) },
                        set: { model.setWorkspaceAccent(ws.name, accent: $0) })) {
                        Text("Same as everywhere").tag(AccentChoice?.none)
                        ForEach(AccentChoice.allCases) { Text($0.title).tag(AccentChoice?.some($0)) }
                    }
                    #if os(macOS)
                    Picker("Layout", selection: Binding(
                        get: { ws.preset.flatMap(LayoutPreset.init(rawValue:)) },
                        set: { model.setWorkspacePreset(ws.name, preset: $0) })) {
                        Text("Keep current").tag(LayoutPreset?.none)
                        ForEach(LayoutPreset.allCases) { Text($0.title).tag(LayoutPreset?.some($0)) }
                    }
                    #endif
                }
            }
            Button("New Workspace…") { promptNewWorkspaceShared() }
            Text("Deleting a workspace keeps its tabs; they move to Personal.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func rename(_ old: String) {
        let model = model
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "Rename Workspace", message: "New name for “\(old)”.", placeholder: old), !name.isEmpty {
                model.renameWorkspace(old, to: name)
            }
        }
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
            Text("Everything on this page comes from this device. Nothing is sent anywhere.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PrivacySettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            VayuProtectionSection(privacy: model.privacy)
            SecurityFactsSection()
            LinkCleaningSection()
            SiteIconsSection()
            ThreatListSection()
            ProxySection()
            SitePermissionsSection()
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
                if !model.extensionCenter.isSupported {
                    Text(unsupportedText).foregroundStyle(.secondary)
                } else if model.extensionCenter.extensions.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "puzzlepiece.extension").font(.system(size: 26)).foregroundStyle(.tertiary)
                        Text("No extensions installed").fontWeight(.medium)
                        Text(model.extensionCenter.canInstall ? "Add an extension from a folder or file, or from its Chrome Web Store page." : "Extensions are added on a Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                ForEach(model.extensionCenter.extensions) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).fontWeight(.medium)
                                if !item.version.isEmpty { Text("Version \(item.version)").font(.caption).foregroundStyle(.secondary) }
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
                    .font(.caption).foregroundStyle(.secondary)
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
            if info.manifestVersion > 0 { Text("Manifest V\(info.manifestVersion) extension").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
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
        Section("Downloads") {
            LabeledContent("Saved to", value: DownloadCoordinator.directory.path)
            Picker("Downloads at a time", selection: $model.maxDownloads) { ForEach(DownloadQueueRules.maxConcurrentChoices, id: \.self) { Text("\($0)").tag($0) } }
            Text("The rest wait their turn, and you can move one to the front. WebKit has no way to limit a download's speed, so there is no bandwidth limit.").font(.caption).foregroundStyle(.secondary)
            Toggle("Sort downloads into folders by kind", isOn: $model.organizeDownloads)
            if model.organizeDownloads {
                Text("New downloads go into Images, Documents, Archives, Audio, Video, Installers or Other inside that folder.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Files are never opened automatically. Name conflicts get a numbered suffix; nothing is overwritten.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Clear Download History") {
                try? model.core.clearDownloads()
                model.downloads.clearCompleted()
            }
        }
    }
}

struct PerformanceSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            MemorySettingsSection()
            ResourceMonitorSection()
            Section("Split View") {
                Text(model.splitTabID == nil ? "Split view is closed." : "Split view keeps two pages live at once, which uses more memory.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct KeyboardSettingsSection: View {
    private let shortcuts: [(String, String)] = [
        ("New Tab", "⌘T"), ("Close Tab", "⌘W"), ("Reopen Closed Tab", "⇧⌘T"), ("New Private Tab", "⇧⌘N"),
        ("Open Location", "⌘L"), ("Command Palette", "⌘K"), ("Find in Page", "⌘F"), ("Bookmark Page", "⌘D"),
        ("Toggle Sidebar", "⇧⌘L"), ("Tab Overview", "⇧⌘\\"), ("Select Tab 1–9", "⌘1–9"), ("Switch Workspace", "⌃1–9"),
        ("Focus Mode", "⌥⌘F"), ("Paste and Go", "⇧⌘V"),
    ]
    var body: some View {
        Section("Shortcuts") {
            ForEach(shortcuts, id: \.0) { LabeledContent($0.0, value: $0.1) }
        }
    }
}

struct AdvancedSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Section("Diagnostics") {
            LabeledContent("Engine", value: model.engine.name)
            LabeledContent("Profile", value: model.profileName)
            Text("Diagnostics stay on this device. Nothing is collected or sent.").font(.caption).foregroundStyle(.secondary)
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
                        Text(title(forTopic: entry.phone)).font(.caption).foregroundStyle(.secondary)
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
        case "privacy":
            PrivacySettingsSection()
            SensitiveLockSection()
            ClearOnQuitSection()
            PermissionActivitySection()
            SavedSignInsSection()
            PasswordsInfoSection()
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
            PermissionActivitySection()
            SiteZoomSection()
            DownloadsSettingsSection()
            PerformanceSettingsSection()
            #if os(iOS)
            ExtensionsSettingsSection()
            RemoteExtensionsSection()
            UserScriptsSection()
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
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
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
                        ForEach(history, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
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
                .font(.caption).foregroundStyle(.secondary)
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
                    if row.custom { Button(role: .destructive) { model.extensionCenter.removeSiteRule(info.id, key: row.key); refresh() } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
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
    @ViewBuilder func embeddedSearch(embedded: Bool, text: Binding<String>) -> some View {
        if embedded {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search", text: text).textFieldStyle(.plain).font(.system(size: 12.5))
                }
                .padding(.horizontal, 9).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
                .padding(.horizontal, 10)
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
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Everything is checked on this device. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
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
                            Text(site.kinds.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
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
                .font(.caption).foregroundStyle(.secondary).padding()
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


/// Pause and resume everything, hold the queue until a time, and the downloads that are waiting or put off for later. Used at the top of every downloads list.
struct DownloadQueueControls: View {
    @ObservedObject var coordinator: DownloadCoordinator

    private var held: Bool { DownloadSchedule.isHeld(until: coordinator.heldUntil) }
    private var hasWork: Bool { !coordinator.active.isEmpty || !coordinator.waiting.isEmpty || !coordinator.interrupted.isEmpty || !coordinator.scheduled.isEmpty }

    var body: some View {
        if hasWork || held {
            Section {
                HStack {
                    if held { Button("Resume All") { coordinator.resumeAll() } } else { Button("Pause All") { coordinator.pauseAll() } }
                    Menu("Hold Until…") {
                        Button("In an hour") { coordinator.holdQueue(until: Date().addingTimeInterval(3600)) }
                        ForEach([(2, "2:00 at night"), (7, "7:00 in the morning"), (22, "10:00 in the evening")], id: \.0) { hour, label in
                            Button(label) { if let t = DownloadSchedule.nextOccurrence(hour: hour, minute: 0) { coordinator.holdQueue(until: t) } }
                        }
                        Divider()
                        Button("Until I resume") { coordinator.holdQueue(until: .distantFuture) }
                    }
                    Spacer()
                }
                if held {
                    Label(coordinator.heldUntil == .distantFuture ? "Downloads are held until you resume them." : "Downloads are held until \(coordinator.heldUntil.map { $0.formatted(date: .omitted, time: .shortened) } ?? "").",
                          systemImage: "pause.circle").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(coordinator.waiting) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.filename).lineLimit(1); Text("Waiting for a free place").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Menu(item.priority.title) {
                            ForEach(DownloadPriority.allCases.reversed()) { p in Button(p.title) { coordinator.setPriority(item.id, p) } }
                        }.fixedSize()
                        Button(role: .destructive) { coordinator.cancelWaiting(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
                ForEach(coordinator.scheduled) { item in
                    HStack {
                        VStack(alignment: .leading) { Text(item.filename).lineLimit(1); Text("Starts when the hold ends").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button(role: .destructive) { coordinator.removeScheduled(item.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    }
                }
                if !held, !coordinator.scheduled.isEmpty { Button("Start Them Now") { coordinator.startScheduledNow() } }
            } header: { Text("Queue") }
        }
    }
}
