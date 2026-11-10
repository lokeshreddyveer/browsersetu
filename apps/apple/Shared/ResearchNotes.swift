import SwiftUI

// Tags, duplicate detection that sees through tracking parameters and "www.", one flow that saves a page with a passage and a note together, and exports other note applications read
// (a folder of Markdown notes with their details at the top, as Obsidian and Joplin take them in, and ENEX, which Joplin and Evernote import). Nothing here is automatic: a page is
// only saved when the person chooses to, a private tab is never saved, and nothing leaves the device except as a file the person saves or shares.

enum ResearchURL {
    /// The address with what does not change the page taken off: the scheme and host in lower case, "www.", the fragment, default ports, a trailing slash, and the tracking parameters.
    /// Two saves of the same page, one from a shared link full of "utm_" and one typed by hand, have the same normalized address.
    static func normalize(_ text: String?) -> String? {
        guard let text, var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), var host = parts.host?.lowercased(),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return text?.trimmingCharacters(in: .whitespaces).lowercased() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        parts.scheme = scheme == "http" ? "https" : scheme
        parts.host = host
        // A plain anchor (#section) is the same page; a route (#/inbox, #!/x) is a different page of the same app, so it stays.
        if let fragment = parts.fragment, !(fragment.hasPrefix("/") || fragment.hasPrefix("!/")) { parts.fragment = nil }
        parts.user = nil; parts.password = nil
        if parts.port == 443 || parts.port == 80 { parts.port = nil }
        if let items = parts.queryItems {
            let kept = items.filter { !TrackingParameters.isTracking($0.name) }
            parts.queryItems = kept.isEmpty ? nil : kept.sorted { $0.name < $1.name }
        }
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        parts.path = path == "/" ? "" : path
        return parts.string
    }
}

enum ResearchTags {
    static let maxPerItem = 8, maxLength = 24

    /// Tags from what a person typed ("reading, to do; Work"): lower case, no "#", plain letters, digits and dashes, no empty ones, no repeats, a few of them.
    static func parse(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: { ",;\n".contains($0) }) {
            var tag = raw.trimmingCharacters(in: .whitespaces).lowercased()
            while tag.hasPrefix("#") { tag.removeFirst() }
            tag = String(tag.map { $0.isLetter || $0.isNumber ? $0 : ($0 == " " || $0 == "-" || $0 == "_" ? "-" : "\u{0}") }.filter { $0 != "\u{0}" }.prefix(maxLength))
            while tag.hasPrefix("-") { tag.removeFirst() }
            while tag.hasSuffix("-") { tag.removeLast() }
            if !tag.isEmpty, !out.contains(tag) { out.append(tag) }
            if out.count == maxPerItem { break }
        }
        return out
    }
}

extension ResearchStore {
    /// A page already saved in any collection, found by its normalized address.
    func duplicate(ofURL url: String?) -> (collection: ResearchCollection, item: ResearchItem)? {
        guard let wanted = ResearchURL.normalize(url) else { return nil }
        for collection in collections {
            if let item = collection.items.first(where: { ($0.kind == .page || $0.kind == .pdf) && ResearchURL.normalize($0.url) == wanted }) { return (collection, item) }
        }
        return nil
    }

    var allTags: [String] { Array(Set(collections.flatMap(\.items).flatMap(\.tags))).sorted() }
}

// MARK: - Export for other note applications

