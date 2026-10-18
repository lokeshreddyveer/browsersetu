import CoreImage.CIFilterBuiltins
import SwiftUI
import Translation
import UniformTypeIdentifiers

// MARK: - Reading list

/// An article saved to read later. Its text is kept on this device, so it opens without a connection.
struct ReadingItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String
    var site: String
    var added = Date()
    var read = false
    /// Passages the reader marked in the saved copy.
    var highlights: [String] = []
    var hasOfflineCopy = false
    /// How far down the article the person had read (0 to 1).
    var progress: Double?
}

/// The reading list on disk: an index, and one file per saved article.
enum ReadingStore {
    static func folder(root: URL) -> URL { root.appendingPathComponent("reading", isDirectory: true) }
    private static func articleFile(_ id: UUID, root: URL) -> URL { folder(root: root).appendingPathComponent(id.uuidString + ".json") }

    static func loadIndex(root: URL) -> [ReadingItem] {
        guard let data = try? Data(contentsOf: folder(root: root).appendingPathComponent("index.json")) else { return [] }
        return (try? JSONDecoder().decode([ReadingItem].self, from: data)) ?? []
    }

    static func saveIndex(_ items: [ReadingItem], root: URL) {
        try? FileManager.default.createDirectory(at: folder(root: root), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: folder(root: root).appendingPathComponent("index.json"), options: .atomic) }
    }

    static func saveArticle(_ article: ReadableArticle, id: UUID, root: URL) {
        try? FileManager.default.createDirectory(at: folder(root: root), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(article) { try? data.write(to: articleFile(id, root: root), options: .atomic) }
    }

    static func loadArticle(id: UUID, root: URL) -> ReadableArticle? {
        guard let data = try? Data(contentsOf: articleFile(id, root: root)) else { return nil }
        return try? JSONDecoder().decode(ReadableArticle.self, from: data)
    }

    static func deleteArticle(id: UUID, root: URL) { try? FileManager.default.removeItem(at: articleFile(id, root: root)) }
}

// MARK: - Search shortcuts

/// A short word before a search picks the search engine for that one search: "g cats", "yt trailers", "w Ada Lovelace".
enum SearchShortcuts {
    struct Entry: Equatable { var keyword: String; var name: String; var template: String }

    static let builtIn: [Entry] = [
        Entry(keyword: "b", name: "Brave Search", template: "https://search.brave.com/search?q={}"),
        Entry(keyword: "d", name: "DuckDuckGo", template: "https://duckduckgo.com/?q={}"),
        Entry(keyword: "g", name: "Google", template: "https://www.google.com/search?q={}"),
        Entry(keyword: "bing", name: "Bing", template: "https://www.bing.com/search?q={}"),
        Entry(keyword: "e", name: "Ecosia", template: "https://www.ecosia.org/search?q={}"),
        Entry(keyword: "w", name: "Wikipedia", template: "https://en.wikipedia.org/w/index.php?search={}"),
        Entry(keyword: "yt", name: "YouTube", template: "https://www.youtube.com/results?search_query={}"),
        Entry(keyword: "gh", name: "GitHub", template: "https://github.com/search?q={}"),
        Entry(keyword: "maps", name: "Apple Maps", template: "https://maps.apple.com/?q={}"),
    ]

    private static let queryAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#?"))

    /// The search this input asks for, or nil when it does not start with a known keyword followed by something to search for.
    static func resolve(_ input: String, custom: [String: String]) -> (name: String, query: String, url: String)? {
        let parts = input.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2 else { return nil }
        let key = parts[0].lowercased()
        let query = parts[1].trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let encoded = query.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
        if let template = custom[key], SearchEngines.validated(template) != nil {
            return (key, query, template.replacingOccurrences(of: "{}", with: encoded))
        }
        guard let entry = builtIn.first(where: { $0.keyword == key }) else { return nil }
        return (entry.name, query, entry.template.replacingOccurrences(of: "{}", with: encoded))
    }
}

// MARK: - QR codes

enum QRCode {
    /// A QR code for `text`, as a crisp picture `size` points across (nil if the text is too long for a code).
    static func image(for text: String, size: CGFloat = 280) -> PlatformImage? {
        guard !text.isEmpty, text.utf8.count <= 1_500 else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale.rounded(.down), y: scale.rounded(.down)))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}

// MARK: - The model's productivity tools

extension BrowserModel {
    // Reading list

    /// Saves the page in front: its article is kept on this device so it opens without a connection. A page with no article is
    /// saved as a link only.
    func addToReadingList() async {
        guard let tab = active, !tab.isBlank, let url = tab.url, !tab.isPrivate else {
            notice = "Pages from private tabs are not saved."; return
        }
        guard !readingList.contains(where: { $0.url == url.absoluteString }) else { notice = "Already in your reading list."; return }
        let article = await tab.engine.readableContent()
        var item = ReadingItem(url: url.absoluteString, title: tab.displayTitle, site: displayHost(url))
        if let article {
            ReadingStore.saveArticle(article, id: item.id, root: profileFolder)
            item.hasOfflineCopy = true
            if !article.title.isEmpty { item.title = article.title }
        }
        setReadingList([item] + readingList)
        notice = item.hasOfflineCopy ? "Saved to your reading list, to read offline." : "Saved to your reading list as a link: this page has no article to keep."
    }

