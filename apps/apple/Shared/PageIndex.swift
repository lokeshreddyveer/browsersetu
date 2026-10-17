import Foundation
import SQLite3
import SwiftUI

/// One page found in the searchable copy of what you have read.
struct PageHit: Identifiable, Equatable {
    var id: String { url }
    var url: String
    var title: String
    var snippet: String
    var visited: Date
}

/// A private, on-device full-text index of the pages you read, kept in a file inside this profile's folder. It never leaves the device
/// and is never used by anything but the search box on your own screen.
final class PageIndex {
    private var db: OpaquePointer?
    private var readDB: OpaquePointer?
    /// Writes run one at a time on this queue and never make the caller wait; searches use their own connection, so typing in the address bar is never held up
    /// by a page being saved.
    private let queue = DispatchQueue(label: "pageindex")
    private let readQueue = DispatchQueue(label: "pageindex.read")

    init?(folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("pages.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return nil }
        let create = "CREATE VIRTUAL TABLE IF NOT EXISTS pages USING fts5(url UNINDEXED, title, host, body, visited UNINDEXED, tokenize='unicode61 remove_diacritics 2');"
        guard sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        sqlite3_exec(db, "PRAGMA secure_delete = ON;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)
        sqlite3_open_v2(path, &readDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
    }

    deinit { sqlite3_close(readDB); sqlite3_close(db) }

    /// Turns what was typed into a query that cannot be anything but words: each word must start a word in the page.
    static func matchQuery(_ text: String) -> String? {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !$0.isEmpty }.prefix(8)
        return words.isEmpty ? nil : words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    func upsert(url: String, title: String, host: String, body: String, visited: Date = Date()) {
        queue.async { [self] in
            run("DELETE FROM pages WHERE url = ?;", [url])
            run("INSERT INTO pages (url, title, host, body, visited) VALUES (?, ?, ?, ?, ?);", [url, title, host, String(body.prefix(60000)), String(visited.timeIntervalSince1970)])
        }
    }

    func search(_ text: String, limit: Int = 20) -> [PageHit] {
        guard let match = Self.matchQuery(text), let db = readDB ?? db else { return [] }
        return readQueue.sync {
            var statement: OpaquePointer?
            let sql = "SELECT url, title, snippet(pages, 3, '', '', '…', 14), visited FROM pages WHERE pages MATCH ? ORDER BY bm25(pages, 0, 6, 3, 1) LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, match, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var hits: [PageHit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                func col(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
                hits.append(PageHit(url: col(0), title: col(1), snippet: col(2).replacingOccurrences(of: "\n", with: " "),
                                    visited: Date(timeIntervalSince1970: Double(col(3)) ?? 0)))
            }
            return hits
        }
    }

    /// Waits for every write queued so far (tests, and anything that must see the result).
    func flush() { queue.sync {} }

    /// A search that first waits for queued writes, so it sees everything saved before it.
    func searchAfterWrites(_ text: String, limit: Int = 20) -> [PageHit] { flush(); return search(text, limit: limit) }

    var count: Int {
        queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM pages;", -1, &statement, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
        }
    }

    func remove(url: String) { queue.sync { run("DELETE FROM pages WHERE url = ?;", [url]) } }

    func removeHost(_ host: String) { queue.sync { run("DELETE FROM pages WHERE host = ?;", [host]) } }

    func removeAll() {
        queue.sync {
            run("DELETE FROM pages;", [])
            sqlite3_exec(db, "INSERT INTO pages(pages) VALUES('optimize'); VACUUM;", nil, nil, nil)
        }
    }

    /// Drops what is older than the limit, then the oldest of the rest until no more than `maxPages` remain.
    func prune(olderThan days: Int, maxPages: Int, now: Date = Date()) {
        queue.sync {
            let cutoff = now.addingTimeInterval(-Double(days) * 86400).timeIntervalSince1970
            run("DELETE FROM pages WHERE CAST(visited AS REAL) < ?;", [String(cutoff)])
            run("DELETE FROM pages WHERE rowid IN (SELECT rowid FROM pages ORDER BY CAST(visited AS REAL) DESC LIMIT -1 OFFSET ?);", [String(maxPages)])
        }
    }

    private func run(_ sql: String, _ values: [String]) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT) }
        sqlite3_step(statement)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum PageIndexRules {
    static let maxPages = 4000
    /// Words in a page's address that suggest account, payment or sign-in pages. These are never copied.
    static let sensitiveWords = ["login", "signin", "sign-in", "logon", "password", "passwd", "account", "checkout", "payment", "billing", "bank", "wallet", "oauth", "auth", "session", "verify", "2fa", "otp"]

    static func shouldIndex(_ url: URL, excludedHosts: Set<String>) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased(), !host.isEmpty, host != "localhost" else { return false }
        if excludedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        let path = (url.path + " " + host).lowercased()
        return !sensitiveWords.contains { path.contains($0) }
    }
}