extension ResearchExport {
    private static func yaml(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") + "\""
    }

    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// One Markdown note per item, each with its details at the top (title, source, when it was captured, tags, collection, kind). Obsidian reads these as properties and Joplin imports the files.
    static func noteFiles(_ collection: ResearchCollection) -> [(name: String, text: String)] {
        var taken = Set<String>()
        return collection.items.map { item in
            let base = String((item.title.isEmpty ? "Note" : item.title).replacingOccurrences(of: "[/\\\\:*?\"<>|#^\\[\\]\\n\\r]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(80))
            var name = (base.isEmpty ? "Note" : base) + ".md"
            var n = 2
            while !taken.insert(name.lowercased()).inserted { name = (base.isEmpty ? "Note" : base) + " \(n).md"; n += 1 }
            var head = "---\ntitle: \(yaml(item.title))\n"
            if let url = item.url, !url.isEmpty { head += "source: \(yaml(url))\n" }
            head += "captured: \(stamp(item.captured ?? item.added))\ncollection: \(yaml(collection.name))\ntype: \(item.kind.rawValue)\n"
            head += "tags: [" + item.tags.joined(separator: ", ") + "]\n---\n\n"
            var body = ""
            switch item.kind {
            case .highlight: body = "> " + (item.text ?? "").replacingOccurrences(of: "\n", with: "\n> ") + "\n" + (item.comment.map { "\n" + $0 + "\n" } ?? "")
            case .note: body = (item.text ?? "") + "\n"
            case .page, .pdf: body = (item.citation?.markdown ?? ResearchExport.mdLink(item.title, item.url)) + "\n" + (item.text.map { "\n> " + $0.replacingOccurrences(of: "\n", with: "\n> ") + "\n" } ?? "")
            }
            return (name, head + body)
        }
    }

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func enexDate(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f.string(from: date)
    }

    /// ENEX, the export format Evernote made and Joplin, Apple's and many other note applications import: one note per item, with its title, tags, creation time and source address.
    /// XML 1.0 cannot hold most control characters, even escaped: a note with one in it would make the whole file unreadable to the program that imports it.
    static func xmlSafe(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value == 0x9 || $0.value == 0xA || $0.value == 0xD || ($0.value >= 0x20 && $0.value != 0xFFFE && $0.value != 0xFFFF) }))
    }

    static func enex(_ original: ResearchCollection, now: Date = Date()) -> String {
        var collection = original
        collection.name = xmlSafe(collection.name)
        collection.items = collection.items.map { item in
            var i = item
            i.title = xmlSafe(i.title); i.text = i.text.map(xmlSafe); i.comment = i.comment.map(xmlSafe); i.url = i.url.map(xmlSafe); i.tags = i.tags.map(xmlSafe)
            return i
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE en-export SYSTEM \"http://xml.evernote.com/pub/evernote-export4.dtd\">\n<en-export export-date=\"\(enexDate(now))\" application=\"Browser Setu\" version=\"1\">\n"
        for item in collection.items {
            var html = ""
            if let text = item.text, !text.isEmpty { html += item.kind == .highlight ? "<blockquote>\(escape(text))</blockquote>" : "<div>\(escape(text).replacingOccurrences(of: "\n", with: "<br/>"))</div>" }
            if let comment = item.comment, !comment.isEmpty { html += "<div>\(escape(comment))</div>" }
            if let url = item.url, let safe = safeLink(url) { html += "<div><a href=\"\(safe)\">\(escape(item.title))</a></div>" }
            if html.isEmpty { html = "<div>\(escape(item.title))</div>" }
            let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE en-note SYSTEM \"http://xml.evernote.com/pub/enml2.dtd\"><en-note>\(html)</en-note>".replacingOccurrences(of: "]]>", with: "]]&gt;")
            out += "<note><title>\(xml(item.title.isEmpty ? "Note" : item.title))</title><content><![CDATA[\(content)]]></content><created>\(enexDate(item.captured ?? item.added))</created><updated>\(enexDate(item.captured ?? item.added))</updated>"
            for tag in item.tags { out += "<tag>\(xml(tag))</tag>" }
            if let url = item.url, safeLink(url) != nil { out += "<note-attributes><source-url>\(xml(url))</source-url></note-attributes>" }
            out += "</note>\n"
        }
        return out + "</en-export>\n"
    }
}

// MARK: - One flow to save to Research

/// What is being saved: the page (with its title, address and the time it was captured), a passage if one was selected, and the person's own note, with tags, into one collection.
struct ResearchDraft: Identifiable {
    let id = UUID()
    var pageTitle: String
    var url: String
    var citation: Citation?
    var captured = Date()
    var selection: String?
    var note = ""
    var comment = ""
    var tags = ""
    var includePage = true
    var includeSelection = true
    var collectionID: UUID?
    var duplicate: (collection: String, added: Date)?
}

extension BrowserModel {
    /// Reads the page in front into a draft for the person to look over. A private tab, or no page, gives nothing.
    func researchDraftForActivePage() async -> ResearchDraft? {
        guard let tab = active, tab.privacy.canSaveToResearch, !tab.isBlank else { notice = "Open a page first. Pages from private, guest, scratch and Glance tabs are never saved."; return nil }
        guard let citation = await citationForActivePage() else { notice = "There is no page to save."; return nil }
        var draft = ResearchDraft(pageTitle: citation.title, url: citation.url, citation: citation, captured: Date())
        let selected = await tab.engine.selectedText()?.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.selection = (selected?.isEmpty == false) ? String(selected!.prefix(ResearchStore.maxText)) : nil
        draft.collectionID = research.current?.id ?? research.collections.first?.id
        if let found = research.duplicate(ofURL: citation.url) { draft.duplicate = (found.collection.name, found.item.added) }
        return draft
    }

