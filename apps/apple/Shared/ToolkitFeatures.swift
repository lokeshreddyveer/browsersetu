import Charts
import Foundation
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Feeds (RSS and Atom)

struct Feed: Codable, Identifiable, Equatable {
    var url: String
    var title: String
    var id: String { url }
}

struct FeedItem: Codable, Identifiable, Equatable {
    var feed: String
    var title: String
    var link: String
    var summary: String
    var date: Date?
    var id: String { link }
}

/// Reads an RSS or Atom document. Anything it does not understand is skipped, and a document that is not a feed gives nothing.
final class FeedParser: NSObject, XMLParserDelegate {
    private(set) var title = ""
    private(set) var items: [FeedItem] = []
    private var inItem = false
    private var text = ""
    private var current: [String: String] = [:]
    private var depth = 0

    static func parse(_ data: Data, feedURL: String) -> (title: String, items: [FeedItem]) {
        let p = FeedParser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.shouldResolveExternalEntities = false
        xml.parse()
        return (p.title, p.items.prefix(50).map { var i = $0; i.feed = feedURL; return i })
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        text = ""
        if name == "item" || name == "entry" { inItem = true; current = [:] }
        if inItem, name == "link", let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" { current["link"] = href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if text.count < 20_000 { text += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if text.count < 20_000 { text += String(decoding: CDATABlock, as: UTF8.self) } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inItem {
            switch name {
            case "title": current["title"] = value
            case "link": if current["link"] == nil, !value.isEmpty { current["link"] = value }
            case "description", "summary", "content", "content:encoded": if current["summary"] == nil || name != "description" { current["summary"] = value }
            case "pubDate", "published", "updated", "dc:date": if current["date"] == nil { current["date"] = value }
            case "item", "entry":
                inItem = false
                if let link = current["link"], let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    items.append(FeedItem(feed: "", title: Self.plain(current["title"] ?? link), link: link, summary: Self.plain(current["summary"] ?? "").prefix(280).description,
                                          date: current["date"].flatMap(Self.date)))
                }
            default: break
            }
        } else if name == "title", title.isEmpty, depth <= 3 { title = value }
    }

    /// Markup taken out of a summary, and the common character references put back.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] { s = s.replacingOccurrences(of: a, with: b) }
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z"] { f.dateFormat = pattern; if let d = f.date(from: text) { return d } }
        return nil
    }
}

enum FeedFetcher {
    /// The feed's address after the checks: https only, and a host.
    static func valid(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let url = URL(string: t), url.scheme?.lowercased() == "https", url.host?.contains(".") == true else { return nil }
        return url
    }

    /// One request, no cookies, no referrer, a 2 MB limit.
    static func fetch(_ url: URL) async -> (title: String, items: [FeedItem])? {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 12
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession(configuration: config).data(for: request), data.count <= 2_000_000,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        let parsed = FeedParser.parse(data, feedURL: url.absoluteString)
        return parsed.items.isEmpty ? nil : parsed
    }
}

// MARK: Time on sites

struct SiteTimeLog: Codable, Equatable {
    /// Seconds by site, by day ("2026-10-19").
    var days: [String: [String: Double]] = [:]
    static let keepDays = 30
    /// How long the days are kept. Set by the person; 0 keeps them until they are cleared.
    static let retentionChoices = [7, 30, 90, 365, 0]
    /// A person with no sign of life for this long is not counted (a coffee, a call, a locked screen).
    static let idleLimit: TimeInterval = 120

