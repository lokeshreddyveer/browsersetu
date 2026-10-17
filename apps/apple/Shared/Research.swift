import SwiftUI

// MARK: - What is kept

/// Where a page came from, in the form a paper or a note needs: its title, address, author, the date it was published and the date it was read.
struct Citation: Codable, Equatable {
    var title: String
    var url: String
    var author: String?
    /// As the site gave it ("2026-03-04T10:00:00Z" or "March 4, 2026"); shown as a date when it can be read as one.
    var published: String?
    var site: String?
    var accessed: Date

    private static let day: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMMM yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// The published date as "4 March 2026", or the text as given when it cannot be read as a date.
    var publishedText: String? {
        guard let published, !published.isEmpty else { return nil }
        if let date = Self.iso.date(from: String(published.prefix(10))) { return Self.day.string(from: date) }
        return published
    }

    /// "Author. “Title.” Site, 4 March 2026. https://… (accessed 16 October 2026)."
    var plain: String {
        var parts: [String] = []
        if let author, !author.isEmpty { parts.append(author + ".") }
        parts.append("“\(title).”")
        let site = [self.site, publishedText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        if !site.isEmpty { parts.append(site + ".") }
        parts.append(url)
        parts.append("(accessed \(Self.day.string(from: accessed))).")
        return parts.joined(separator: " ")
    }

    var markdown: String {
        var line = "[\(title.replacingOccurrences(of: "]", with: "\\]"))](\(url))"
        let by = [author, site, publishedText].compactMap { $0 }.filter { !$0.isEmpty }
        if !by.isEmpty { line += " — " + by.joined(separator: ", ") }
        return line + " (accessed \(Self.day.string(from: accessed)))"
    }
}

struct ResearchItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case page, highlight, note, pdf }
    var id = UUID()
    var kind: Kind
    var title: String
    var url: String?
    /// The highlighted passage, or the note.
    var text: String?
    var citation: Citation?
    var added = Date()
    /// A saved copy of the page as a PDF, kept in this profile's research folder (a file name, never a path).
    var file: String? = nil
    /// Your own words about the passage in `text`.
    var comment: String? = nil
    /// How far down the page the passage was (0...1).
    var place: Double? = nil
}

struct ResearchCollection: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var items: [ResearchItem] = []
}

/// The collections, kept in one file inside this profile's folder. Nothing here leaves the device.
@MainActor
final class ResearchStore: ObservableObject {
    static let maxItems = 500
    static let maxText = 20_000
    static let maxCollections = 100

    @Published private(set) var collections: [ResearchCollection] = []
    /// Where the quick "add to research" buttons put things.
    @Published var currentID: UUID?
    private let fileURL: URL
    let filesFolder: URL
    static let maxFileBytes = 60 * 1024 * 1024

    init(folder: URL) {
        filesFolder = folder.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("collections.json")
        if let data = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([ResearchCollection].self, from: data) { collections = list }
        currentID = collections.first?.id
    }

    var current: ResearchCollection? { collections.first { $0.id == currentID } ?? collections.first }

