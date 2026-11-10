import SwiftUI
import AppKit

/// The LinkGrabber: a place to collect links before deciding. Collecting is not downloading: nothing here creates a task, opens a connection, or reserves anything until
/// the person chooses Add Selected or Preview.
struct LinkGrabberSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { LinkGrabberContent(store: model.linkGrabber, model: model, done: done) }
}

private struct LinkGrabberContent: View {
    @ObservedObject var store: LinkGrabberStore
    @ObservedObject var model: BrowserModel
    var done: () -> Void
    @State private var pasting = false
    @State private var pasteText = ""
    @State private var message: String?
    @State private var packaging = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if pasting { pasteArea; Divider().opacity(0.5) }
            list
            Divider().opacity(0.5)
            footer
        }
        // Wide enough for the bottom bar's seven buttons and its note on one line (at 720 "Add as Package…" was cut off and the note wrapped); and no striped rows, which drew empty bars behind the empty message.
        .frame(minWidth: 900, minHeight: 420)
        .alternatingRowBackgrounds(.disabled)
        .onChange(of: model.linkNotice) { _, new in if let new { message = new } }
    }

    /// What the person's accounts say about a link's website. Never picks credentials for a link that is not the person's own: the account is used when the address is added with Add Download.
    static func accountHint(_ store: AccountStore, _ link: DetectedLink) -> String? {
        guard link.kind.isSupported, let url = URL(string: link.original) else { return nil }
        switch store.hint(for: url) {
        case .none: return nil
        case .connected(let n): return "Account “\(n)” — use Add Download to sign in"
        case .signInAgain(let n): return "Account “\(n)” needs signing in again"
        case .expired(let n): return "Account “\(n)” has expired"
        case .sessionOnly(let n): return "Signed-in session (\(n)) — use the page to download"
        case .unsupported(let n): return "Account “\(n)” is only used over https"
        }
    }

    /// A file of links (text list, M3U, Metalink): the addresses are collected here for review, never started. DLC, RSDF and CCF are named as unsupported.
    private func importFile() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (result, report) = try LinkContainers.importFile(url, into: store)
            if case .unsupported(let why) = result.kind { message = why }
            else { message = "\(report.added) link\(report.added == 1 ? "" : "s") collected for review" + (report.duplicates > 0 ? ", \(report.duplicates) already there" : "") + (result.truncated || report.truncated ? " (more than the limit)" : "") + "." }
        } catch { message = (error as? LocalizedError)?.errorDescription ?? "That file could not be read." }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.down.right").foregroundStyle(Theme.accent)
                Text("LinkGrabber").font(.system(size: 15, weight: .semibold))
                if store.isPrivate { Label("Private: kept in memory only", systemImage: "eye.slash").font(.system(size: 11)).foregroundStyle(.secondary) }
                Text("\(store.items.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Search links", text: $store.search).textFieldStyle(.plain).font(.system(size: 12.5)).accessibilityLabel("Search links")
                }
                .padding(.horizontal, 9).frame(width: 200, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.07)))
                Picker("Show", selection: $store.filter) { ForEach(LinkFilter.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 150)
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 8) {
                Button { pasting.toggle() } label: { Label("Paste Links…", systemImage: "doc.on.clipboard") }
                Button { importClipboard() } label: { Label("Import from Clipboard", systemImage: "square.and.arrow.down") }
                    .help("Reads the clipboard once, now, because you asked")
                Button { if !store.isPrivate { importFile() } } label: { Label("Import Link File…", systemImage: "doc.text") }
                    .help("Reads a text list, M3U list or Metalink file and collects its links for review. Nothing is downloaded.").disabled(store.isPrivate)
                Button { Task { await model.collectLinksFromCurrentPage() } } label: { Label("Collect from This Page", systemImage: "globe") }
                    .help("Reads the links of the page that is open, once. Nothing is downloaded or contacted.")
                Button { Task { await model.collectImagesFromCurrentPage() } } label: { Label("Collect Images", systemImage: "photo.on.rectangle") }
                    .help("Reads the pictures of the page that is open (the full-size files where the page links them), once. Nothing is downloaded or contacted.")
                Spacer()
                if let message { Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail) }
                else if let note = store.notice { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste one link or many, or any text that contains them. Nothing is contacted.").font(.system(size: 11.5)).foregroundStyle(.secondary)
            TextEditor(text: $pasteText).font(.system(size: 12, design: .monospaced)).frame(height: 90).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            HStack {
                Button("Add Links") { addPasted() }.buttonStyle(.borderedProminent).controlSize(.small).disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { pasting = false; pasteText = "" }.controlSize(.small)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: List

    private var list: some View {
        let rows = store.visible
        return ZStack {
            Table(rows, selection: $store.selection) {
                TableColumn("Name") { link in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.name).lineLimit(1).truncationMode(.middle)
                        if let g = link.group { Text(g).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                TableColumn("Type") { link in Text(link.protocolLabel).foregroundStyle(link.kind.isSupported ? Color.primary : Color.secondary) }.width(min: 90, ideal: 110)
                TableColumn("Host") { link in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(link.host ?? "").foregroundStyle(.secondary).lineLimit(1)
                        if !link.isPrivate, let hint = Self.accountHint(model.accountStore, link) { Text(hint).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }.width(min: 90, ideal: 150)
                TableColumn("Size") { link in Text(sizeText(link)).foregroundStyle(.secondary).monospacedDigit() }.width(70)
                TableColumn("Status") { link in Text(Self.status(link)).foregroundStyle(Self.statusTint(link)).lineLimit(1) }.width(min: 130, ideal: 190)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Remove") { store.remove(ids) }
                Button("Preview") { previewFirst(ids) }.disabled(!ids.contains { id in store.items.first { $0.id == id }.map { $0.needsApproval && $0.canAdd } ?? false })
            }
            if rows.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "link.badge.plus").font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text(store.items.isEmpty ? "No links collected yet" : "Nothing matches").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    if store.items.isEmpty { Text("Paste links, import the clipboard, or collect them from the page you have open.").font(.system(size: 11.5)).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    static func status(_ link: DetectedLink) -> String {
        switch link.kind {
        case .unsupported(let why), .invalid(let why): return why
        default: break
        }
        if !link.provenance.mayBeAddedFromHere { return "Suggestion only" }
        switch link.check {
        case .notChecked: return link.needsApproval ? "Preview first" : "Not checked"
        case .checking: return "Checking…"
        case .checked: return "Found"
        case .notCheckable(let why): return why.hasPrefix("The website") ? "Not checked" : why
        case .failed(let why): return "Failed: \(why)"
        }
    }
    static func statusTint(_ link: DetectedLink) -> Color {
        switch link.check { case .failed: .orange; case .checked: .green; default: .secondary }
    }
    private func sizeText(_ link: DetectedLink) -> String {
        if case .checked(let m) = link.check, let s = m.size, s > 0 { return DownloadStats.bytes(s) }
        if link.kind == .ed2kFile, let s = Int64(link.id.split(separator: ":").last ?? "") { return DownloadStats.bytes(s) }
        return ""
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Select All") { store.selectAllAddable() }.disabled(store.visible.isEmpty)
            Button("Remove") { store.remove(store.selection) }.disabled(store.selection.isEmpty)
            Button("Clear") { store.clear(); message = nil }.disabled(store.items.isEmpty)
            Spacer()
            Text(store.selection.isEmpty ? "Review before downloading" : "\(store.selection.count) selected").font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Button("Check Selected") { model.linkChecker.check(Array(store.selection), in: store) }
                .disabled(store.selectedItems.isEmpty).help("Asks the websites for the name and size. Only the selected links, a few at a time.")
            Button("Preview") { previewFirst(store.selection) }.disabled(!store.selectedItems.contains { $0.needsApproval && $0.canAdd })
            Button("Add as Package…") { packaging = true }.disabled(!store.selectedItems.contains { $0.canAdd }).help("Reviews the selection, then makes one download for each file, grouped in a package.")
                .popover(isPresented: $packaging, arrowEdge: .top) { BatchPackageForm(store: store, model: model) { message = $0; packaging = false } }
            Button("Add Selected") { addSelected() }.buttonStyle(.borderedProminent).disabled(!store.selectedItems.contains { $0.canAdd })
        }
        .controlSize(.small).padding(.horizontal, 16).frame(height: 40)
    }

    // MARK: Actions

    private func addPasted() {
        let r = store.add(text: pasteText, provenance: .pasted)
        message = r.added == 0 ? (r.duplicates > 0 ? "Already collected." : "No links found in that text.") : "\(r.added) added" + (r.duplicates > 0 ? ", \(r.duplicates) already there" : "") + (r.truncated ? " (limit reached)" : "")
        if r.added > 0 { pasteText = ""; pasting = false }
    }

    private func importClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        guard text.utf8.count <= ClipboardLinkWatcher.maxTextBytes else { message = "The clipboard holds too much text."; return }
        let r = store.add(text: text, provenance: .clipboard)
        message = r.added == 0 ? (r.duplicates > 0 ? "Already collected." : "No links on the clipboard.") : "\(r.added) added from the clipboard."
    }

    private func previewFirst(_ ids: Set<String>) {
        guard let link = store.items.first(where: { ids.contains($0.id) && $0.needsApproval && $0.canAdd }) else { return }
        let route = LinkRouter.route(link)
        if case .refused(let why) = route { message = why; return }
        model.openLinkPreview(route)
        done()
    }

    private func addSelected() {
        var previewed = false
        let r = store.addSelected(to: model.downloads) { route in model.openLinkPreview(route); previewed = true }
        var parts: [String] = []
        if r.started > 0 { parts.append("\(r.started) download\(r.started == 1 ? "" : "s") started") }
        if r.alreadyThere > 0 { parts.append("\(r.alreadyThere) already downloading") }
        if r.refused > 0 { parts.append("\(r.refused) not added") }
        if r.tooMany { parts.append("batch limit reached; add the rest again") }
        message = parts.isEmpty ? nil : parts.joined(separator: ", ")
        if previewed { done() }
    }
}

/// Switches for link detection, in the Downloads settings.
struct LinkDetectionSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Section("Links") {
            Text("Browser Setu recognises magnet and eD2k links and shows what they hold before anything is contacted. The LinkGrabber collects links so you can review them before downloading.").settingsNote()
            Toggle("Open magnet and eD2k links in Browser Setu", isOn: $model.interceptP2PLinks)
            Toggle("Watch the clipboard for download links", isOn: $model.watchClipboardForLinks)
            Text(model.watchClipboardForLinks ? "Links you copy are added to the LinkGrabber (never downloaded). Nothing else on the clipboard is kept or logged. Off in private tabs." : "Off: the clipboard is not read unless you choose Import from Clipboard.").settingsNote()
            Button("Open LinkGrabber") { model.openLinkGrabber() }
        }
    }
}