    /// Forgets the days older than `days` (0 keeps all).
    mutating func prune(keepingDays days: Int, now: Date = Date(), calendar: Calendar = .current) {
        guard days > 0, let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return }
        let first = Self.day(cutoff, calendar: calendar)
        for key in days_keys() where key < first { self.days[key] = nil }
    }
    private func days_keys() -> [String] { Array(days.keys) }

    static func day(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    mutating func add(seconds: Double, host: String, on date: Date = Date()) {
        guard seconds > 0, seconds <= 120, !host.isEmpty else { return }
        days[Self.day(date), default: [:]][host, default: 0] += seconds
    }

    func sites(on date: Date = Date()) -> [(host: String, seconds: Double)] {
        (days[Self.day(date)] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    func total(on date: Date = Date()) -> Double { (days[Self.day(date)] ?? [:]).values.reduce(0, +) }

    /// The last `days` days, oldest first.
    func recent(days count: Int, endingOn date: Date = Date(), calendar: Calendar = .current) -> [(day: String, seconds: Double)] {
        (0..<count).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: date) }.map { (Self.day($0, calendar: calendar), (days[Self.day($0, calendar: calendar)] ?? [:]).values.reduce(0, +)) }
    }

    /// The sites with the most time over the last `days` days.
    func topSites(days count: Int, endingOn date: Date = Date(), calendar: Calendar = .current) -> [(host: String, seconds: Double)] {
        var totals: [String: Double] = [:]
        for offset in 0..<count { if let d = calendar.date(byAdding: .day, value: -offset, to: date) { for (host, seconds) in days[Self.day(d, calendar: calendar)] ?? [:] { totals[host, default: 0] += seconds } } }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    /// The last seven days, oldest first.
    func week(endingOn date: Date = Date(), calendar: Calendar = .current) -> [(day: String, seconds: Double)] {
        (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: date) }.map { (Self.day($0), (days[Self.day($0)] ?? [:]).values.reduce(0, +)) }
    }

    static func clock(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(m, seconds > 0 ? 1 : 0)) min"
    }
}

// MARK: Clipboard history

struct ClipboardEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let date: Date
}

enum ClipboardRules {
    static let limit = 30
    /// Newest first; the same text again moves to the top, long text is cut, and entries past the age limit go.
    static func adding(_ text: String, to list: [ClipboardEntry], now: Date = Date(), keepFor: TimeInterval) -> [ClipboardEntry] {
        let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !clean.isEmpty else { return list }
        var out = list.filter { $0.text != clean }
        out.insert(ClipboardEntry(text: clean, date: now), at: 0)
        return Array(expired(out, now: now, keepFor: keepFor).prefix(limit))
    }

    static func expired(_ list: [ClipboardEntry], now: Date, keepFor: TimeInterval) -> [ClipboardEntry] { list.filter { now.timeIntervalSince($0.date) <= keepFor } }
}

// MARK: Questions about a page

enum PageAsk {
    static let instructions = "You answer a question using only the page text you are given. If the page does not say, answer that it does not. Keep the answer short and plain."

    static func prompt(question: String, title: String, text: String) -> String {
        "Question: \(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))\n\nTitle: \(title)\n\nPage text:\n\(PageSummary.trimmed(text))"
    }

    static func answer(question: String, title: String, text: String) async throws -> String {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { throw PageSummary.Failure.failed("Type a question first.") }
        guard !PageSummary.trimmed(text).isEmpty else { throw PageSummary.Failure.noText }
        if let reason = PageSummary.unavailableReason { throw PageSummary.Failure.unavailable(reason) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            do {
                let response = try await LanguageModelSession(instructions: instructions).respond(to: prompt(question: question, title: title, text: text))
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { throw PageSummary.Failure.failed(error.localizedDescription) }
        }
        #endif
        throw PageSummary.Failure.unavailable("This needs macOS 26 or iOS 26 with Apple Intelligence.")
    }
}

// MARK: The model

@MainActor
extension BrowserModel {
    private var feedCacheFile: URL {
        let folder = URL(fileURLWithPath: root).appendingPathComponent("profiles/\(profileName)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("feeds-cache.json")
    }

    func loadFeeds() {
        feeds = Self.decodeMap(try? core.getSetting(key: "feeds"), as: [Feed].self)["list"] ?? []
        if let data = try? Data(contentsOf: feedCacheFile), let items = try? JSONDecoder().decode([FeedItem].self, from: data) { feedItems = items }
        siteTimeLog = (try? core.getSetting(key: "site_time")).flatMap { $0 }.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(SiteTimeLog.self, from: $0) } ?? SiteTimeLog()
    }

