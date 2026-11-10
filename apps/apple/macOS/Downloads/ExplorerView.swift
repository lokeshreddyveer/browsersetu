import SwiftUI

/// "Explore a Website": reads a few pages of one website and lists the files it finds, so the person can choose. Reading is bounded and polite; nothing is downloaded.
struct ExplorerSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { ExplorerContent(store: model.websiteExplorer, model: model, done: done) }
}

private struct ExplorerContent: View {
    @ObservedObject var store: ExplorerStore
    @ObservedObject var model: BrowserModel
    var done: () -> Void
    @State private var address = ""
    @State private var depth = 1
    @State private var pages = 25
    @State private var sameSite = true
    @State private var stayInFolder = true
    @State private var message: String?
    /// The address the sheet was opened with from a page. It is the page's until the person changes it.
    @State private var prefilled: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "network").foregroundStyle(Theme.accent)
                Text("Explore a Website").font(.system(size: 15, weight: .semibold))
                Text("\(store.items.count) found").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                if store.phase == .running { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            controls
            Divider().opacity(0.5)
            filters
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            if address.isEmpty, let a = model.explorerAddress { address = a; prefilled = a; model.explorerAddress = nil }
        }
        .onDisappear { store.cancel() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("https://example.com/files/", text: $address).textFieldStyle(.roundedBorder).onSubmit(go)
                Stepper("Depth \(depth)", value: $depth, in: ExplorerScope.depthRange).frame(width: 110)
                Stepper("Pages \(pages)", value: $pages, in: 5...100, step: 5).frame(width: 120)
                if store.phase == .running { Button("Stop") { store.cancel() } } else { Button("Explore", action: go).buttonStyle(.borderedProminent).disabled(URL(string: address.trimmingCharacters(in: .whitespaces)) == nil) }
            }
            HStack(spacing: 14) {
                Toggle("This website only", isOn: $sameSite)
                Toggle("Stay in this folder", isOn: $stayInFolder)
                Text("Respects the website's robots.txt. Reads a few pages, slowly, and downloads nothing.").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                if let line = statusLine { Text(line).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            }.toggleStyle(.checkbox).font(.system(size: 11.5))
        }.controlSize(.small).padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var statusLine: String? {
        let s = store.summary
        guard store.phase != .idle else { return message }
        var t = "\(s.pagesVisited) page\(s.pagesVisited == 1 ? "" : "s") read"
        if s.blockedByRobots > 0 { t += ", \(s.blockedByRobots) blocked by robots.txt" }
        if s.outOfScope > 0 { t += ", \(s.outOfScope) outside the scope" }
        if s.insideNetworkRefused > 0 { t += ", \(s.insideNetworkRefused) inside your network refused" }
        switch s.stop {
        case .finished: break
        case .pageLimit: t += ". Stopped at the page limit"
        case .candidateLimit: t += ". Stopped at the result limit"
        case .byteBudget: t += ". Stopped at the size limit"
        case .timeLimit: t += ". Stopped at the time limit"
        case .cancelled: t += ". Stopped"
        case .refusedByRobots, .startFailed: t = s.note ?? t
        }
        return t
    }

    private var filters: some View {
        HStack(spacing: 8) {
            TextField("Search", text: $store.search).textFieldStyle(.roundedBorder).frame(width: 150)
            Picker("Type", selection: $store.category) { Text("All types").tag(ExplorerCategory?.none); ForEach(ExplorerCategory.allCases) { Text($0.title).tag(Optional($0)) } }.labelsHidden().frame(width: 110)
            Picker("Website", selection: $store.host) { Text("All websites").tag(String?.none); ForEach(store.hosts, id: \.self) { Text($0).tag(Optional($0)) } }.labelsHidden().frame(width: 150)
            TextField("Folder contains", text: $store.directoryContains).textFieldStyle(.roundedBorder).frame(width: 120)
            Toggle("Checked only", isOn: $store.onlyChecked).toggleStyle(.checkbox)
            Spacer()
            Text("\(store.visible.count) shown").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }.controlSize(.small).padding(.horizontal, 16).padding(.vertical, 6)
    }

    private var list: some View {
        Group {
            if store.items.isEmpty {
                Text(store.phase == .running ? "Reading…" : "Enter an address and choose Explore.").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selection) {
                    ForEach(store.visible) { i in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(i.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                                Text("\(i.category.title) · \(i.host) · \(i.directory) · level \(i.depth)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(label(i.availability)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }.tag(i.id)
                    }
                }.listStyle(.inset)
            }
        }
    }

    private func label(_ a: ExplorerItem.Availability) -> String {
        switch a {
        case .proposed: "Not checked"
        case .verified(let size, _): size.map { DownloadStats.bytes($0) } ?? "Checked"
        case .unavailable(let why): why
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Select All Shown") { store.selectAllVisible() }.disabled(store.visible.isEmpty)
            Button("Clear Selection") { store.clearSelection() }.disabled(store.selection.isEmpty)
            Button("Exclude Selected") { store.excludeSelected() }.disabled(store.selectedVisible.isEmpty)
            Spacer()
            Text(store.selectedVisible.isEmpty ? "Nothing selected" : "\(store.selectedVisible.count) selected").font(.system(size: 11.5)).foregroundStyle(.secondary)
            Button("Check Sizes") {
                store.verify(store.selectedVisible.map(\.id)) { [model] url in
                    let s = try await model.engine.downloads.http.engine.resolve(DownloadSourceRequest(url: url, profile: model.profileName, isPrivate: false, origin: .page))
                    return LinkMetadata(filename: s.suggestedFilename, size: s.totalBytes, acceptsRanges: s.acceptsRanges)
                }
            }.disabled(store.selectedVisible.isEmpty).help("Asks the website about the selected files (at most 50), only because you asked.")
            Button("Add to LinkGrabber") {
                let r = model.addExplorerSelectionToLinkGrabber()
                message = "\(r.added) added to the LinkGrabber" + (r.duplicates > 0 ? ", \(r.duplicates) already there" : "")
                model.openLinkGrabber()
            }.buttonStyle(.borderedProminent).disabled(store.selectedVisible.isEmpty)
        }.controlSize(.small).padding(.horizontal, 16).frame(height: 40)
    }

    private func go() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: text) else { return }
        message = model.startExplorer(url, depth: depth, pages: pages, sameSite: sameSite, stayInFolder: stayInFolder, typedByPerson: address.trimmingCharacters(in: .whitespaces) != prefilled)
    }
}
