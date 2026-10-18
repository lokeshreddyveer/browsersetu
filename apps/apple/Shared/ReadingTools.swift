import Foundation
import NaturalLanguage
import SwiftUI

/// How the reader looks: type, colours, width and spacing. One setting for the whole app, applied to every article.
struct ReaderStyle: Codable, Equatable {
    enum Family: String, Codable, CaseIterable, Identifiable {
        case serif, sans, rounded, mono
        var id: String { rawValue }
        var title: String { rawValue == "sans" ? "Sans" : rawValue.capitalized }
        var stack: String {
            switch self {
            case .serif: "\"New York\", Georgia, serif"
            case .sans: "-apple-system, \"Helvetica Neue\", sans-serif"
            case .rounded: "ui-rounded, \"SF Pro Rounded\", -apple-system, sans-serif"
            case .mono: "ui-monospace, Menlo, monospace"
            }
        }
    }
    enum Theme: String, Codable, CaseIterable, Identifiable {
        case auto, light, sepia, dark, black
        var id: String { rawValue }
        var title: String { rawValue == "auto" ? "Match System" : rawValue.capitalized }
        var colors: (background: String, text: String) {
            switch self {
            case .auto: ("Canvas", "CanvasText")
            case .light: ("#ffffff", "#1d1d1f")
            case .sepia: ("#f4ecd8", "#5b4636")
            case .dark: ("#1c1c1e", "#e5e5e7")
            case .black: ("#000000", "#d0d0d0")
            }
        }
    }
    enum Width: String, Codable, CaseIterable, Identifiable {
        case narrow, medium, wide
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var pixels: Int { self == .narrow ? 560 : (self == .medium ? 680 : 840) }
    }

    var family: Family = .serif
    var theme: Theme = .auto
    var width: Width = .medium
    /// Body text size in points.
    var size = 19
    var lineSpacing = 1.65
    /// Extra space between letters, in em.
    var letterSpacing = 0.0

    static let sizeRange = 14...34
    static let lineSpacingChoices = [1.3, 1.45, 1.65, 1.85, 2.1]
    static let letterSpacingChoices = [0.0, 0.02, 0.05, 0.08]

    /// The style in force. Set by the model when the setting changes, so a page can be built without reaching for the model.
    nonisolated(unsafe) static var current = ReaderStyle()

    func clamped() -> ReaderStyle {
        var s = self
        s.size = min(max(s.size, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        s.lineSpacing = min(max(s.lineSpacing, 1.2), 2.4)
        s.letterSpacing = min(max(s.letterSpacing, 0), 0.12)
        return s
    }

    /// The rules for the article page.
    var css: String {
        let s = clamped()
        let c = s.theme.colors
        let scheme = s.theme == .auto ? "light dark" : (s.theme == .light || s.theme == .sepia ? "light" : "dark")
        return """
        :root { color-scheme: \(scheme); }
        body { margin: 0; background: \(c.background); color: \(c.text); font: \(s.size)px/\(s.lineSpacing) \(s.family.stack); letter-spacing: \(s.letterSpacing)em; }
        main { max-width: \(s.width.pixels)px; margin: 0 auto; padding: 56px 24px 96px; }
        .site { font: 600 13px -apple-system, sans-serif; letter-spacing: .06em; text-transform: uppercase; opacity: .55; margin-bottom: 8px; }
        h1 { font: 700 \(Int(Double(s.size) * 1.8))px/1.2 \(s.family == .mono ? s.family.stack : "-apple-system, sans-serif"); margin: 0 0 28px; letter-spacing: 0; }
        h2, h3 { font-family: \(s.family == .mono ? s.family.stack : "-apple-system, sans-serif"); line-height: 1.3; margin: 34px 0 10px; letter-spacing: 0; }
        p, li { margin: 0 0 1.05em; }
        blockquote { margin: 1.4em 0; padding-left: 18px; border-left: 3px solid color-mix(in srgb, \(c.text) 25%, transparent); opacity: .85; }
        pre { overflow-x: auto; padding: 14px; border-radius: 10px; background: color-mix(in srgb, \(c.text) 8%, transparent); font-size: \(max(12, s.size - 4))px; letter-spacing: 0; }
        mark { background: rgba(255, 214, 10, .45); color: inherit; padding: 0 .1em; border-radius: 3px; }
        figure { margin: 1.6em 0; } img { max-width: 100%; height: auto; border-radius: 10px; }
        """
    }
}

/// A reference for the page, in a few common shapes. The page's author and publication date are not available to the browser, so the site stands in
/// for the publisher and the date is "n.d."; the date it was read is included.
enum PageCitation {
    enum Style: String, CaseIterable, Identifiable {
        case apa, mla, plain
        var id: String { rawValue }
        var title: String { self == .plain ? "Plain" : rawValue.uppercased() }
    }

    static func format(title: String, site: String, url: String, accessed: Date = Date(), style: Style) -> String {
        func day(_ pattern: String) -> String {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = pattern
            return f.string(from: accessed)
        }
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines), s = site.trimmingCharacters(in: .whitespacesAndNewlines)
        switch style {
        case .apa: return "\(s.isEmpty ? t : s). (n.d.). \(t). Retrieved \(day("MMMM d, yyyy")), from \(url)"
        case .mla: return "“\(t).” \(s.isEmpty ? "" : s + ", ")n.d., \(url). Accessed \(day("d MMM. yyyy"))."
        case .plain: return "\(t) — \(s.isEmpty ? url : s) — \(url)"
        }
    }
}

/// Which language a text is written in, from the system's own recogniser. Nothing leaves the device.
enum LanguageDetector {
    struct Detected: Equatable { var code: String; var name: String; var confidence: Double }

