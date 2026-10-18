import SwiftUI
import UniformTypeIdentifiers

/// A named set of tabs, saved to open again later.
struct SavedSession: Codable, Identifiable, Equatable {
    struct Tab: Codable, Equatable {
        var url: String; var title: String; var pinned: Bool
        /// How far down the page the person was (0...1), so it opens where they were.
        var scroll: Double? = nil
    }
    var id = UUID()
    var name: String
    var date = Date()
    var tabs: [Tab]
    /// How the window was arranged, and the two pages that were side by side (if any); both come back when the session is opened.
    var layout: LayoutSnapshot? = nil
    var split: [String]? = nil
    /// The workspace the tabs were in; opening the session goes back to it when it still exists.
    var workspace: String? = nil
}

extension BrowserModel {
    // MARK: Locking and sleeping

    func isLocked(_ tab: TabController) -> Bool { lockedTabIDs.contains(tab.id) }

    func toggleLock(_ tab: TabController) {
        var ids = lockedTabIDs
        if ids.contains(tab.id) { ids.remove(tab.id) } else { ids.insert(tab.id) }
        setLockedTabs(ids)
    }

    /// Releases a tab's page from memory now. It keeps its place, title and scroll position, and loads again when opened.
    func hibernate(_ tab: TabController) async {
        guard tab.id != activeID, !tab.isPrivate, !tab.isBlank, !tab.isDiscarded else { return }
        if await tab.engine.isBusy() { notice = "“\(tab.displayTitle)” is playing media or loading, so it was left awake."; return }
        guard tab.id != activeID else { return }
        tab.discard(reason: "you put it to sleep")
    }

    // MARK: Duplicates

    /// The address two tabs share when they show the same page: no fragment, no trailing slash, host in lower case.
    private func duplicateKey(_ tab: TabController) -> String? {
        guard !tab.isBlank, let url = tab.url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        parts.host = parts.host?.lowercased()
        var text = parts.string ?? url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return (tab.isPrivate ? "private|" : "") + text
    }

    /// Groups of tabs that show the same page (two or more in each).
    func duplicateGroups() -> [[TabController]] {
        var buckets: [String: [TabController]] = [:]
        for tab in tabs { if let key = duplicateKey(tab) { buckets[key, default: []].append(tab) } }
        return buckets.values.filter { $0.count > 1 }
    }

    /// How many other tabs show the same page as `tab`.
    func duplicateCount(of tab: TabController) -> Int {
        guard let key = duplicateKey(tab) else { return 0 }
        return tabs.filter { $0.id != tab.id && duplicateKey($0) == key }.count
    }

    /// Keeps one tab of each page (the one in front, a pinned or locked one, or the first) and closes the rest.
    @discardableResult
    func closeDuplicateTabs() -> Int {
        if duplicateGroups().reduce(0, { $0 + $1.count - 1 }) > 5 { takeCheckpoint(reason: "Before closing duplicates", force: true) }
        var closed = 0
        for group in duplicateGroups() {
            let keep = group.first { $0.id == activeID } ?? group.first { $0.pinned || lockedTabIDs.contains($0.id) } ?? group[0]
            for tab in group where tab.id != keep.id && !lockedTabIDs.contains(tab.id) && !tab.pinned {
                closeTab(id: tab.id); closed += 1
            }
        }
        notice = closed == 0 ? "No duplicate tabs." : "Closed \(closed) duplicate tab\(closed == 1 ? "" : "s")."
        return closed
    }

    func closeDuplicates(of tab: TabController) {
        guard let key = duplicateKey(tab) else { return }
        var closed = 0
        for other in tabs where other.id != tab.id && duplicateKey(other) == key && !lockedTabIDs.contains(other.id) && !other.pinned {
            closeTab(id: other.id); closed += 1
        }
        notice = closed == 0 ? "The other copies are pinned or locked." : "Closed \(closed) duplicate tab\(closed == 1 ? "" : "s")."
    }

    // MARK: Saved sessions