    /// Opens a saved article: the offline copy if there is one, else the page itself.
    func openReadingItem(_ item: ReadingItem, online: Bool = false) {
        var updated = item
        updated.read = true
        setReadingList(readingList.map { $0.id == item.id ? updated : $0 })
        guard !online, item.hasOfflineCopy, let article = ReadingStore.loadArticle(id: item.id, root: profileFolder) else { open(urlString: item.url); return }
        let tab = openTab(url: nil, isPrivate: false)
        tab.readingItemID = item.id
        tab.setReadingTitle(item.title)
        tab.readerContent = (article, item.highlights, URL(string: item.url))
        tab.engine.showHTML(ReaderHTML.page(for: article, highlights: item.highlights), baseURL: URL(string: item.url))
        // Back to where the person stopped.
        if let progress = item.progress, progress > 0.03, progress < 0.97 {
            Task { @MainActor [weak tab] in
                try? await Task.sleep(for: .seconds(0.8))
                await tab?.engine.scrollTo(fraction: progress)
            }
        }
    }

    func removeReadingItem(_ item: ReadingItem) {
        ReadingStore.deleteArticle(id: item.id, root: profileFolder)
        setReadingList(readingList.filter { $0.id != item.id })
    }

    func toggleRead(_ item: ReadingItem) { setReadingList(readingList.map { var c = $0; if c.id == item.id { c.read.toggle() }; return c }) }

    /// Marks whatever is selected in a saved article, and redraws it with the mark.
    func highlightSelection() async {
        guard let tab = active, let id = tab.readingItemID, var item = readingList.first(where: { $0.id == id }) else {
            notice = "Open a saved article from your reading list to highlight it."; return
        }
        guard let text = await tab.engine.selectedText() else { notice = "Select some text first."; return }
        if !item.highlights.contains(text) { item.highlights.append(text) }
        setReadingList(readingList.map { $0.id == id ? item : $0 })
        if let article = ReadingStore.loadArticle(id: id, root: profileFolder) {
            tab.readerContent = (article, item.highlights, URL(string: item.url))
            tab.engine.showHTML(ReaderHTML.page(for: article, highlights: item.highlights), baseURL: URL(string: item.url))
        }
    }

    // Notes on websites

    /// Notes belong to a page: its address without the query and fragment.
    func noteKey(for tab: TabController?) -> String? {
        guard let url = tab?.url, let host = url.host else { return nil }
        var path = url.path
        while path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        return host.lowercased() + path
    }

    func noteForActivePage() -> String { noteKey(for: active).flatMap { siteNotes[$0] } ?? "" }

    func setNoteForActivePage(_ text: String) {
        guard let key = noteKey(for: active) else { return }
        var map = siteNotes
        let trimmed = String(text.prefix(5_000))
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { map[key] = nil } else if map[key] != nil || map.count < 300 { map[key] = trimmed }
        setSiteNotes(map)
    }

    // A style sheet per website