    private func saveFeeds() { saveSetting("feeds", encodedMap(["list": feeds])) }

    func addFeed(_ text: String) async -> String? {
        guard let url = FeedFetcher.valid(text) else { return "Use the full web address of a feed, starting with https." }
        guard feeds.count < 20 else { return "You can follow up to 20 feeds." }
        guard !feeds.contains(where: { $0.url == url.absoluteString }) else { return "You already follow that." }
        guard let result = await FeedFetcher.fetch(url) else { return "That address did not give a feed. Try the site's RSS or Atom address." }
        return addFetchedFeed(url, result)
    }

    /// Follows a feed that was already fetched (several are fetched together when an OPML list is imported). Nil when it was added.
    func addFetchedFeed(_ url: URL, _ result: (title: String, items: [FeedItem])) -> String? {
        guard feeds.count < 20 else { return "You can follow up to 20 feeds." }
        guard !feeds.contains(where: { $0.url == url.absoluteString }) else { return "You already follow that." }
        feeds.append(Feed(url: url.absoluteString, title: result.title.isEmpty ? (url.host ?? url.absoluteString) : result.title))
        saveFeeds()
        feedItems = merge(feedItems.filter { $0.feed != url.absoluteString }, result.items)
        saveFeedItems()
        return nil
    }

    func removeFeed(_ feed: Feed) {
        feeds.removeAll { $0.url == feed.url }
        feedItems.removeAll { $0.feed == feed.url }
        saveFeeds(); saveFeedItems()
    }

    func refreshFeeds() async {
        refreshingFeeds = true
        defer { refreshingFeeds = false }
        var all: [FeedItem] = []
        for feed in feeds {
            guard let url = URL(string: feed.url) else { continue }
            if let result = await FeedFetcher.fetch(url) { all += result.items } else { all += feedItems.filter { $0.feed == feed.url } }
        }
        feedItems = merge([], all)
        saveFeedItems()
    }

    private func merge(_ a: [FeedItem], _ b: [FeedItem]) -> [FeedItem] {
        var seen = Set<String>()
        return (a + b).filter { seen.insert($0.link).inserted }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(400).map { $0 }
    }

    private func saveFeedItems() { if let data = try? JSONEncoder().encode(feedItems) { try? data.write(to: feedCacheFile, options: .atomic) } }

    func saveFeedItemToReadingList(_ item: FeedItem) {
        guard let url = URL(string: item.link), !readingList.contains(where: { $0.url == item.link }) else { notice = "Already in your reading list."; return }
        setReadingList([ReadingItem(url: item.link, title: item.title, site: displayHost(url))] + readingList)
        notice = "Saved to your reading list."
    }

    // MARK: Time on sites

    /// Called with the background check. Adds the time since the last call to the site in front, only while the app is in front and the tab is not private.
    func trackSiteTime(now: Date = Date()) {
        defer { lastTimeTick = now }
        guard trackTime, !isSecondary, let tab = active, tab.privacy.canRecordActivity, !tab.isBlank, let host = tab.url?.host else { breakStart = nil; return }
        #if os(macOS)
        // In front, and the person has touched the keyboard, mouse or trackpad lately: a locked screen or a walk away is not counted.
        guard NSApp.isActive, Self.systemIdleSeconds() < SiteTimeLog.idleLimit else { breakStart = nil; return }
        #else
        // In front, and the person has done something in the browser lately. Only what Browser Setu itself can see: nothing about other apps.
        guard UIApplication.shared.applicationState == .active, now.timeIntervalSince(lastInteraction) < SiteTimeLog.idleLimit else { breakStart = nil; return }
        #endif
        let key = FaviconStore.key(forHost: host) ?? host
        siteTimeLog.add(seconds: now.timeIntervalSince(lastTimeTick), host: key, on: now)
        siteTimeLog.prune(keepingDays: siteTimeRetentionDays, now: now)
        timeTicks += 1
        if timeTicks % 12 == 0, let data = try? JSONEncoder().encode(siteTimeLog), let text = String(data: data, encoding: .utf8) { saveSetting("site_time", text) }
        if breakSite != key { breakSite = key; breakStart = now }
        if breakMinutes > 0, let start = breakStart, now.timeIntervalSince(start) >= Double(breakMinutes) * 60 {
            breakStart = now
            notice = "You have been on \(key) for \(breakMinutes) minutes. A short break?"
        }
    }

