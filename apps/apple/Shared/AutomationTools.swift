import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Text work on what is on the clipboard or pasted in. Each step is a fixed, named operation; none runs code, and nothing leaves the device.
enum ClipboardTransforms {
    enum Kind: String, CaseIterable, Identifiable {
        case cleanLinks, extractLinks, dedupeLines, sortLines, trimLines, plainText
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cleanLinks: "Remove Tracking from Links"
            case .extractLinks: "Keep Only the Links"
            case .dedupeLines: "Remove Repeated Lines"
            case .sortLines: "Sort Lines"
            case .trimLines: "Trim Spaces and Blank Lines"
            case .plainText: "Plain Text"
            }
        }
    }

    /// Web addresses in some text, in order, once each, without the punctuation that follows them in a sentence.
    static func links(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+") else { return [] }
        var seen = Set<String>(), out: [URL] = []
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var s = String(text[r])
            while let last = s.last, ".,;:!?)]}".contains(last) { s.removeLast() }
            if let url = URL(string: s), url.host != nil, seen.insert(s).inserted { out.append(url) }
        }
        return out
    }

    static func apply(_ kind: Kind, to text: String) -> String {
        switch kind {
        case .cleanLinks:
            var out = text
            for url in links(in: text) { if let cleaned = TrackingParameters.clean(url), cleaned != url { out = out.replacingOccurrences(of: url.absoluteString, with: cleaned.absoluteString) } }
            return out
        case .extractLinks: return links(in: text).map(\.absoluteString).joined(separator: "\n")
        case .dedupeLines:
            var seen = Set<String>()
            return text.components(separatedBy: "\n").filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .sortLines: return text.components(separatedBy: "\n").sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        case .trimLines: return text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        case .plainText: return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\u{00A0}", with: " ")
        }
        }
}

enum WorkflowTransfer {
    static let maxWorkflows = 50

    /// A shareable copy of workflows. Only the steps are in it: names, kinds and values.
    static func export(_ list: [Workflow]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(list), encoding: .utf8)) ?? "[]"
    }

    /// Reads workflows someone sent. Anything not valid is left out, and a step that runs a command is kept only if it is one of the safe ones.
    static func parse(_ text: String, safeCommands: Set<String>) -> (valid: [Workflow], skipped: Int) {
        guard let data = text.data(using: .utf8), let list = try? JSONDecoder().decode([Workflow].self, from: data) else { return ([], 0) }
        var valid: [Workflow] = [], skipped = 0
        for flow in list.prefix(maxWorkflows) {
            let ok = flow.isValid && flow.steps.allSatisfy { $0.kind != .command || safeCommands.contains($0.value) }
            if ok { valid.append(flow) } else { skipped += 1 }
        }
        return (valid, skipped)
    }
}

struct WorkflowRun: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var date = Date()
    var steps: Int
    var source: String
}

@MainActor
func pasteboardText() -> String? {
    #if os(macOS)
    NSPasteboard.general.string(forType: .string)
    #else
    UIPasteboard.general.string
    #endif
}

@MainActor
extension BrowserModel {
    /// Opens each address in its own tab. More than ten asks first, because a page or a pasted list can hold hundreds.
    func openLinks(_ urls: [URL], background: Bool = true) async {
        guard !urls.isEmpty else { notice = "There are no web addresses to open."; return }
        if urls.count > 10 {
            let go = await Dialogs.choose(title: "Open \(urls.count) pages?", message: "Each one opens in its own tab.", buttons: ["Open \(min(urls.count, 50))", "Cancel"])
            guard go == 0 else { return }
        }
        var first: TabController?
        for url in urls.prefix(50) {
            let tab = openTab(url: url, isPrivate: false, select: false)
            if first == nil { first = tab }
        }
        if !background, let first { select(first.id) }
        notice = "Opened \(min(urls.count, 50)) page\(min(urls.count, 50) == 1 ? "" : "s")."
    }

