import SwiftUI

// The Bookmarks, History and Downloads panels, rebuilt on PanelKit. The sidebar keeps its own compact lists (BookmarksView and HistoryView with `embedded`).

// MARK: - Bookmarks

struct BookmarksPanel: View {
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var items: [BookmarkItem] = []
    /// False until the first read, so the lists do not flash empty and then animate in.
    @State private var loaded = false
    @State private var filter: Filter = .all
    @State private var allCount = 0

    enum Filter: String, CaseIterable, Identifiable {
        case all, favorites, tagged
        var id: String { rawValue }
        var title: String { self == .all ? "All" : (self == .favorites ? "Favorites" : "Tagged") }
    }

    private var shown: [BookmarkItem] {
        switch filter {
        case .all: items
        case .favorites: items.filter { $0.folder == BrowserModel.favoritesFolder }
        case .tagged: items.filter { !model.tags(forBookmark: $0.url).isEmpty }
        }
    }

    private var folders: [(name: String, rows: [BookmarkItem])] {
        var order: [String] = [], buckets: [String: [BookmarkItem]] = [:]
        for b in shown {
            if buckets[b.folder] == nil { order.append(b.folder) }
            buckets[b.folder, default: []].append(b)
        }
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
        VStack(spacing: 0) {
            PanelHeader(symbol: "book", title: "Bookmarks", count: allCount, query: $query, prompt: "Search bookmarks and tags") { EmptyView() }
            PanelChips(choices: Filter.allCases, selection: $filter, title: { $0.title }, count: { count(for: $0) })
            if loaded && shown.isEmpty {
                PanelBody { PanelEmpty(symbol: "book", title: query.isEmpty ? "No bookmarks here" : "Nothing matches", detail: query.isEmpty ? "Press the star in the address bar, or ⌘D, to keep a page." : "Try a title, an address or a #tag.") }
            } else {
                PanelBody {
                    ForEach(folders, id: \.name) { folder in
                        PanelSection(title: folder.name.isEmpty ? "Unfiled" : folder.name, symbol: folder.name == BrowserModel.favoritesFolder ? "star.fill" : "folder", count: folder.rows.count) {
                            ForEach(folder.rows, id: \.url) { b in row(b, folders: folders.map(\.name)) }
                        }
                    }
                }
            }
        }
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private func count(for filter: Filter) -> Int {
        switch filter {
        case .all: items.count
        case .favorites: items.filter { $0.folder == BrowserModel.favoritesFolder }.count
        case .tagged: items.filter { !model.tags(forBookmark: $0.url).isEmpty }.count
        }
    }

    private func row(_ b: BookmarkItem, folders: [String]) -> some View {
        PanelRow(title: b.title.isEmpty ? b.url : b.title, detail: displayHost(URL(string: b.url)), tags: model.tags(forBookmark: b.url), action: { model.open(urlString: b.url) }) {
            SiteTile(url: b.url, title: b.title, size: 30)
        } trailing: {
            Menu {
                Button("Open in New Tab") { model.open(urlString: b.url, newTab: true) }
                Button("Edit…") { edit(b) }
                Button("Edit Tags…") { editTags(b) }
                Menu("Move to Folder") {
                    Button("Favorites") { move(b, to: BrowserModel.favoritesFolder) }
                    Button("No Folder") { move(b, to: "") }
                    ForEach(folders.filter { !$0.isEmpty && $0 != BrowserModel.favoritesFolder }, id: \.self) { f in Button(f) { move(b, to: f) } }
                    Divider()
                    Button("New Folder…") { newFolder(for: b) }
                }
                Divider()
                Button("Delete", role: .destructive) { remove(b) }
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More for \(b.title)")
        }
        .contextMenu {
            Button("Open in New Tab") { model.open(urlString: b.url, newTab: true) }
            Button("Edit…") { edit(b) }
            Button("Edit Tags…") { editTags(b) }
            Button("Delete", role: .destructive) { remove(b) }
        }
    }

    /// Matches in the title or address, and bookmarks whose tags match ("#work" or "work").
    private func reload() {
        var found = (try? model.core.listBookmarks(query: query)) ?? []
        let wanted = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
        if !wanted.isEmpty {
            let have = Set(found.map(\.url))
            found += ((try? model.core.listBookmarks(query: "")) ?? []).filter { !have.contains($0.url) && model.tags(forBookmark: $0.url).contains { $0.contains(wanted) } }
        }
        if loaded { animated(.easeOut(duration: 0.18)) { items = found } } else { items = found; loaded = true }
        if query.isEmpty { allCount = found.count } else { allCount = (try? model.core.listBookmarks(query: ""))?.count ?? found.count }
    }

    private func editTags(_ b: BookmarkItem) {
        let model = model
        Task { @MainActor in
            let current = model.tags(forBookmark: b.url).joined(separator: ", ")
            if let text = await Dialogs.promptText(title: "Tags", message: "Separate tags with commas. Search for a tag with #.", placeholder: current) { model.setTags(text, forBookmark: b.url); reload() }
        }
    }

    private func remove(_ b: BookmarkItem) { try? model.core.removeBookmark(url: b.url); model.refreshBookmarkState(); reload() }
    private func move(_ b: BookmarkItem, to folder: String) { try? model.core.addBookmark(url: b.url, title: b.title, folder: folder); reload() }

    private func edit(_ b: BookmarkItem) {
        Task { @MainActor in
            if let title = await Dialogs.promptText(title: "Edit Bookmark", message: b.url, placeholder: b.title) { try? model.core.addBookmark(url: b.url, title: title, folder: b.folder); reload() }
        }
    }

    private func newFolder(for b: BookmarkItem) {
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "New Folder", message: "Name the folder.", placeholder: ""), !name.isEmpty { move(b, to: name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }
}

// MARK: - History

struct HistoryPanel: View {
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var items: [HistoryItem] = []
    /// False until the first read, so the lists do not flash empty and then animate in.
    @State private var loaded = false
    @State private var range: Range = .all
    @State private var confirmClear = false

    enum Range: String, CaseIterable, Identifiable {
        case today, yesterday, week, all
        var id: String { rawValue }
        var title: String { switch self { case .today: "Today"; case .yesterday: "Yesterday"; case .week: "Last 7 Days"; case .all: "All" } }
    }

    private func inRange(_ item: HistoryItem, _ range: Range) -> Bool {
        let cal = Calendar.current, date = Date(timeIntervalSince1970: TimeInterval(item.lastVisit))
        switch range {
        case .all: return true
        case .today: return cal.isDateInToday(date)
        case .yesterday: return cal.isDateInYesterday(date)
        case .week: return date > Date().addingTimeInterval(-7 * 86_400)
        }
    }

    private var shown: [HistoryItem] { items.filter { inRange($0, range) } }

    private var sections: [(title: String, rows: [HistoryItem])] {
        let cal = Calendar.current
        var order: [Date] = [], buckets: [Date: [HistoryItem]] = [:]
        for h in shown {
            let day = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(h.lastVisit)))
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(h)
        }
        return order.map { day in
            let title = cal.isDateInToday(day) ? "Today" : (cal.isDateInYesterday(day) ? "Yesterday" : day.formatted(date: .complete, time: .omitted))
            return (title, buckets[day] ?? [])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(symbol: "clock", title: "History", count: items.count, query: $query, prompt: "Search history") {
                Menu {
                    Button("Clear the Last Hour") { clear { Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval($0.lastVisit))) < 3600 } }
                    Button("Clear Today") { clear { Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval($0.lastVisit))) } }
                    Divider()
                    Button("Clear All History…", role: .destructive) { confirmClear = true }
                } label: { Label("Clear", systemImage: "trash") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(items.isEmpty)
            }
            PanelChips(choices: Range.allCases, selection: $range, title: { $0.title }, count: { r in items.filter { inRange($0, r) }.count })
            if loaded && shown.isEmpty {
                PanelBody { PanelEmpty(symbol: "clock", title: query.isEmpty ? "No history" : "Nothing matches", detail: query.isEmpty ? "Pages you visit appear here, newest first. Private tabs are never listed." : "Try fewer words, or widen the range above.") }
            } else {
                PanelBody {
                    ForEach(sections, id: \.title) { section in
                        PanelSection(title: section.title, count: section.rows.count) {
                            ForEach(section.rows, id: \.url) { h in row(h) }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear All History", role: .destructive) { try? model.core.clearHistory(); reload() }
        } message: { Text("This removes every page from the list. It can't be undone.") }
        .onChange(of: query) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    private func row(_ h: HistoryItem) -> some View {
        let time = Date(timeIntervalSince1970: TimeInterval(h.lastVisit)).formatted(date: .omitted, time: .shortened)
        return PanelRow(title: h.title.isEmpty ? h.url : h.title, detail: displayHost(URL(string: h.url)), compact: true, action: { model.open(urlString: h.url) }) {
            SiteTile(url: h.url, title: h.title, size: 20)
        } trailing: {
            HStack(spacing: 8) {
                Text(time).font(.system(size: 11.5)).foregroundStyle(.tertiary).monospacedDigit()
                Button { remove(h) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 22, height: 22).contentShape(Circle()) }
                    .buttonStyle(.plain).help("Remove from history").accessibilityLabel("Remove \(h.title) from history")
            }
        }
        .contextMenu {
            Button("Open in New Tab") { model.open(urlString: h.url, newTab: true) }
            Button("Delete", role: .destructive) { remove(h) }
        }
    }

    private func reload() {
        let found = (query.isEmpty ? try? model.core.recentHistory(limit: 400) : try? model.core.searchHistory(query: query, limit: 400)) ?? []
        if loaded { animated(.easeOut(duration: 0.18)) { items = found } } else { items = found; loaded = true }
    }

    private func remove(_ h: HistoryItem) { try? model.core.deleteHistoryEntry(url: h.url); reload() }

    private func clear(where matches: (HistoryItem) -> Bool) {
        for item in items where matches(item) { try? model.core.deleteHistoryEntry(url: item.url) }
        reload()
    }
}

// MARK: - Downloads

struct DownloadsPanel: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: DownloadCoordinator
    @State private var query = ""
    @State private var items: [DownloadItem] = []
    /// False until the first read, so the lists do not flash empty and then animate in.
    @State private var loaded = false
    @State private var kind: Kind = .all

    enum Kind: String, CaseIterable, Identifiable {
        case all, documents, images, media, archives, apps
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .all: "doc"
            case .documents: "doc.text"
            case .images: "photo"
            case .media: "play.rectangle"
            case .archives: "archivebox"
            case .apps: "app.gift"
            }
        }