    /// Saves the tabs of this workspace (normal tabs only: private tabs are never written down).
    /// With `group`, saves only that group's tabs (and the groups inside it) as a collection.
    func saveSession(named name: String, group: String? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = tabs.filter { tab in !tab.isPrivate && !tab.isBlank && tab.workspace == activeWorkspace && (group.map { GroupPath.isInside(tab.group, of: $0) } ?? true) }
        guard !clean.isEmpty, clean.count <= 60, !list.isEmpty else { notice = "There are no tabs to save in this workspace."; return }
        var session = SavedSession(name: clean, tabs: list.compactMap { tab in
            tab.url.map { SavedSession.Tab(url: $0.absoluteString, title: tab.displayTitle, pinned: tab.pinned) }
        })
        session.layout = group == nil ? layoutSnapshot() : nil
        session.workspace = activeWorkspace
        if group == nil, let left = active?.url?.absoluteString, let right = splitTab?.url?.absoluteString { session.split = [left, right] }
        setSavedSessions(Array(([session] + savedSessions).prefix(50)))
        notice = "Saved “\(clean)” with \(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s")."
        // How far down each loaded page was is read afterwards, so saving is never held up by a page.
        let sessionID = session.id
        let readable = list
        Task { @MainActor [weak self] in
            var positions: [String: Double] = [:]
            for tab in readable where tab.hasLoadedPage && !tab.isDiscarded {
                if let url = tab.url?.absoluteString, let fraction = await tab.engine.scrollFraction(), PageMemoryRules.worthRemembering(fraction) { positions[url] = fraction }
            }
            guard let self, !positions.isEmpty, var saved = self.savedSessions.first(where: { $0.id == sessionID }) else { return }
            saved.tabs = saved.tabs.map { var t = $0; t.scroll = positions[t.url]; return t }
            self.setSavedSessions(self.savedSessions.map { $0.id == sessionID ? saved : $0 })
        }
    }

    /// Opens a saved session's tabs here, in the current workspace, and switches to the first.
    func openSession(_ session: SavedSession) {
        if let name = session.workspace, name != activeWorkspace, name.isEmpty || workspaces.contains(where: { $0.name == name }) { switchWorkspace(name) }
        var first: TabController?
        for item in session.tabs {
            guard let url = URL(string: item.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let tab = openTab(url: url, isPrivate: false, select: false)
            if let scroll = item.scroll, PageMemoryRules.worthRemembering(scroll) { sessionScroll[tab.id] = scroll }
            if item.pinned { togglePin(tab) }
            if first == nil { first = tab }
        }
        if let first { select(first.id) }
        if let layout = session.layout { apply(layout) }
        if let pair = session.split, pair.count == 2, let left = tabs.last(where: { $0.url?.absoluteString == pair[0] }), let right = tabs.last(where: { $0.url?.absoluteString == pair[1] }), left.id != right.id {
            select(left.id)
            openSplit(with: right)
        }
    }

    func deleteSession(_ session: SavedSession) { setSavedSessions(savedSessions.filter { $0.id != session.id }) }

    // MARK: Activity timeline

    /// The open tabs by when each was last in front: now, earlier today, yesterday, and older.
    func activityGroups(now: Date = Date()) -> [(title: String, tabs: [TabController])] {
        let calendar = Calendar.current
        let list = tabs.filter { !$0.isBlank && $0.isPrivate == activeIsPrivate }.sorted { $0.lastActive > $1.lastActive }
        var out: [(String, [TabController])] = []
        func add(_ title: String, _ pick: (TabController) -> Bool) {
            let items = list.filter(pick)
            if !items.isEmpty { out.append((title, items)) }
        }
        add("In use now") { $0.id == self.activeID || now.timeIntervalSince($0.lastActive) < 120 }
        add("Earlier today") { calendar.isDate($0.lastActive, inSameDayAs: now) && $0.id != self.activeID && now.timeIntervalSince($0.lastActive) >= 120 }
        add("Yesterday") { calendar.isDateInYesterday($0.lastActive) }
        add("Older") { !calendar.isDate($0.lastActive, inSameDayAs: now) && !calendar.isDateInYesterday($0.lastActive) }
        return out
    }
}