    static func detect(_ text: String) -> Detected? {
        let sample = String(text.prefix(2000))
        guard sample.count >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= 0.5 else { return nil }
        let code = best.key.rawValue
        return Detected(code: code, name: Locale.current.localizedString(forLanguageCode: code) ?? code, confidence: best.value)
    }

    /// True when the text's language is the one the system is set to.
    static func isSystemLanguage(_ code: String) -> Bool {
        let system = Locale.current.language.languageCode?.identifier ?? "en"
        return code == system || code.hasPrefix(system + "-")
    }
}

enum ReadingSearch {
    /// An item matches on its title, site, address, highlights or the text of its saved article.
    static func matches(_ item: ReadingItem, article: ReadableArticle?, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        if [item.title, item.site, item.url].contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        if item.highlights.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
        guard let article else { return false }
        return article.blocks.contains { block in
            switch block {
            case .heading(_, let t), .paragraph(let t), .quote(let t), .code(let t), .listItem(let t): return t.localizedCaseInsensitiveContains(q)
            case .image(_, let caption): return caption.localizedCaseInsensitiveContains(q)
            }
        }
    }

    /// Whether to show a progress label for a saved article: started, and not finished.
    static func progressLabel(_ progress: Double?) -> String? {
        guard let p = progress, p >= 0.03 else { return nil }
        return p >= 0.97 ? "finished" : "\(Int((p * 100).rounded()))% read"
    }
}

@MainActor
extension BrowserModel {
    // MARK: Reader style

    func setReaderStyle(_ style: ReaderStyle) {
        readerStyle = style.clamped()
        ReaderStyle.current = readerStyle
        saveSetting("reader_style", (try? String(data: JSONEncoder().encode(readerStyle), encoding: .utf8)) ?? "")
        refreshReaderInFront()
    }

    func changeReaderSize(by delta: Int) {
        var s = readerStyle
        s.size += delta
        setReaderStyle(s)
        notice = "Reader text \(readerStyle.size) pt."
    }

    func loadReaderStyle() {
        if let json = (try? core.getSetting(key: "reader_style")) ?? nil, let data = json.data(using: .utf8), let style = try? JSONDecoder().decode(ReaderStyle.self, from: data) {
            readerStyle = style.clamped()
        } else { readerStyle = ReaderStyle() }
        ReaderStyle.current = readerStyle
    }

    /// Draws the article in front again with the new style.
    func refreshReaderInFront() {
        guard let tab = active, let content = tab.readerContent, tab.isReading || tab.readingItemID != nil else { return }
        tab.engine.showHTML(ReaderHTML.page(for: content.article, highlights: content.highlights), baseURL: content.base)
    }