extension BrowserModel {
    var pageIndex: PageIndex? {
        if let existing = pageIndexStore { return existing }
        pageIndexStore = PageIndex(folder: profileFolder.appendingPathComponent("search", isDirectory: true))
        return pageIndexStore
    }

    /// Copies the text of the page that just loaded, if the person turned this on and the page is an ordinary one.
    func indexPageIfAllowed(_ tab: TabController) {
        guard indexPages, !tab.isPrivate, let url = tab.url, PageIndexRules.shouldIndex(url, excludedHosts: indexExcludedHosts) else { return }
        let generation = indexGeneration
        let profile = profileName
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard tab.url == url, !tab.isLoading, let engine = tab.engine else { return }
            if await engine.pageHasSensitiveForm() { return }
            guard let text = await engine.pageText(), text.count > 120 else { return }
            // Everything is checked again at the moment of saving: the person may have turned this off, excluded the site, switched profile or opened it
            // privately while the page's text was being read.
            guard generation == indexGeneration, profile == profileName, indexPages, !tab.isPrivate, tab.url == url, !tab.isLoading,
                  PageIndexRules.shouldIndex(url, excludedHosts: indexExcludedHosts), !Task.isCancelled else { return }
            var clean = URLComponents(url: TrackingParameters.clean(url) ?? url, resolvingAgainstBaseURL: false)
            clean?.fragment = nil
            pageIndex?.upsert(url: clean?.string ?? url.absoluteString, title: tab.title, host: url.host ?? "", body: text)
            if Int.random(in: 0..<25) == 0 { pageIndex?.prune(olderThan: indexRetentionDays, maxPages: PageIndexRules.maxPages) }
            indexCount = pageIndex?.count ?? 0
        }
    }

    /// Anything queued before this is dropped at its moment of saving.
    func cancelPendingIndexing() { indexGeneration += 1 }

    func eraseSearchableCopy() {
        cancelPendingIndexing()
        pageIndex?.removeAll()
        indexCount = 0
    }
}

struct PageSearchView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var query = ""
    @State private var hits: [PageHit] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search words inside pages you have read", text: $query).textFieldStyle(.plain).focused($focused)
            }
            .padding(12)
            Divider()
            if !model.indexPages {
                ContentUnavailableView {
                    Label("Search Is Off", systemImage: "magnifyingglass")
                } description: {
                    Text("Turn on a searchable copy of the pages you read, kept only on this device, to find words inside them later. Nothing is stored from private tabs or from sign-in, payment and account pages.")
                } actions: {
                    Button("Turn On") { model.indexPages = true }.buttonStyle(.borderedProminent)
                }
            } else if query.isEmpty {
                ContentUnavailableView("\(model.indexCount) pages saved", systemImage: "doc.text.magnifyingglass", description: Text("Type a few words you remember from a page."))
            } else if hits.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(hits) { hit in
                    Button { model.sheet = nil; model.open(urlString: hit.url, newTab: true) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.title.isEmpty ? hit.url : hit.title).fontWeight(.medium).lineLimit(1)
                            Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            Text(displayHost(URL(string: hit.url)) + " · " + hit.visited.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { Button("Forget This Page", role: .destructive) { model.pageIndex?.remove(url: hit.url); hits.removeAll { $0.id == hit.id } } }
                }
            }
        }
        .onAppear { focused = true; model.indexCount = model.pageIndex?.count ?? 0 }
        .onChange(of: query) { _, text in hits = model.pageIndex?.search(text) ?? [] }
        .accessibilityIdentifier("page-search")
    }
}

struct SearchableCopySection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Keep a searchable copy of pages I visit", isOn: $model.indexPages)
            if model.indexPages {
                Picker("Keep for", selection: $model.indexRetentionDays) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }
                Button("Search My Pages…") { model.sheet = .pageSearch }
            }
            LabeledContent("Pages saved", value: "\(model.indexCount)")
            Button("Erase the Searchable Copy", role: .destructive) { model.eraseSearchableCopy() }.disabled(model.indexCount == 0)
            Text("Lets you find words inside pages you read, from the address bar or Search My Pages. Stays on this device, is never uploaded, and skips private tabs, sign-in, payment and account pages. Clearing browsing data erases it too.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Search My Pages") }
        .onAppear { model.indexCount = model.pageIndex?.count ?? 0 }
    }
}