    func openLinksFromClipboard() async {
        guard let text = pasteboardText() else { notice = "The clipboard has no text."; return }
        await openLinks(ClipboardTransforms.links(in: text))
    }

    func transformClipboard(_ kind: ClipboardTransforms.Kind) {
        guard let text = pasteboardText(), !text.isEmpty else { notice = "The clipboard has no text."; return }
        let result = ClipboardTransforms.apply(kind, to: text)
        copyToPasteboard(result)
        notice = result == text ? "\(kind.title): nothing to change." : "\(kind.title): the clipboard now holds the result."
    }

    // MARK: Batch bookmarks

    func tagAll(_ items: [BookmarkItem], tag: String) {
        let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 30 else { return }
        var map = bookmarkTags
        for item in items { var tags = map[item.url] ?? []; if !tags.contains(clean) { tags.append(clean) }; map[item.url] = tags }
        setBookmarkTags(map)
        notice = "Tagged \(items.count) bookmark\(items.count == 1 ? "" : "s") “\(clean)”."
    }

    func moveAll(_ items: [BookmarkItem], toFolder folder: String) {
        let clean = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 60 else { return }
        for item in items { try? core.addBookmark(url: item.url, title: item.title, folder: clean) }
        refreshBookmarkState()
        notice = "Moved \(items.count) bookmark\(items.count == 1 ? "" : "s")\(clean.isEmpty ? "" : " to “\(clean)”")."
    }
}

struct AutomationExtrasSection: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var bench: Workbench
    @State private var several = ""
    @State private var transferText = ""
    @State private var note: String?

    var body: some View {
        Group {
            Section {
                TextEditor(text: $several).font(.system(.callout, design: .monospaced)).frame(height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                HStack {
                    Button("Open These Links") { Task { await model.openLinks(ClipboardTransforms.links(in: several)) } }.disabled(ClipboardTransforms.links(in: several).isEmpty)
                    Button("Open Links from the Clipboard") { Task { await model.openLinksFromClipboard() } }
                }
            } header: { Text("Open Several Pages") } footer: { Text("Paste any text with web addresses; each address opens in its own tab, in the background. More than ten asks first.") }
            Section {
                ForEach(ClipboardTransforms.Kind.allCases) { kind in
                    Button(kind.title) { model.transformClipboard(kind) }
                }
            } header: { Text("Clipboard") } footer: { Text("Changes the text on the clipboard. Nothing is sent anywhere, and nothing runs code.") }
            Section {
                Picker("Run when the app opens", selection: Binding(get: { bench.startupWorkflow ?? "" }, set: { bench.setStartupWorkflow($0.isEmpty ? nil : $0) })) {
                    Text("Nothing").tag("")
                    ForEach(bench.workflows) { Text($0.name).tag($0.id) }
                }
                if bench.workflowHistory.isEmpty { Text("No workflow has run yet.").foregroundStyle(.secondary) }
                ForEach(bench.workflowHistory.prefix(10)) { run in
                    Text("\(run.name) · \(run.steps) steps · \(run.source) · \(run.date.formatted(.relative(presentation: .named)))").font(.caption)
                }
            } header: { Text("Workflow Start and History") }
            Section {
                HStack {
                    Button("Copy My Workflows") { copyToPasteboard(WorkflowTransfer.export(bench.workflows)); note = "Copied \(bench.workflows.count) workflow\(bench.workflows.count == 1 ? "" : "s")." }.disabled(bench.workflows.isEmpty)
                    Button("Import from the Clipboard") {
                        let result = WorkflowTransfer.parse(pasteboardText() ?? "", safeCommands: Workbench.safeCommands)
                        var added = 0
                        for flow in result.valid where bench.addWorkflow(flow) { added += 1 }
                        note = "Added \(added) workflow\(added == 1 ? "" : "s")" + (result.skipped > 0 ? ", skipped \(result.skipped) that were invalid or used a command a workflow may not run." : ".")
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("Share Workflows") } footer: { Text("Only the steps are shared. An imported workflow can use only the safe commands, and it never runs by itself.") }
        }
    }
}