    // MARK: Citations and highlights

    func copyCitation(_ style: PageCitation.Style) {
        guard let tab = active, !tab.isBlank, let url = tab.readerContent?.base ?? tab.url else { notice = "There is no page to cite."; return }
        let site = tab.readerContent?.article.site.nonEmptyOrNil ?? displayHost(url)
        copyToPasteboard(PageCitation.format(title: tab.readerContent?.article.title.nonEmptyOrNil ?? tab.displayTitle, site: site, url: url.absoluteString, style: style))
        notice = "\(style.title) citation copied."
    }

    /// The highlights of the saved article in front, each quoted, followed by its citation.
    func copyHighlights() {
        guard let id = active?.readingItemID, let item = readingList.first(where: { $0.id == id }) else { notice = "Open a saved article to copy its highlights."; return }
        guard !item.highlights.isEmpty else { notice = "This article has no highlights yet."; return }
        let quotes = item.highlights.map { "“\($0)”" }.joined(separator: "\n\n")
        copyToPasteboard(quotes + "\n\n" + PageCitation.format(title: item.title, site: item.site, url: item.url, style: .apa))
        notice = "Copied \(item.highlights.count) highlight\(item.highlights.count == 1 ? "" : "s") with a citation."
    }

    // MARK: Progress and search

    /// Keeps how far down a saved article the person is. Called with the background check, for the article in front only.
    func updateReadingProgress() async {
        guard let tab = active, let id = tab.readingItemID, let item = readingList.first(where: { $0.id == id }),
              let fraction = await tab.engine.scrollFraction() else { return }
        guard abs(fraction - (item.progress ?? 0)) >= 0.03 else { return }
        setReadingList(readingList.map { var c = $0; if c.id == id { c.progress = fraction }; return c })
    }

    func searchReading(_ query: String) -> [ReadingItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return readingList }
        return readingList.filter { ReadingSearch.matches($0, article: $0.hasOfflineCopy ? ReadingStore.loadArticle(id: $0.id, root: profileFolder) : nil, query: query) }
    }

    // MARK: Translation helpers

    /// Says what language the page is in.
    func detectPageLanguage() async {
        guard let text = await active?.engine.pageText(), let found = LanguageDetector.detect(text) else { notice = "Could not tell what language this page is in."; return }
        notice = "This page looks like \(found.name)."
    }

    func translateSelection() async {
        guard let text = await active?.engine.selectedText() else { notice = "Select some text first."; return }
        translationText = text
    }
}

private extension String { var nonEmptyOrNil: String? { isEmpty ? nil : self } }

struct ReaderSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    private func binding<T>(_ keyPath: WritableKeyPath<ReaderStyle, T>) -> Binding<T> {
        Binding(get: { model.readerStyle[keyPath: keyPath] }, set: { var s = model.readerStyle; s[keyPath: keyPath] = $0; model.setReaderStyle(s) })
    }

    var body: some View {
        Section {
            Picker("Font", selection: binding(\.family)) { ForEach(ReaderStyle.Family.allCases) { Text($0.title).tag($0) } }
            Picker("Background", selection: binding(\.theme)) { ForEach(ReaderStyle.Theme.allCases) { Text($0.title).tag($0) } }
            Picker("Width", selection: binding(\.width)) { ForEach(ReaderStyle.Width.allCases) { Text($0.title).tag($0) } }
            Stepper("Text size: \(model.readerStyle.size) pt", value: binding(\.size), in: ReaderStyle.sizeRange)
            Picker("Line spacing", selection: binding(\.lineSpacing)) { ForEach(ReaderStyle.lineSpacingChoices, id: \.self) { Text($0.formatted()).tag($0) } }
            Picker("Letter spacing", selection: binding(\.letterSpacing)) { ForEach(ReaderStyle.letterSpacingChoices, id: \.self) { Text($0 == 0 ? "Normal" : "+\(Int($0 * 100))%").tag($0) } }
        } header: { Text("Reader") } footer: {
            Text("Applies to the reader view and to saved articles. The fonts are the ones built into the system.")
        }
    }
}