    func siteStyle(forHost host: String?) -> String? {
        let own = FaviconStore.key(forHost: host).flatMap { siteStyles[$0] } ?? ""
        // The style sheet for every website comes first, so a site's own can override it.
        let combined = [globalStyle, own].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    /// Saves (or with empty text, removes) the style sheet for the page's website and applies it now.
    func setStyleForActiveSite(_ css: String) {
        guard let key = FaviconStore.key(forHost: active?.url?.host) else { return }
        var map = siteStyles
        let trimmed = String(css.prefix(20_000))
        if trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { map[key] = nil } else if map[key] != nil || map.count < 100 { map[key] = trimmed }
        setSiteStyles(map)
        active?.applySiteStyle()
    }

    // Tags on bookmarks

    func tags(forBookmark url: String) -> [String] { bookmarkTags[url] ?? [] }

    func setTags(_ text: String, forBookmark url: String) {
        let tags = text.split(whereSeparator: { ",;".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 30 }
        var map = bookmarkTags
        map[url] = Array(NSOrderedSet(array: tags).array as? [String] ?? tags).prefix(10).map { $0 }
        setBookmarkTags(map)
    }

    // Links

    /// The page's address with tracking parameters taken off, copied.
    func copyCleanLink() {
        guard let url = active?.url, !(active?.isBlank ?? true) else { return }
        let cleaned = TrackingParameters.clean(url) ?? url
        copyToPasteboard(cleaned.absoluteString)
        notice = cleaned != url ? "Copied the link without tracking parameters." : "Copied the link."
    }

    // Translation

    /// Hands the page's text to the system's own translation sheet. It works on this device; nothing is sent by Browser Setu.
    func translateOnDevice() async {
        guard let text = await active?.engine.pageText() else { notice = "There is no text on this page to translate."; return }
        if let found = LanguageDetector.detect(text) {
            if LanguageDetector.isSystemLanguage(found.code) { notice = "This page is already in \(found.name)."; return }
            notice = "Translating from \(found.name)."
        }
        translationText = text
    }
}

extension TabController {
    func setReadingTitle(_ title: String) { self.title = title }
}

/// Presents the system translation sheet while `model.translationText` is set (macOS 14.4 and iOS 17.4 and later).
struct SystemTranslation: ViewModifier {
    @EnvironmentObject var model: BrowserModel

    func body(content: Content) -> some View {
        if #available(iOS 17.4, macOS 14.4, *) {
            content.translationPresentation(isPresented: Binding(get: { model.translationText != nil }, set: { if !$0 { model.translationText = nil } }),
                                            text: model.translationText ?? "")
        } else {
            content
        }
    }
}

// MARK: - Screens

struct ReadingListView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        List {
            Section {
                TextField("Search saved articles", text: $query).autocorrectionDisabled()
                Button("Add This Page to the Reading List") { Task { await model.addToReadingList() } }
                    .disabled(model.active?.isBlank ?? true)
            } footer: { Text("An article is kept on this device so it opens without a connection. Select text in a saved article, then choose Highlight Selection.") }
            SavedPagesSection()
            Section("Saved") {
                if model.readingList.isEmpty { Label("Nothing saved yet", systemImage: "books.vertical").foregroundStyle(.secondary) }
                else if model.searchReading(query).isEmpty { Label("No saved article matches", systemImage: "magnifyingglass").foregroundStyle(.secondary) }
                ForEach(model.searchReading(query)) { item in
                    Button { model.openReadingItem(item); model.sheet = nil; dismiss() } label: {
                        HStack(spacing: 10) {
                            Circle().fill(item.read ? Color.clear : Theme.accent).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).fontWeight(item.read ? .regular : .semibold).lineLimit(2)
                                Text("\(item.site) · \(item.added.formatted(.relative(presentation: .named)))" + (item.hasOfflineCopy ? " · offline" : "")
                                     + (item.highlights.isEmpty ? "" : " · \(item.highlights.count) highlight\(item.highlights.count == 1 ? "" : "s")")
                                     + (ReadingSearch.progressLabel(item.progress).map { " · " + $0 } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(item.read ? "Mark as Unread" : "Mark as Read") { model.toggleRead(item) }
                        if item.hasOfflineCopy { Button("Open the Website") { model.openReadingItem(item, online: true); model.sheet = nil; dismiss() } }
                        Button("Remove", role: .destructive) { model.removeReadingItem(item) }
                    }
                }
                .onDelete { offsets in offsets.map { model.readingList[$0] }.forEach(model.removeReadingItem) }
            }
        }
        .accessibilityIdentifier("reading-list")
    }
}

/// A note kept on this device for the page in front.
struct PageNoteView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(displayHost(model.active?.url) + (model.active?.url?.path ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            TextEditor(text: $text).font(.body).frame(minHeight: 160)
                .overlay(alignment: .topLeading) { if text.isEmpty { Text("Write a note about this page…").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) } }
            Text("Saved on this device only, and shown again whenever you open this page.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { text = model.noteForActivePage() }
        .onChange(of: text) { _, new in model.setNoteForActivePage(new) }
        .accessibilityIdentifier("page-note")
    }
}

/// A QR code for the page in front (its link without tracking parameters), to scan with another device.
struct QRCodeView: View {
    @EnvironmentObject var model: BrowserModel

    private var link: String {
        guard let url = model.active?.url else { return "" }
        return (TrackingParameters.clean(url) ?? url).absoluteString
    }

    var body: some View {
        VStack(spacing: 14) {
            if let image = QRCode.image(for: link) {
                Image(platform: image).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240)
                    .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(link).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.center).frame(maxWidth: 280)
                Button("Copy Link") { copyToPasteboard(link) }
            } else {
                ContentUnavailableView("No QR Code", systemImage: "qrcode", description: Text("This page’s address is too long, or there is no page open."))
            }
        }
        .padding(24)
        .accessibilityIdentifier("qr-code")
    }
}

/// Your own CSS for one website: hide a banner, enlarge text, change colours. Style only: it can never run code.
struct SiteStyleView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var css = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Style for \(FaviconStore.key(forHost: model.active?.url?.host) ?? "this website")").font(.headline)
            TextEditor(text: $css).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
                .overlay(alignment: .topLeading) { if css.isEmpty { Text(".cookie-banner { display: none !important; }").foregroundStyle(.tertiary).font(.system(.body, design: .monospaced)).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) } }
            Text("CSS only, applied each time a page on this website loads. Saved on this device. Scripts are never run.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { css = model.siteStyle(forHost: model.active?.url?.host) ?? "" }
        .onChange(of: css) { _, new in model.setStyleForActiveSite(new) }
        .accessibilityIdentifier("site-style")
    }
}