    func clearSiteTime() { siteTimeLog = SiteTimeLog(); saveSetting("site_time", "{\"days\":{}}") }

    /// Seconds since the last keyboard, mouse or trackpad event on this Mac.
    static func systemIdleSeconds() -> TimeInterval {
        #if os(macOS)
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        #else
        return 0
        #endif
    }

    /// The person did something in a page or the browser (iPhone: the only sign of life there is). Cheap: one date.
    func noteInteraction() { lastInteraction = Date() }

    func setSiteTimeRetention(_ days: Int) {
        siteTimeRetentionDays = days
        saveSetting("site_time_days", String(days))
        siteTimeLog.prune(keepingDays: days)
        if let data = try? JSONEncoder().encode(siteTimeLog), let text = String(data: data, encoding: .utf8) { saveSetting("site_time", text) }
    }

    // MARK: Clipboard

    func recordCopy(_ text: String) {
        guard keepClipboardHistory, active?.privacy.canRecordClipboard ?? true else { return }
        clipboardHistory = ClipboardRules.adding(text, to: clipboardHistory, keepFor: 24 * 3600)
    }
}

// MARK: The screen

struct ToolkitView: View {
    enum Part: String, CaseIterable, Identifiable { case feeds = "Feeds", ask = "Ask", tasks = "Tasks", vault = "Vault", time = "Time", clipboard = "Clipboard"; var id: String { rawValue } }
    @EnvironmentObject var model: BrowserModel
    @State private var part = Part.feeds
    @State private var newFeed = ""
    @State private var feedProblem: String?
    @State private var adding = false
    @State private var onPage: [FoundFeed]?
    @State private var importing = false
    @State private var exporting = false
    @State private var feedNote: String?
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $part) { ForEach(Part.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().padding([.horizontal, .top], 16).padding(.bottom, 8)
            Group {
                switch part {
                case .feeds: feeds
                case .ask: ask
                case .tasks: TasksView()
                case .vault: VaultView()
                case .time: time
                case .clipboard: clipboard
                }
            }
        }
        .onAppear { model.loadFeedsIfNeeded() }
    }