        static func of(_ filename: String) -> Kind {
            switch (filename as NSString).pathExtension.lowercased() {
            case "pdf", "doc", "docx", "txt", "rtf", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv", "md", "epub", "html": .documents
            case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp": .images
            case "mp3", "m4a", "wav", "flac", "mp4", "mov", "mkv", "avi", "webm", "m4v": .media
            case "zip", "gz", "tar", "tgz", "7z", "rar", "dmg", "iso": .archives
            case "pkg", "app", "ipa", "exe", "msi", "apk": .apps
            default: .all
            }
        }
    }

    private var shown: [DownloadItem] {
        items.filter { item in
            (kind == .all || Kind.of(item.filename) == kind) && (query.isEmpty || item.filename.localizedCaseInsensitiveContains(query) || item.url.localizedCaseInsensitiveContains(query))
        }
    }

    private var busy: Bool { !coordinator.active.isEmpty || !coordinator.interrupted.isEmpty || !coordinator.waiting.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(symbol: "arrow.down.circle", title: "Downloads", count: items.count + coordinator.active.count, query: $query, prompt: "Search downloads") {
                Button { copyToPasteboard(coordinator.diagnostics); model.notice = "Download diagnostics copied." } label: { Image(systemName: "stethoscope").accessibilityLabel("Copy download diagnostics") }
                    .buttonStyle(.borderless).help("Copy Download Diagnostics").fixedSize()
                Button(role: .destructive) { try? model.core.clearDownloads(); coordinator.clearCompleted(); reload() } label: { Image(systemName: "trash").accessibilityLabel("Clear completed downloads") }
                    .buttonStyle(.borderless).help("Clear Completed").disabled(items.isEmpty).fixedSize()
            }
            PanelChips(choices: Kind.allCases, selection: $kind, title: { $0.title }, count: { k in k == .all ? items.count : items.filter { Kind.of($0.filename) == k }.count })
            if loaded && !busy && shown.isEmpty {
                PanelBody { PanelEmpty(symbol: "arrow.down.circle", title: query.isEmpty && kind == .all ? "No downloads" : "Nothing matches", detail: "Files you download appear here, with progress while they come in.") }
            } else {
                PanelBody {
                    if busy { queueBar }
                    if !coordinator.active.isEmpty {
                        PanelSection(title: "In Progress", symbol: "arrow.down.circle.fill", count: coordinator.active.count, collapsible: false) {
                            ForEach(Array(coordinator.active.values)) { d in active(d) }
                        }
                    }
                    if !coordinator.interrupted.isEmpty {
                        PanelSection(title: "Interrupted", symbol: "exclamationmark.arrow.circlepath", count: coordinator.interrupted.count) {
                            ForEach(Array(coordinator.interrupted.values)) { d in interrupted(d) }
                        }
                    }
                    if !shown.isEmpty {
                        PanelSection(title: "Completed", symbol: "checkmark.circle", count: shown.count) {
                            ForEach(shown, id: \.created) { d in completed(d) }
                        }
                    }
                }
            }
        }
        .onChange(of: coordinator.completed) { _, _ in reload() }
        .onAppear(perform: reload)
    }

    /// Pause, resume and hold the whole queue.
    private var queueBar: some View {
        let held = DownloadSchedule.isHeld(until: coordinator.heldUntil)
        return HStack(spacing: 10) {
            Image(systemName: held ? "pause.circle.fill" : "arrow.down.circle").foregroundStyle(Theme.accent)
            Text(held ? (coordinator.heldUntil == .distantFuture ? "Queue held until you resume" : "Queue held until \(coordinator.heldUntil.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")") : "Queue running")
                .font(.system(size: 12.5, weight: .medium))
            Spacer()
            if held { Button("Resume All") { coordinator.resumeAll() } } else { Button("Pause All") { coordinator.pauseAll() } }
            Menu("Hold Until…") {
                Button("In an hour") { coordinator.holdQueue(until: Date().addingTimeInterval(3600)) }
                Button("2:00 at night") { if let t = DownloadSchedule.nextOccurrence(hour: 2, minute: 0) { coordinator.holdQueue(until: t) } }
                Button("7:00 in the morning") { if let t = DownloadSchedule.nextOccurrence(hour: 7, minute: 0) { coordinator.holdQueue(until: t) } }
                Divider()
                Button("Until I resume") { coordinator.holdQueue(until: .distantFuture) }
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless).font(.system(size: 12))
        .padding(.horizontal, 14).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.10)))
        .padding(.horizontal, 20)
    }

    private func fileIcon(_ filename: String) -> some View {
        Image(systemName: Kind.of(filename).symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent)
            .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.14)))
    }

    private func active(_ d: ActiveDownload) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: max(0.02, d.fraction)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: d.fraction)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.filename).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                ProgressView(value: d.fraction).tint(Theme.accent)
                Text(d.detail.isEmpty ? "\(Int(d.fraction * 100))%" : "\(Int(d.fraction * 100))% · \(d.detail)").font(.system(size: 11.5)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Button("Cancel") { coordinator.cancel(d.id) }.buttonStyle(.borderless).font(.system(size: 12))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func interrupted(_ d: InterruptedDownload) -> some View {
        HStack(spacing: 12) {
            fileIcon(d.filename)
            VStack(alignment: .leading, spacing: 2) {
                Text(d.filename).font(.system(size: 13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text("Stopped part-way. Resuming works if the website allows it.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Resume") { coordinator.resume(d.id) }.buttonStyle(.borderedProminent).controlSize(.small)
            Button("Remove") { coordinator.dismissInterrupted(d.id) }.buttonStyle(.borderless).font(.system(size: 12))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func completed(_ d: DownloadItem) -> some View {
        let date = Date(timeIntervalSince1970: TimeInterval(d.created)).formatted(date: .abbreviated, time: .shortened)
        return PanelRow(title: d.filename, detail: displayHost(URL(string: d.url)) + " · " + date, action: nil) {
            fileIcon(d.filename)
        } trailing: {
            if let file = DownloadCoordinator.locate(filename: d.filename) { DownloadFileActions(url: file) }
            else { Text("Moved or deleted").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }

    private func reload() {
        let found = (try? model.core.listDownloads(limit: 200)) ?? []
        if loaded { animated(.easeOut(duration: 0.18)) { items = found } } else { items = found; loaded = true }
    }
}