    /// Saves what the draft says, as separate items that share one capture time. Returns how many items were saved or updated.
    @discardableResult
    func saveResearchDraft(_ draft: ResearchDraft) -> Int {
        guard let collection = draft.collectionID.flatMap({ id in research.collections.first { $0.id == id } }) ?? targetCollection() else { return 0 }
        let tags = ResearchTags.parse(draft.tags)
        var saved = 0
        if draft.includePage {
            let isPDF = URL(string: draft.url)?.pathExtension.lowercased() == "pdf"
            var item = ResearchItem(kind: isPDF ? .pdf : .page, title: draft.pageTitle, url: draft.url, text: nil, citation: draft.citation)
            item.tags = tags; item.captured = draft.captured
            if research.add(item, to: collection.id) { saved += 1 }
        }
        if draft.includeSelection, let text = draft.selection, !text.isEmpty {
            var item = ResearchItem(kind: .highlight, title: draft.pageTitle, url: draft.url, text: text, citation: draft.citation, comment: draft.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft.comment)
            item.tags = tags; item.captured = draft.captured
            if research.add(item, to: collection.id) { saved += 1 }
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            var item = ResearchItem(kind: .note, title: draft.pageTitle, url: draft.url, text: String(note.prefix(ResearchStore.maxText)))
            item.tags = tags; item.captured = draft.captured
            if research.add(item, to: collection.id) { saved += 1 }
        }
        if saved > 0 { notice = "Saved to “\(collection.name)”." }
        return saved
    }

    func exportResearchNotes(_ collection: ResearchCollection) {
        let folder = DownloadCoordinator.uniqueURL(in: DownloadCoordinator.directory, name: collection.name.replacingOccurrences(of: "/", with: "-") + " notes")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in ResearchExport.noteFiles(collection) { try Data(file.text.utf8).write(to: folder.appendingPathComponent(file.name), options: .withoutOverwriting) }
            notice = "Saved \(collection.items.count) notes in the folder “\(folder.lastPathComponent)” in Downloads."
        } catch { notice = "That could not be saved. \(error.localizedDescription)" }
    }
}

struct ResearchSaveView: View {
    @EnvironmentObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: ResearchDraft
    @State private var saveFailed = false

    /// Something the person typed would be lost (the page and the selection are chosen again at will; the words are not).
    private var hasTypedText: Bool { !draft.note.isEmpty || !draft.comment.isEmpty || !draft.tags.isEmpty }
    private var canSave: Bool { draft.includePage || (draft.includeSelection && draft.selection != nil) || !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section("Page") {
                Toggle(isOn: $draft.includePage) { VStack(alignment: .leading, spacing: 2) { Text(draft.pageTitle).lineLimit(2); Text(draft.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) } }
                LabeledContent("Captured", value: draft.captured.formatted(date: .abbreviated, time: .shortened))
                if let duplicate = draft.duplicate {
                    Label("Already saved in “\(duplicate.collection)” on \(duplicate.added.formatted(date: .abbreviated, time: .omitted)). Saving updates it.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }
            if let selection = draft.selection {
                Section("Selected text") {
                    Toggle(isOn: $draft.includeSelection) { Text(selection).font(.callout).lineLimit(5) }
                    TextField("Your comment on it (optional)", text: $draft.comment)
                }
            }
            Section("Your note") { TextEditor(text: $draft.note).frame(minHeight: 70).quietWritingToolsButton() }
            Section("Where") {
                Picker("Collection", selection: Binding(get: { draft.collectionID }, set: { draft.collectionID = $0 })) {
                    ForEach(model.research.collections) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField("Tags (reading, to do, work)", text: $draft.tags).autocorrectionDisabled()
                if !model.research.allTags.isEmpty { Text("Used before: " + model.research.allTags.prefix(10).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { if model.saveResearchDraft(draft) > 0 { dismiss() } else { saveFailed = true } }.keyboardShortcut(.defaultAction).disabled(!canSave) }
        }
        .formStyle(.grouped)
        .onAppear { if draft.collectionID == nil { draft.collectionID = model.research.collections.first?.id } }
        .alert("Could not save", isPresented: $saveFailed) { Button("OK", role: .cancel) {} } message: { Text("Nothing was saved. The note stays open so nothing is lost.") }
        // Done and Escape ask first when words were typed: Save (a failed save keeps this open), Discard Changes or Keep Editing.
        .guardsUnsavedChanges(isDirty: hasTypedText, save: { !canSave ? "Choose the page, the selection or write a note first." : (model.saveResearchDraft(draft) > 0 ? nil : "Nothing could be saved.") })
    }
}