    /// The saved copy of an item, if it has one and the file is still there. The name is checked so a damaged or hostile list cannot point outside the folder.
    func savedFile(for item: ResearchItem) -> URL? {
        guard let name = item.file, name == (name as NSString).lastPathComponent, !name.hasPrefix("."), name.hasSuffix(".pdf") else { return nil }
        let url = filesFolder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes a page's PDF and returns the file name to put in the item, or nil when it is too big or cannot be written.
    func saveFile(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= Self.maxFileBytes else { return nil }
        try? FileManager.default.createDirectory(at: filesFolder, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".pdf"
        do { try data.write(to: filesFolder.appendingPathComponent(name), options: .atomic); return name } catch { return nil }
    }

    private func removeFiles(of items: [ResearchItem]) {
        for item in items { if let url = savedFile(for: item) { try? FileManager.default.removeItem(at: url) } }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(collections) { try? data.write(to: fileURL, options: .atomic) }
    }

    @discardableResult
    func create(name: String) -> ResearchCollection? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, collections.count < Self.maxCollections else { return nil }
        let collection = ResearchCollection(name: clean)
        collections.append(collection)
        currentID = collection.id
        save()
        return collection
    }

    /// Collections from a backup: ones already here (same id) are left alone, new ones are added, within the same limits.
    @discardableResult
    func merge(_ incoming: [ResearchCollection]) -> Int {
        var added = 0
        for var collection in incoming where !collections.contains(where: { $0.id == collection.id }) && collections.count < Self.maxCollections {
            collection.name = String(collection.name.prefix(60))
            collection.items = Array(collection.items.prefix(Self.maxItems)).map { var i = $0; i.text = i.text.map { String($0.prefix(Self.maxText)) }; return i }
            collections.append(collection); added += 1
        }
        if added > 0 { save() }
        return added
    }

    func rename(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 60, let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].name = clean
        save()
    }

    func delete(_ id: UUID) {
        removeFiles(of: collections.first { $0.id == id }?.items ?? [])
        collections.removeAll { $0.id == id }
        if currentID == id { currentID = collections.first?.id }
        save()
    }

    /// Adds an item. A page already in the collection is updated instead of listed twice; text is cut to a sensible length.
    @discardableResult
    func add(_ item: ResearchItem, to id: UUID) -> Bool {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return false }
        var item = item
        if let text = item.text { item.text = String(text.prefix(Self.maxText)) }
        if item.kind == .page || item.kind == .pdf, let url = item.url,
           let existing = collections[index].items.firstIndex(where: { ($0.kind == .page || $0.kind == .pdf) && $0.url == url }) {
            item.id = collections[index].items[existing].id
            collections[index].items[existing] = item
        } else {
            guard collections[index].items.count < Self.maxItems else { return false }
            collections[index].items.append(item)
        }
        save()
        return true
    }

    func remove(_ itemID: UUID, from id: UUID) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(of: collections[index].items.filter { $0.id == itemID })
        collections[index].items.removeAll { $0.id == itemID }
        save()
    }

    func removeAll() { collections = []; currentID = nil; save() }

    /// Every item of every collection, newest first, with the day heading it belongs under: the research timeline.
    func timeline(calendar: Calendar = .current) -> [(day: Date, items: [(collection: String, item: ResearchItem)])] {
        let all = collections.flatMap { c in c.items.map { (collection: c.name, item: $0) } }.sorted { $0.item.added > $1.item.added }
        let grouped = Dictionary(grouping: all) { calendar.startOfDay(for: $0.item.added) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }
}

// MARK: - Export

enum ResearchExport {
    private static func heading(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "d MMMM yyyy"; f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }

    static func markdown(_ collection: ResearchCollection, now: Date = Date()) -> String {
        var out = "# \(collection.name)\n\n_Exported \(heading(now)) from Browser Setu_\n"
        let pages = collection.items.filter { $0.kind == .page || $0.kind == .pdf }
        let highlights = collection.items.filter { $0.kind == .highlight }
        let notes = collection.items.filter { $0.kind == .note }
        if !pages.isEmpty {
            out += "\n## Pages\n\n"
            for (index, item) in pages.enumerated() {
                out += "\(index + 1). " + (item.citation?.markdown ?? "[\(item.title)](\(item.url ?? ""))") + (item.kind == .pdf ? " (PDF)" : "") + "\n"
                if let note = item.text, !note.isEmpty { out += "   > " + note.replacingOccurrences(of: "\n", with: "\n   > ") + "\n" }
            }
        }
        if !highlights.isEmpty {
            out += "\n## Highlights\n\n"
            for item in highlights {
                out += "> " + (item.text ?? "").replacingOccurrences(of: "\n", with: "\n> ") + "\n"
                if let url = item.url { out += ">\n> — [\(item.title)](\(url))\n" }
                out += "\n"
            }
        }
        if !notes.isEmpty {
            out += "\n## Notes\n\n"
            for item in notes { out += "### \(item.title)\n\n\(item.text ?? "")\n\n" }
        }
        let cited = collection.items.compactMap(\.citation)
        if !cited.isEmpty {
            out += "\n## Sources\n\n"
            var seen = Set<String>()
            for citation in cited where seen.insert(citation.url).inserted { out += "- " + citation.plain + "\n" }
        }
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func safeLink(_ url: String?) -> String? {
        guard let url, let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
        return escape(url)
    }

    static func html(_ collection: ResearchCollection, now: Date = Date()) -> String {
        func link(_ title: String, _ url: String?) -> String { safeLink(url).map { "<a href=\"\($0)\">\(escape(title))</a>" } ?? escape(title) }
        var body = "<h1>\(escape(collection.name))</h1>\n<p class=\"meta\">Exported \(heading(now)) from Browser Setu</p>\n"
        let pages = collection.items.filter { $0.kind == .page || $0.kind == .pdf }
        if !pages.isEmpty {
            body += "<h2>Pages</h2>\n<ol>\n"
            for item in pages {
                body += "<li>" + link(item.title, item.url) + (item.kind == .pdf ? " (PDF)" : "")
                if let c = item.citation { body += "<br><span class=\"cite\">" + escape(c.plain) + "</span>" }
                if let note = item.text, !note.isEmpty { body += "<blockquote>" + escape(note).replacingOccurrences(of: "\n", with: "<br>") + "</blockquote>" }
                body += "</li>\n"
            }
            body += "</ol>\n"
        }
        let highlights = collection.items.filter { $0.kind == .highlight }
        if !highlights.isEmpty {
            body += "<h2>Highlights</h2>\n"
            for item in highlights {
                body += "<blockquote>" + escape(item.text ?? "").replacingOccurrences(of: "\n", with: "<br>")
                if item.url != nil { body += "<footer>— " + link(item.title, item.url) + "</footer>" }
                body += "</blockquote>\n"
            }
        }
        let notes = collection.items.filter { $0.kind == .note }
        if !notes.isEmpty {
            body += "<h2>Notes</h2>\n"
            for item in notes { body += "<h3>\(escape(item.title))</h3>\n<p>" + escape(item.text ?? "").replacingOccurrences(of: "\n", with: "<br>") + "</p>\n" }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>\(escape(collection.name))</title>
        <style>body{font:16px/1.55 -apple-system,Helvetica,Arial,sans-serif;max-width:46em;margin:2.5em auto;padding:0 1.2em;color:#222}
        h1{font-size:1.9em;margin-bottom:.1em}.meta{color:#777;margin-top:0}blockquote{margin:.6em 0;padding:.1em 1em;border-left:3px solid #bbb;color:#444}
        footer{color:#777;font-size:.9em}.cite{color:#666;font-size:.9em}a{color:#0b5fff}</style></head><body>
        \(body)</body></html>
        """
    }
}

// MARK: - The browser's side of it

extension BrowserModel {
    var research: ResearchStore {
        if isSecondary, let primary = windows.primary { return primary.research }
        if let existing = researchBacking { return existing }
        let store = ResearchStore(folder: profileFolder.appendingPathComponent("research", isDirectory: true))
        researchBacking = store
        return store
    }

    /// The page in front as a citation (title, address, author and date from the page's own tags).
    func citationForActivePage() async -> Citation? {
        guard let tab = active, !tab.isPrivate, !tab.isBlank, let url = tab.url else { return nil }
        let meta = await tab.engine.pageMetadata() ?? [:]
        let title = (meta["title"]?.isEmpty == false ? meta["title"] : nil) ?? tab.displayTitle
        let address = TrackingParameters.clean(url) ?? url
        return Citation(title: title, url: address.absoluteString, author: meta["author"].flatMap { $0.isEmpty ? nil : $0 },
                        published: meta["published"].flatMap { $0.isEmpty ? nil : $0 }, site: meta["site"].flatMap { $0.isEmpty ? nil : $0 }, accessed: Date())
    }

    private func targetCollection() -> ResearchCollection? {
        if let current = research.current { return current }
        return research.create(name: "My Research")
    }

    func addPageToResearch() async {
        guard let tab = active, !tab.isPrivate else { notice = "Pages from private tabs are not saved."; return }
        guard let citation = await citationForActivePage(), let collection = targetCollection() else { notice = "There is no page to add."; return }
        let isPDF = URL(string: citation.url)?.pathExtension.lowercased() == "pdf"
        research.add(ResearchItem(kind: isPDF ? .pdf : .page, title: citation.title, url: citation.url, text: nil, citation: citation), to: collection.id)
        notice = "Added to “\(collection.name)”."
    }

    func addSelectionToResearch() async {
        guard let tab = active, !tab.isPrivate else { notice = "Pages from private tabs are not saved."; return }
        guard let text = await tab.engine.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { notice = "Select some text on the page first."; return }
        guard let citation = await citationForActivePage(), let collection = targetCollection() else { return }
        research.add(ResearchItem(kind: .highlight, title: citation.title, url: citation.url, text: text, citation: citation), to: collection.id)
        notice = "Highlight added to “\(collection.name)”."
    }

    /// Saves the page in front as a PDF kept in the research folder, so it can be read with no connection and no matter what happens to the page. Private tabs are never saved.
    func saveOfflineCopyToResearch() async {
        guard let tab = active, !tab.isPrivate, !tab.isBlank else { notice = "Open a page first. Private tabs are never saved."; return }
        guard let citation = await citationForActivePage(), let collection = targetCollection() else { notice = "There is no page to save."; return }
        guard let pdf = await tab.engine.pagePDF(), let name = research.saveFile(pdf) else { notice = "This page could not be saved as a PDF (it may be too large)."; return }
        research.add(ResearchItem(kind: .pdf, title: citation.title, url: citation.url, text: nil, citation: citation, file: name), to: collection.id)
        notice = "Saved a copy to “\(collection.name)”: it opens without a connection."
    }

    /// A passage you selected, with your own note about it, and how far down the page it was. Later "Go to passage" finds it again on the page.
    func addAnchoredNote(_ comment: String) async {
        guard let tab = active, !tab.isPrivate, !tab.isBlank else { notice = "Open a page first. Private tabs are never saved."; return }
        let body = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard let passage = await tab.engine.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines), !passage.isEmpty else { notice = "Select the words the note is about first."; return }
        guard let citation = await citationForActivePage(), let collection = targetCollection() else { return }
        let place = await tab.engine.scrollFraction()
        research.add(ResearchItem(kind: .highlight, title: citation.title, url: citation.url, text: passage, citation: citation, comment: String(body.prefix(2000)), place: place), to: collection.id)
        notice = "Note added to “\(collection.name)”."
    }

    /// Opens the page a saved passage came from (the tab that already shows it, or a new one) and finds the passage on it.
    func goToPassage(_ item: ResearchItem) {
        guard let raw = item.url, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let key = PageMemoryKey.key(for: url)
        let tab: TabController
        if let open = tabs.first(where: { !$0.isPrivate && $0.url.flatMap(PageMemoryKey.key(for:)) == key }) { tab = open; select(open.id) }
        else { tab = openTab(url: url, isPrivate: false) }
        if let passage = item.text, !passage.isEmpty { pendingPassage[tab.id] = String(passage.prefix(120)) }
        if tab.hasLoadedPage, !tab.isLoading { showPassage(in: tab) }
    }

    func showPassage(in tab: TabController) {
        guard let passage = pendingPassage.removeValue(forKey: tab.id) else { return }
        Task { try? await Task.sleep(for: .seconds(0.8)); guard activeID == tab.id else { return }; showFind(); findText = passage; findNext() }
    }

    func addNoteToResearch(title: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let collection = targetCollection() else { return }
        research.add(ResearchItem(kind: .note, title: title.isEmpty ? "Note" : title, url: nil, text: body, citation: nil), to: collection.id)
    }

    func copyCitationForActivePage() async {
        guard let citation = await citationForActivePage() else { notice = "Citations are not made for private or blank tabs."; return }
        copyToPasteboard(citation.plain)
        notice = "Citation copied."
    }

    /// Writes the collection to Downloads as Markdown, HTML or PDF.
    func exportResearch(_ collection: ResearchCollection, as format: ResearchFormat) async {
        let name = collection.name.replacingOccurrences(of: "/", with: "-")
        switch format {
        case .markdown: saveExport(Data(ResearchExport.markdown(collection).utf8), name: name + ".md")
        case .html: saveExport(Data(ResearchExport.html(collection).utf8), name: name + ".html")
        case .pdf:
            // The page is drawn in a tab of its own that leaves nothing behind, then printed to a PDF.
            let scratch = openScratchTab()
            defer { closeTab(id: scratch.id, force: true) }
            scratch.engine.showHTML(ResearchExport.html(collection), baseURL: nil)
            try? await Task.sleep(for: .milliseconds(900))
            guard let pdf = await scratch.engine.pagePDF(), !pdf.isEmpty else { notice = "The PDF could not be made."; return }
            saveExport(pdf, name: name + ".pdf")
        }
    }

    private func saveExport(_ data: Data, name: String) {
        do {
            try FileManager.default.createDirectory(at: DownloadCoordinator.directory, withIntermediateDirectories: true)
            let target = DownloadCoordinator.uniqueURL(in: DownloadCoordinator.directory, name: name)
            try data.write(to: target, options: .atomic)
            notice = "Saved \(target.lastPathComponent) to Downloads."
        } catch { notice = "That could not be saved. \(error.localizedDescription)" }
    }

    /// Puts two pages of a collection side by side.
    func compareResearchPages(_ first: ResearchItem, _ second: ResearchItem) {
        guard let a = first.url.flatMap(URL.init(string:)), let b = second.url.flatMap(URL.init(string:)) else { return }
        let left = openTab(url: a, isPrivate: false)
        let right = openTab(url: b, isPrivate: false, select: false)
        select(left.id)
        openSplit(with: right)
    }
}

enum ResearchFormat: String, CaseIterable, Identifiable {
    case markdown, html, pdf
    var id: String { rawValue }
    var title: String { self == .markdown ? "Markdown" : (self == .html ? "HTML" : "PDF") }
}

// MARK: - Screen

struct ResearchView: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var store: ResearchStore
    @State private var showTimeline = false
    @State private var compare: [UUID] = []
    @State private var noteTitle = ""
    @State private var noteText = ""
    @State private var reading: URL?
    @State private var askingNote = false
    @State private var anchoredText = ""

    init(store: ResearchStore) { self.store = store }

    var body: some View {
        researchList
            .sheet(item: $reading) { PDFAnnotatorView(source: $0).environmentObject(model) }
            .alert("Note on the selected words", isPresented: $askingNote) {
                TextField("Your note", text: $anchoredText)
                Button("Add") { let text = anchoredText; anchoredText = ""; Task { await model.addAnchoredNote(text) } }
                Button("Cancel", role: .cancel) { anchoredText = "" }
            } message: { Text("Select the words on the page first. The note is saved with them and can take you back to the spot.") }
    }

    private var researchList: some View {
        List {
            Section {
                if store.collections.isEmpty {
                    Text("No collections yet. Add the page you are reading, or make a collection first.").foregroundStyle(.secondary)
                } else {
                    Picker("Collection", selection: Binding(get: { store.current?.id ?? UUID() }, set: { store.currentID = $0 })) {
                        ForEach(store.collections) { Text($0.name).tag($0.id) }
                    }
                }
                HStack {
                    Button("Add This Page") { Task { await model.addPageToResearch() } }
                    Button("Add Selection") { Task { await model.addSelectionToResearch() } }
                    Button("Save Offline Copy") { Task { await model.saveOfflineCopyToResearch() } }
                    Button("Note on Selection…") { askingNote = true }
                    Button("Copy Citation") { Task { await model.copyCitationForActivePage() } }
                }
                Button("New Collection…") {
                    Task { @MainActor in if let name = await Dialogs.promptText(title: "New Collection", message: "Name this set of pages, highlights and notes.", placeholder: "") { store.create(name: name) } }
                }
                Toggle("Timeline of everything", isOn: $showTimeline)
            }
            if showTimeline { timeline } else if let collection = store.current { collectionSection(collection) }
            Section("Write a Note") {
                TextField("Title", text: $noteTitle)
                TextField("Note", text: $noteText, axis: .vertical).lineLimit(2...6)
                Button("Add Note") { model.addNoteToResearch(title: noteTitle, text: noteText); noteTitle = ""; noteText = "" }.disabled(noteText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .accessibilityIdentifier("research")
    }

    @ViewBuilder private func collectionSection(_ collection: ResearchCollection) -> some View {
        Section {
            if collection.items.isEmpty { Text("Empty.").foregroundStyle(.secondary) }
            ForEach(collection.items) { item in row(item, in: collection) }
            if compare.count == 2 {
                Button("Compare the Two Chosen Pages Side by Side") {
                    let chosen = collection.items.filter { compare.contains($0.id) }
                    if chosen.count == 2 { model.compareResearchPages(chosen[0], chosen[1]); compare = [] }
                }
            }
        } header: {
            HStack {
                Text(collection.name)
                Spacer()
                Menu("Export") { ForEach(ResearchFormat.allCases) { format in Button(format.title) { Task { await model.exportResearch(collection, as: format) } } } }
                Button("Delete", role: .destructive) { store.delete(collection.id) }
            }
        }
    }

    private func row(_ item: ResearchItem, in collection: ResearchCollection) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if item.kind == .page || item.kind == .pdf {
                Button { toggleCompare(item.id) } label: { Image(systemName: compare.contains(item.id) ? "checkmark.circle.fill" : "circle") }
                    .buttonStyle(.plain).help("Choose to compare").accessibilityLabel("Choose \(item.title) to compare")
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(item.title, systemImage: symbol(item.kind)).lineLimit(2)
                if let text = item.text, !text.isEmpty { Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                if let comment = item.comment, !comment.isEmpty { Text(comment).font(.callout).lineLimit(4) }
                if store.savedFile(for: item) != nil { Label("Saved copy, opens offline", systemImage: "arrow.down.circle").font(.caption2).foregroundStyle(.tertiary) }
                if let citation = item.citation { Text(citation.plain).font(.caption2).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if let file = store.savedFile(for: item) { Button("Open Copy") { reading = file }.controlSize(.small) }
            if item.kind == .highlight, item.url != nil { Button("Go to Passage") { model.goToPassage(item) }.controlSize(.small) }
            else if let url = item.url.flatMap(URL.init(string:)) { Button("Open") { model.openTab(url: url, isPrivate: false) }.controlSize(.small) }
            Button(role: .destructive) { store.remove(item.id, from: collection.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private var timeline: some View {
        ForEach(store.timeline(), id: \.day) { entry in
            Section(entry.day.formatted(date: .complete, time: .omitted)) {
                ForEach(entry.items, id: \.item.id) { pair in
                    Label("\(pair.item.title) · \(pair.collection)", systemImage: symbol(pair.item.kind)).lineLimit(2)
                }
            }
        }
    }

    private func toggleCompare(_ id: UUID) {
        if let index = compare.firstIndex(of: id) { compare.remove(at: index) } else { compare = Array((compare + [id]).suffix(2)) }
    }

    private func symbol(_ kind: ResearchItem.Kind) -> String {
        switch kind { case .page: "doc.text"; case .pdf: "doc.richtext"; case .highlight: "highlighter"; case .note: "note.text" }
    }
}