    private var feeds: some View {
        PanelList {
            Section {
                HStack {
                    FormTextField("Feed address, such as https://example.com/feed.xml", text: $newFeed).textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    Button(adding ? "Adding…" : "Follow") {
                        adding = true
                        Task { feedProblem = await model.addFeed(newFeed); if feedProblem == nil { newFeed = "" }; adding = false }
                    }.disabled(newFeed.isEmpty || adding)
                }
                if let feedProblem { Text(feedProblem).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Find Feeds on This Page") { Task { onPage = await model.feedsOnActivePage() } }
                    Button("Import OPML…") { importing = true }
                    Button("Export OPML…") { exporting = true }.disabled(model.feeds.isEmpty)
                }
                .buttonStyle(.borderless).font(.caption)
                if let onPage {
                    if onPage.isEmpty { Text("This page does not advertise a feed.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(onPage) { found in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(found.title.isEmpty ? (URL(string: found.url)?.host ?? found.url) : found.title).lineLimit(1)
                                Text(found.url).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Spacer()
                            Button("Follow") { Task { feedProblem = await model.addFeed(found.url); if feedProblem == nil { self.onPage?.removeAll { $0.id == found.id } } } }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                if let feedNote { Text(feedNote).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button(model.refreshingFeeds ? "Refreshing…" : "Refresh All") { Task { await model.refreshFeeds() } }.disabled(model.refreshingFeeds || model.feeds.isEmpty)
                    Spacer()
                    Text("\(model.feeds.count) of 20 followed").font(.caption).foregroundStyle(.secondary)
                }
            } footer: { Text("Each feed is fetched on its own, with no cookies and no referrer, only when you refresh. Articles stay on this device so you can read them offline.") }
            if !model.feeds.isEmpty {
                Section("Following") {
                    ForEach(model.feeds) { feed in
                        HStack {
                            Text(feed.title).lineLimit(1)
                            Spacer()
                            Button(role: .destructive) { model.removeFeed(feed) } label: { Image(systemName: "minus.circle").accessibilityLabel("Unfollow") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            Section("Latest") {
                if model.feedItems.isEmpty { Text("Nothing yet. Follow a feed above.").foregroundStyle(.secondary) }
                ForEach(model.feedItems.prefix(80)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Button { model.open(urlString: item.link, newTab: true) } label: { Text(item.title).fontWeight(.medium).multilineTextAlignment(.leading) }.buttonStyle(.plain)
                        if !item.summary.isEmpty { Text(item.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        HStack {
                            Text((model.feeds.first { $0.url == item.feed }?.title ?? displayHost(URL(string: item.link))) + (item.date.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""))
                                .font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Button("Save") { model.saveFeedItemToReadingList(item) }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
        }
        .motion(.easeOut(duration: 0.2), value: onPage)
        .fileImporter(isPresented: $importing, allowedContentTypes: OPMLDocument.readableContentTypes + [.xml, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 1_000_000 else { feedNote = "That file could not be read."; return }
            Task { feedNote = await model.importOPML(data) }
        }
        .fileExporter(isPresented: $exporting, document: OPMLDocument(text: model.opmlText), contentType: OPMLDocument.readableContentTypes[0], defaultFilename: "feeds") { result in
            if case .failure = result { feedNote = "The list could not be saved." }
        }
    }

    private var ask: some View {
        PanelList {
            Section {
                FormTextField("Ask about the page you are on", text: $question).textFieldStyle(.roundedBorder).onSubmit { runAsk() }
                Button(asking ? "Reading…" : "Ask") { runAsk() }.disabled(asking || question.isEmpty || (model.active?.isBlank ?? true))
                if let answer { Text(answer).textSelection(.enabled) }
            } footer: { Text("Answered on this device from the text of the page in front. It can be wrong; check anything important on the page. Needs macOS 26 or iOS 26 with Apple Intelligence.") }
        }
    }

    private func runAsk() {
        guard let tab = model.active, !tab.isBlank, !question.isEmpty else { return }
        asking = true; answer = nil
        Task {
            let text = await tab.engine.pageText() ?? ""
            do { answer = try await PageAsk.answer(question: question, title: tab.displayTitle, text: text) }
            catch PageSummary.Failure.noText { answer = "There is no readable text on this page." }
            catch PageSummary.Failure.unavailable(let r) { answer = r }
            catch PageSummary.Failure.failed(let r) { answer = r }
            catch { answer = error.localizedDescription }
            asking = false
        }
    }

    private var time: some View {
        PanelList {
            Section {
                Toggle("Keep track of time on sites", isOn: $model.trackTime)
                Picker("Remind me to take a break after", selection: $model.breakMinutes) {
                    Text("Never").tag(0); Text("20 minutes").tag(20); Text("30 minutes").tag(30); Text("45 minutes").tag(45); Text("60 minutes").tag(60)
                }
                if model.trackTime {
                    Picker("Keep this for", selection: Binding(get: { model.siteTimeRetentionDays }, set: { model.setSiteTimeRetention($0) })) {
                        ForEach(SiteTimeLog.retentionChoices, id: \.self) { Text($0 == 0 ? "Until I clear it" : $0 == 365 ? "1 year" : "\($0) days").tag($0) }
                    }
                }
            } footer: {
                #if os(macOS)
                Text("Off until you turn it on. Counts the seconds a page is in front while Browser Setu is in front and you are using the keyboard or mouse (not while you are away or the screen is locked). Private tabs are never counted. Only the site and the seconds per day are kept, on this device.")
                #else
                Text("Off until you turn it on. Counts the seconds a page is in front while Browser Setu is open and you are using it. It only knows about Browser Setu: nothing about other apps. Private tabs are never counted. Only the site and the seconds per day are kept, on this device.")
                #endif
            }
            if model.trackTime {
                Section("Today · \(SiteTimeLog.clock(model.siteTimeLog.total()))") {
                    let sites = model.siteTimeLog.sites()
                    if sites.isEmpty { Text("Nothing yet today.").foregroundStyle(.secondary) }
                    ForEach(sites.prefix(15), id: \.host) { LabeledContent($0.host, value: SiteTimeLog.clock($0.seconds)) }
                }
                Section("The Last Two Weeks") {
                    Chart(model.siteTimeLog.recent(days: 14), id: \.day) { entry in
                        BarMark(x: .value("Day", String(entry.day.suffix(5))), y: .value("Minutes", entry.seconds / 60)).foregroundStyle(Theme.accent)
                    }
                    .frame(height: 120)
                    .accessibilityLabel("Minutes on sites for each of the last 14 days")
                    ForEach(model.siteTimeLog.week(), id: \.day) { LabeledContent($0.day, value: SiteTimeLog.clock($0.seconds)) }
                }
                Section("Top Sites This Week") {
                    ForEach(model.siteTimeLog.topSites(days: 7).prefix(8), id: \.host) { LabeledContent($0.host, value: SiteTimeLog.clock($0.seconds)) }
                }
                Section { Button("Clear Time Data", role: .destructive) { model.clearSiteTime() } }
            }
        }
    }

    private var clipboard: some View {
        PanelList {
            Section {
                Toggle("Remember what I copy from Browser Setu", isOn: $model.keepClipboardHistory)
            } footer: { Text("Only links, citations and text copied with Browser Setu's own Copy commands, for 24 hours, in memory only: it is gone when you quit. It never reads the system clipboard.") }
            if model.keepClipboardHistory {
                Section {
                    if model.clipboardHistory.isEmpty { Text("Nothing copied yet.").foregroundStyle(.secondary) }
                    ForEach(model.clipboardHistory) { entry in
                        HStack {
                            VStack(alignment: .leading) { Text(entry.text).lineLimit(2); Text(entry.date.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary) }
                            Spacer()
                            Button("Copy") { copyToPasteboardQuietly(entry.text) }.buttonStyle(.borderless)
                        }
                    }
                    if !model.clipboardHistory.isEmpty { Button("Clear", role: .destructive) { model.clipboardHistory = [] } }
                }
            }
        }
    }
}

/// For a secret (a password, a two-factor code, a private note): it is kept out of the clipboard history, marked as concealed so clipboard managers skip it,
/// kept off the other devices' shared clipboard on iPhone, and, when `clearAfter` is given, removed again after that many seconds unless something else was
/// copied in the meantime.
@MainActor func copySecretToPasteboard(_ text: String, clearAfter seconds: TimeInterval? = nil) {
    #if os(macOS)
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(text, forType: .string)
    board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    guard let seconds else { return }
    let mine = board.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() } }
    #else
    var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
    if let seconds { options[.expirationDate] = Date().addingTimeInterval(seconds) }
    UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: options)
    #endif
}

@MainActor func copyToPasteboardQuietly(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

extension BrowserModel {
    @MainActor func loadFeedsIfNeeded() { if !feedsLoaded { feedsLoaded = true; loadFeeds(); loadMoreTools() } }
}