/// Saved sessions as a file, to move to another device or keep as a backup.
struct SessionsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var sessions: [SavedSession]
    init(sessions: [SavedSession]) { self.sessions = sessions }
    init(configuration: ReadConfiguration) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        sessions = (try? decoder.decode([SavedSession].self, from: configuration.file.regularFileContents ?? Data())) ?? []
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(sessions))
    }
}

extension BrowserModel {
    /// Adds sessions from a file. Only web addresses are kept, a session already here (same id) is skipped, and there is a limit.
    @discardableResult
    func importSessions(_ incoming: [SavedSession]) -> Int {
        var list = savedSessions
        var added = 0
        for var session in incoming where !list.contains(where: { $0.id == session.id }) {
            session.tabs = session.tabs.filter { URL(string: $0.url).map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil } ?? false }
            session.name = String(session.name.prefix(60))
            guard !session.tabs.isEmpty, !session.name.isEmpty else { continue }
            list.append(session); added += 1
        }
        setSavedSessions(Array(list.prefix(50)))
        return added
    }
}

/// Saved sessions: save this workspace's tabs under a name, open a set again, delete one.
struct SavedSessionsView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var importing = false

    var body: some View {
        List {
            Section {
                Button("Save These Tabs as a Session…") {
                    Task { @MainActor in
                        if let name = await Dialogs.promptText(title: "Save Session", message: "Name this set of tabs.", placeholder: "Research, Trip, Work…"), !name.isEmpty {
                            model.saveSession(named: name)
                        }
                    }
                }
                .disabled(model.tabs.allSatisfy { $0.isBlank || $0.isPrivate })
                Button("Export Sessions…") { exporting = true }.disabled(model.savedSessions.isEmpty)
                Button("Import Sessions…") { importing = true }
            } footer: {
                Text("Saves the open tabs of this workspace. Private tabs are never saved. Export makes a file you can open on another device.")
            }
            Section("Saved") {
                if model.savedSessions.isEmpty {
                    Label("No saved sessions yet", systemImage: "tray").foregroundStyle(.secondary)
                }
                ForEach(model.savedSessions) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name).fontWeight(.medium)
                            Text("\(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s") · \(session.date.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open") { model.openSession(session); model.sheet = nil; dismiss() }
                        Button(role: .destructive) { model.deleteSession(session) } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.borderless)
                    }
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: SessionsDocument(sessions: model.savedSessions), contentType: .json, defaultFilename: "Browser Setu Sessions") { result in
            if case .success = result { model.notice = "Sessions exported." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { model.notice = "That file could not be read."; return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let sessions = try? decoder.decode([SavedSession].self, from: data) else { model.notice = "That is not a Browser Setu sessions file."; return }
            let added = model.importSessions(sessions)
            model.notice = added == 0 ? "No new sessions in that file." : "Imported \(added) session\(added == 1 ? "" : "s")."
        }
        .accessibilityIdentifier("saved-sessions")
    }
}

/// Which tabs were used, and when.
struct TabActivityView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = model.activityGroups()
        List {
            if groups.isEmpty { Label("No tabs yet", systemImage: "clock").foregroundStyle(.secondary) }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.tabs) { tab in
                        Button {
                            if tab.workspace != model.activeWorkspace { model.switchWorkspace(tab.workspace) }
                            model.select(tab.id); model.sheet = nil; dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                SiteTile(url: tab.url?.absoluteString ?? "", title: tab.displayTitle, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tab.displayTitle).lineLimit(1)
                                    Text(displayHost(tab.url) + " · " + tab.lastActive.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if tab.isDiscarded { chip("Asleep", "moon.zzz") }
                                if tab.isLocked { chip("Locked", "lock.fill") }
                                if tab.pinned { chip("Pinned", "pin.fill") }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .accessibilityIdentifier("tab-activity")
    }

    private func chip(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption2).foregroundStyle(.secondary).labelStyle(.iconOnly).help(text)
    }
}
