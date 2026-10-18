import Foundation
import SwiftUI

// MARK: Bookmark housekeeping

struct SmartCollection: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
    var items: [BookmarkItem]
}

enum BookmarkTools {
    /// The address with what does not change the page taken off: case in the scheme and host, "www.", the fragment and a trailing slash.
    static func key(_ address: String) -> String {
        guard var parts = URLComponents(string: address) else { return address.lowercased() }
        parts.scheme = parts.scheme?.lowercased()
        var host = parts.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        parts.host = host
        parts.fragment = nil
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        parts.path = path == "/" ? "" : path
        return parts.string ?? address.lowercased()
    }

    /// Groups of bookmarks that point to the same page, the oldest first in each group.
    static func duplicates(_ items: [BookmarkItem]) -> [[BookmarkItem]] {
        Dictionary(grouping: items, by: { key($0.url) }).values
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.created < $1.created } }
            .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
    }

    /// Collections the browser works out by itself: when a bookmark was added, which have no tag, each tag, and websites with several bookmarks.
    static func smartCollections(_ items: [BookmarkItem], tags: [String: [String]], now: Date = Date()) -> [SmartCollection] {
        var out: [SmartCollection] = []
        let week = Int64(now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970), month = Int64(now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970)
        let newest = items.sorted { $0.created > $1.created }
        let thisWeek = newest.filter { $0.created >= week }
        if !thisWeek.isEmpty { out.append(SmartCollection(id: "week", title: "Added this week", symbol: "clock", items: thisWeek)) }
        let thisMonth = newest.filter { $0.created >= month }
        if thisMonth.count > thisWeek.count { out.append(SmartCollection(id: "month", title: "Added this month", symbol: "calendar", items: thisMonth)) }
        let untagged = newest.filter { (tags[$0.url] ?? []).isEmpty }
        if !untagged.isEmpty, untagged.count < items.count { out.append(SmartCollection(id: "untagged", title: "Without a tag", symbol: "tag.slash", items: untagged)) }
        for tag in Set(tags.values.flatMap { $0 }).sorted() {
            let tagged = newest.filter { (tags[$0.url] ?? []).contains(tag) }
            if !tagged.isEmpty { out.append(SmartCollection(id: "tag-\(tag)", title: "Tagged “\(tag)”", symbol: "tag", items: tagged)) }
        }
        let bySite = Dictionary(grouping: newest, by: { site(of: $0.url) })
        for (host, list) in bySite.filter({ !$0.key.isEmpty && $0.value.count >= 3 }).sorted(by: { $0.value.count > $1.value.count }).prefix(6) {
            out.append(SmartCollection(id: "site-\(host)", title: host, symbol: "globe", items: list))
        }
        return out
    }

    static func site(of address: String) -> String {
        var host = URL(string: address)?.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

enum LinkHealth: Equatable {
    case ok
    /// Gone for certain: the page or the site no longer exists.
    case broken(String)
    /// Could not tell: the site refused, was slow or was down for a moment.
    case unsure(String)
}

enum LinkChecker {
    static func classify(status: Int?, error: URLError.Code?) -> LinkHealth {
        if let status {
            switch status {
            case 200..<400: return .ok
            case 404, 410: return .broken("Page not found (\(status))")
            case 401, 403, 429, 999: return .unsure("The site refused the check (\(status))")
            case 500...: return .unsure("The site had an error (\(status))")
            default: return .unsure("Answered \(status)")
            }
        }
        switch error {
        case .cannotFindHost?, .dnsLookupFailed?: return .broken("The website no longer exists")
        case .timedOut?: return .unsure("The site did not answer")
        case .notConnectedToInternet?, .networkConnectionLost?: return .unsure("No connection")
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateHasUnknownRoot?: return .unsure("The site's certificate has a problem")
        case .cannotConnectToHost?: return .unsure("The site refused the connection")
        default: return .unsure("Could not be reached")
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Asks the website itself, without cookies or a referrer. HEAD first; sites that do not allow it are asked with GET.
    static func check(_ address: String) async -> LinkHealth {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .unsure("Not a web address") }
        func ask(_ method: String) async -> (Int?, URLError.Code?) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            do {
                let (_, response) = try await session.data(for: request)
                return ((response as? HTTPURLResponse)?.statusCode, nil)
            } catch { return (nil, (error as? URLError)?.code) }
        }
        var (status, error) = await ask("HEAD")
        if let s = status, [400, 403, 405, 501].contains(s) { (status, error) = await ask("GET") }
        return classify(status: status, error: error)
    }
}

// MARK: History retention

enum HistoryRetention {
    static let choices = [0, 7, 30, 90, 365]
    static func title(_ days: Int) -> String { days == 0 ? "Forever" : (days == 365 ? "1 year" : "\(days) days") }

    /// The addresses whose last visit is older than the limit.
    static func expired(_ items: [HistoryItem], days: Int, now: Date = Date()) -> [String] {
        guard days > 0 else { return [] }
        let cutoff = Int64(now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970)
        return items.filter { $0.lastVisit < cutoff }.map(\.url)
    }
}

@MainActor
extension BrowserModel {
    /// Removes history older than the chosen limit. Bookmarks, downloads and saved articles are never touched.
    @discardableResult
    func applyHistoryRetention() -> Int {
        guard historyRetentionDays > 0, let all = try? core.recentHistory(limit: 100_000) else { return 0 }
        let old = HistoryRetention.expired(all, days: historyRetentionDays)
        for url in old { try? core.deleteHistoryEntry(url: url) }
        return old.count
    }

    func removeBookmarks(_ items: [BookmarkItem]) {
        for item in items { try? core.removeBookmark(url: item.url) }
        refreshBookmarkState()
    }
}

struct HistoryRetentionSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Picker("Keep browsing history for", selection: $model.historyRetentionDays) {
                ForEach(HistoryRetention.choices, id: \.self) { Text(HistoryRetention.title($0)).tag($0) }
            }
            .onChange(of: model.historyRetentionDays) { _, _ in
                let removed = model.applyHistoryRetention()
                if removed > 0 { model.notice = "Removed \(removed) older history entr\(removed == 1 ? "y" : "ies")." }
            }
        } header: { Text("History") } footer: {
            Text("Older entries are removed when the app starts and when you change this. Bookmarks, downloads and saved articles are kept.")
        }
    }
}

