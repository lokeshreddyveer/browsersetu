import CryptoKit
import Foundation
import SwiftUI

/// A copy of a page's text that you chose to keep, so a later visit can show what changed.
struct PageSnapshot: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var title: String
    var text: String
}

/// A page you asked to be told about when it changes. Checked when you open it, never in the background.
struct PageWatch: Codable, Equatable {
    var title: String
    var digest: String
    var firstPrice: Double?
    var checked: Date
}

struct DiffLine: Identifiable, Equatable {
    enum Kind { case same, added, removed }
    let id = UUID()
    var kind: Kind
    var text: String
}

enum TextDiff {
    /// Line-by-line differences, with unchanged lines kept so the changes can be read in place.
    static func compare(old: String, new: String) -> [DiffLine] {
        func lines(_ s: String) -> [String] { s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        let a = lines(old), b = lines(new)
        let difference = b.difference(from: a)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change { case .remove(let offset, _, _): removed.insert(offset); case .insert(let offset, _, _): inserted.insert(offset) }
        }
        var result: [DiffLine] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) { result.append(DiffLine(kind: .removed, text: a[i])); i += 1 }
            else if j < b.count, inserted.contains(j) { result.append(DiffLine(kind: .added, text: b[j])); j += 1 }
            else if i < a.count, j < b.count { result.append(DiffLine(kind: .same, text: b[j])); i += 1; j += 1 }
            else if i < a.count { i += 1 } else { j += 1 }
        }
        return result
    }

    static func changeCount(_ diff: [DiffLine]) -> Int { diff.filter { $0.kind != .same }.count }
}

enum PriceFinder {
    private static let pattern = NSRegularExpression.fixed(#"[$€£₹]\s?(\d{1,3}(?:,\d{3})+(?:\.\d{2})?|\d+(?:\.\d{2})?)"#)

    /// The first price written in the text, as a number. The first price on a product page is usually the one for sale.
    static func firstPrice(in text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range), let r = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[r].replacingOccurrences(of: ",", with: ""))
    }
}

enum WatchCheck: Equatable {
    case unchanged, changed, priceDropped(from: Double, to: Double)

    static func evaluate(watch: PageWatch, newText: String) -> WatchCheck {
        let digest = PageDigest.of(newText)
        if let old = watch.firstPrice, let new = PriceFinder.firstPrice(in: newText), new < old { return .priceDropped(from: old, to: new) }
        return digest == watch.digest ? .unchanged : .changed
    }
}

enum PageDigest {
    /// Ignores whitespace so a re-flowed page does not count as a change.
    static func of(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return SHA256.hash(data: Data(flat.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension BrowserModel {
    static let maxSnapshotsPerPage = 10

    func saveSnapshot() async {
        guard let tab = active, !tab.isPrivate, let url = tab.url, let key = PageMemoryKey.key(for: url), let text = await tab.engine.pageText() else {
            notice = "Snapshots are not kept for private tabs or this kind of page."; return
        }
        var list = pageSnapshots[key] ?? []
        list.insert(PageSnapshot(date: Date(), title: tab.title, text: String(text.prefix(40000))), at: 0)
        pageSnapshots[key] = Array(list.prefix(Self.maxSnapshotsPerPage))
        if pageSnapshots.count > 60, let oldest = pageSnapshots.min(by: { ($0.value.first?.date ?? .distantPast) < ($1.value.first?.date ?? .distantPast) })?.key { pageSnapshots[oldest] = nil }
        notice = "Snapshot saved."
    }

    func toggleWatch() async {
        guard let tab = active, !tab.isPrivate, let url = tab.url, let key = PageMemoryKey.key(for: url) else { return }
        if watchedPages[key] != nil { watchedPages[key] = nil; notice = "No longer watching this page."; return }
        guard let text = await tab.engine.pageText() else { return }
        watchedPages[key] = PageWatch(title: tab.title, digest: PageDigest.of(text), firstPrice: PriceFinder.firstPrice(in: text), checked: Date())
        notice = "Watching this page. You will be told when you next open it if it changed or the price dropped."
    }

    var isWatchingActivePage: Bool {
        guard let url = active?.url, let key = PageMemoryKey.key(for: url) else { return false }
        return watchedPages[key] != nil
    }

    /// A watched page just finished loading: compare it with what was seen last.
    func watchDidLoad(_ tab: TabController) {
        guard !tab.isPrivate, let url = tab.url, let key = PageMemoryKey.key(for: url), let watch = watchedPages[key] else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard tab.url == url, let text = await tab.engine.pageText() else { return }
            switch WatchCheck.evaluate(watch: watch, newText: text) {
            case .unchanged: break
            case .changed: notice = "This page has changed since you last looked."
            case .priceDropped(let from, let to): notice = "Price dropped from \(from.formatted()) to \(to.formatted())."
            }
            watchedPages[key] = PageWatch(title: tab.title, digest: PageDigest.of(text), firstPrice: PriceFinder.firstPrice(in: text) ?? watch.firstPrice, checked: Date())
        }
    }
}

struct PageVersionsView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var current = ""
    @State private var picked: PageSnapshot?

    private var key: String? { model.active?.url.flatMap(PageMemoryKey.key(for:)) }
    private var snapshots: [PageSnapshot] { key.flatMap { model.pageSnapshots[$0] } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("Save Snapshot") { Task { await model.saveSnapshot() } }
                Button(model.isWatchingActivePage ? "Stop Watching" : "Watch This Page") { Task { await model.toggleWatch() } }
            }
            .buttonStyle(.bordered).padding(.horizontal, 12).padding(.top, 10)
            if snapshots.isEmpty {
                ContentUnavailableView("No Snapshots", systemImage: "clock.arrow.circlepath", description: Text("Save a snapshot now, and compare it with the page on a later visit. Watching a page tells you when you open it again and it has changed."))
            } else if let picked {
                let diff = TextDiff.compare(old: picked.text, new: current)
                HStack {
                    Text("\(TextDiff.changeCount(diff)) changes since \(picked.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Back") { self.picked = nil }.controlSize(.small)
                }
                .padding(.horizontal, 12)
                List(diff) { line in
                    Text(line.text).font(.callout)
                        .foregroundStyle(line.kind == .same ? Color.secondary : Color.primary)
                        .strikethrough(line.kind == .removed)
                        .listRowBackground(line.kind == .added ? Color.green.opacity(0.18) : line.kind == .removed ? Color.red.opacity(0.18) : Color.clear)
                }
            } else {
                List(snapshots) { snap in
                    Button { Task { current = await model.active?.engine.pageText() ?? ""; picked = snap } } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(snap.date.formatted(date: .abbreviated, time: .shortened))
                            Text("Compare with the page now").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
