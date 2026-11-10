import SwiftUI
import UniformTypeIdentifiers

/// What can be brought over from another browser, and how each is exported there. One list, used by the setup assistant, the import sheet (start page, empty panels) and Settings.
///
/// Browser Setu reads the files other browsers can export; it does not read another browser's own profile folder. Open tabs cannot be brought over at all:
/// tabs sync between your own Browser Setu devices (Settings ▸ Sync), not from another browser.
enum ImportKind: String, CaseIterable, Identifiable, Sendable {
    case bookmarks, passwords, history
    var id: String { rawValue }

    var title: String {
        switch self { case .bookmarks: "Bookmarks"; case .passwords: "Passwords"; case .history: "History" }
    }
    var symbol: String {
        switch self { case .bookmarks: "star.fill"; case .passwords: "key.fill"; case .history: "clock.fill" }
    }
    var summary: String {
        switch self {
        case .bookmarks: "The HTML file that Safari, Chrome, Edge, Brave and Firefox can export."
        case .passwords: "The CSV file from Chrome, Edge, Brave, Firefox or Apple’s Passwords app."
        case .history: "The JSON file from Safari’s Export Browsing History, or the “Browser History” file from a Google Takeout export of Chrome."
        }
    }
    /// Where to find the export in each browser, in plain words.
    var howToExport: String {
        switch self {
        case .bookmarks: "Safari: File ▸ Export ▸ Bookmarks. Chrome, Edge or Brave: Bookmark Manager ▸ ⋮ ▸ Export bookmarks. Firefox: Bookmarks ▸ Manage Bookmarks ▸ Import and Backup ▸ Export Bookmarks to HTML."
        case .passwords: "Chrome, Edge or Brave: Settings ▸ Passwords ▸ ⋮ ▸ Export passwords. Firefox: Passwords ▸ ⋯ ▸ Export Logins. Safari: use Apple’s Passwords app, File ▸ Export All Passwords. The file is plain text, so delete it when you are done. Sites that start with http (not https) are never imported."
        case .history: "Safari: File ▸ Export Browsing History…. Chrome: go to takeout.google.com, choose only Chrome ▸ Browser History, and download the export. Firefox history cannot be imported."
        }
    }
    var contentTypes: [UTType] {
        switch self { case .bookmarks: [.html]; case .passwords: [.commaSeparatedText, .plainText]; case .history: [.json] }
    }
}

/// The three imports, as one implementation. Reading and parsing happen off the main thread; the result is a sentence for the person.
@MainActor
enum ImportActions {
    static func run(_ kind: ImportKind, from url: URL, model: BrowserModel) async -> String {
        switch kind {
        case .bookmarks: return await bookmarks(from: url, model: model)
        case .passwords: return await passwords(from: url, model: model)
        case .history: return await history(from: url, model: model)
        }
    }

    static func bookmarks(from url: URL, model: BrowserModel) async -> String {
        let parsed: [BookmarkHTML.Entry]? = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 50_000_000 else { return nil }
            return BookmarkHTML.parse(String(decoding: data, as: UTF8.self))
        }.value
        guard let parsed else { return "That file could not be read." }
        let r = await model.importBookmarks(entries: parsed)
        return r.added == 0 && r.skipped == 0 ? "No bookmarks were found in that file."
            : "Imported \(r.added) bookmark\(r.added == 1 ? "" : "s")" + (r.skipped > 0 ? ", skipped \(r.skipped) already saved." : ".")
    }

    static func passwords(from url: URL, model: BrowserModel) async -> String {
        let text: String? = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
        guard let text else { return "That file could not be read." }
        let r = model.importPasswords(csv: text)
        var message = "Imported \(r.added) password\(r.added == 1 ? "" : "s")."
        if r.skippedInsecure > 0 { message += " \(r.skippedInsecure) for http sites were left out." }
        if r.skippedDuplicate > 0 { message += " \(r.skippedDuplicate) were already saved." }
        if r.added > 0 { message += " Delete the file you imported: it is plain text." }
        return message
    }

    static func history(from url: URL, model: BrowserModel) async -> String {
        let visits: [HistoryImport.Visit]? = await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 400_000_000 else { return nil }
            return HistoryImport.parse(json: data)
        }.value
        guard let visits else { return "That file could not be read." }
        let count = await model.importHistory(visits)
        return count == 0 ? "No web pages were found in that file." : "Imported \(count) page\(count == 1 ? "" : "s") of history."
    }
}

/// One import: what it is, how to export it from the other browser (one tap away), a button that opens the file picker, and what happened.
struct ImportCard: View {
    let kind: ImportKind
    @EnvironmentObject private var model: BrowserModel
    @State private var picking = false
    @State private var working = false
    @State private var status: String?
    @State private var showHow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: kind.symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title).font(.system(size: 13.5, weight: .semibold))
                    Text(kind.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(showHow ? "Hide how to export" : "How do I export this?") { withAnimation(.easeOut(duration: 0.2)) { showHow.toggle() } }
                        .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    if showHow {
                        Text(kind.howToExport).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                Button(working ? "Importing…" : "Choose File…") { picking = true }
                    .disabled(working)
                    .accessibilityLabel("Choose a file to import \(kind.title.lowercased())")
            }
            if let status {
                Label(status, systemImage: "checkmark.circle").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(status)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .setupRowSurface()
        .accessibilityElement(children: .contain)
        .fileImporter(isPresented: $picking, allowedContentTypes: kind.contentTypes) { result in
            guard case .success(let url) = result else { return }
            working = true
            Task {
                let message = await ImportActions.run(kind, from: url, model: model)
                working = false
                withAnimation(.easeOut(duration: 0.2)) { status = message }
                model.notice = message
            }
        }
    }
}

/// The three imports in a sheet: opened from the start page and from the empty Bookmarks and History panels.
struct ImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Bring your things from another browser").font(.system(size: 20, weight: .semibold, design: .rounded)).accessibilityAddTraits(.isHeader)
                Text("Export from the other browser, then choose the file here. Everything is read on this device and nothing is sent anywhere.").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            ForEach(ImportKind.allCases) { ImportCard(kind: $0) }
            Text("Open tabs cannot be moved from another browser. Browser Setu keeps your tabs the same between your own devices, in Settings ▸ Sync.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 560)
        #endif
    }
}