// MARK: The screen

struct BookmarkToolsView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var bookmarks: [BookmarkItem] = []
    @State private var checking = false
    @State private var checked = 0
    @State private var results: [String: LinkHealth] = [:]
    @State private var task: Task<Void, Never>?

    private var duplicates: [[BookmarkItem]] { BookmarkTools.duplicates(bookmarks) }
    private var broken: [BookmarkItem] { bookmarks.filter { if case .broken = results[$0.url] { return true } else { return false } } }
    private var unsure: [BookmarkItem] { bookmarks.filter { if case .unsure = results[$0.url] { return true } else { return false } } }

    var body: some View {
        List {
            Section("Smart Collections") {
                let collections = BookmarkTools.smartCollections(bookmarks, tags: model.bookmarkTags)
                if collections.isEmpty { Text("Collections appear as you save and tag bookmarks.").foregroundStyle(.secondary) }
                ForEach(collections) { collection in
                    DisclosureGroup {
                        HStack {
                            Button("Tag All…") { Task { @MainActor in if let t = await Dialogs.promptText(title: "Tag \(collection.items.count) Bookmarks", message: "Tag name.", placeholder: ""), !t.isEmpty { model.tagAll(collection.items, tag: t) } } }
                            Button("Move All to Folder…") { Task { @MainActor in if let f = await Dialogs.promptText(title: "Move \(collection.items.count) Bookmarks", message: "Folder name.", placeholder: ""), !f.isEmpty { model.moveAll(collection.items, toFolder: f); reload() } } }
                            Button("Remove All", role: .destructive) { Task { @MainActor in if await Dialogs.choose(title: "Remove \(collection.items.count) bookmarks?", message: "This cannot be undone.", buttons: ["Remove", "Cancel"]) == 0 { model.removeBookmarks(collection.items); reload() } } }
                        }.buttonStyle(.bordered).controlSize(.small)
                        ForEach(collection.items.prefix(40), id: \.url) { item in
                            Button { model.open(urlString: item.url, newTab: true) } label: { row(item) }.buttonStyle(.plain)
                        }
                    } label: {
                        Label("\(collection.title) (\(collection.items.count))", systemImage: collection.symbol)
                    }
                }
            }
            Section {
                if duplicates.isEmpty { Label("No duplicates", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                ForEach(Array(duplicates.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group[0].title.isEmpty ? group[0].url : group[0].title).lineLimit(1)
                        Text("\(group.count) copies · \(BookmarkTools.site(of: group[0].url))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !duplicates.isEmpty {
                    Button("Remove \(duplicates.reduce(0) { $0 + $1.count - 1 }) Duplicates, Keep the Oldest") {
                        model.removeBookmarks(duplicates.flatMap { $0.dropFirst() })
                        reload()
                    }
                }
            } header: { Text("Duplicates") }
            Section {
                if checking { HStack { ProgressView(value: Double(checked), total: Double(max(bookmarks.count, 1))); Button("Stop") { task?.cancel() } } }
                else {
                    Button(results.isEmpty ? "Check for Broken Links" : "Check Again") { startCheck() }.disabled(bookmarks.isEmpty)
                }
                ForEach(broken, id: \.url) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title.isEmpty ? item.url : item.title).lineLimit(1)
                            if case .broken(let why) = results[item.url] { Text(why).font(.caption).foregroundStyle(.red) }
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { model.removeBookmarks([item]); reload() }.buttonStyle(.borderless)
                    }
                }
                if !broken.isEmpty { Button("Remove \(broken.count) Broken", role: .destructive) { model.removeBookmarks(broken); reload() } }
                if !unsure.isEmpty { DisclosureGroup("Could not tell (\(unsure.count))") {
                    ForEach(unsure, id: \.url) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title.isEmpty ? item.url : item.title).lineLimit(1)
                            if case .unsure(let why) = results[item.url] { Text(why).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } }
            } header: { Text("Broken Links") } footer: {
                Text("This contacts each bookmarked website once (no cookies, no referrer) from this device. A page is called broken only when the site says it is gone or the website no longer exists; a site that refuses or is slow is listed apart.")
            }
        }
        .onAppear(perform: reload)
        .onDisappear { task?.cancel() }
    }

    private func row(_ item: BookmarkItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title.isEmpty ? item.url : item.title).lineLimit(1)
            Text(BookmarkTools.site(of: item.url)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reload() { bookmarks = (try? model.core.listBookmarks(query: "")) ?? [] }

    private func startCheck() {
        results = [:]; checked = 0; checking = true
        let list = Array(bookmarks.prefix(500))
        task = Task {
            await withTaskGroup(of: (String, LinkHealth).self) { group in
                var next = 0
                func add() { if next < list.count { let url = list[next].url; next += 1; group.addTask { (url, await LinkChecker.check(url)) } } }
                for _ in 0..<min(6, list.count) { add() }
                for await (url, health) in group {
                    if Task.isCancelled { group.cancelAll(); break }
                    results[url] = health; checked += 1
                    add()
                }
            }
            checking = false
        }
    }
}
