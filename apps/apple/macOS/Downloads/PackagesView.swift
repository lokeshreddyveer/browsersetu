import SwiftUI

/// Review of a selection before it becomes a package: what will be made, what will not, and where it will be saved. Nothing starts until Create.
struct BatchPackageForm: View {
    @ObservedObject var store: LinkGrabberStore
    @ObservedObject var model: BrowserModel
    var done: (String) -> Void
    @State private var name = "Package"
    @State private var grouping = BatchGrouping.none
    @State private var template = "{package}"
    @State private var busy = false
    @State private var task: Task<Void, Never>?

    private var chosen: [DetectedLink] { store.selectedItems }
    private var files: [DetectedLink] { chosen.filter { $0.canAdd && ($0.kind == .httpResource || $0.kind == .torrentURL) } }
    private var needOwn: Int { chosen.filter { $0.kind.isPeerToPeer && $0.kind != .torrentURL || $0.kind == .streamManifest }.count }
    private var duplicates: Int {
        let live = Set(model.engine.downloads.ledger.records.values.filter { !$0.state.isFinal && !$0.isPrivate }.compactMap { $0.source.url.flatMap(URL.init(string:)).map(LinkClassifier.normalizedKey) })
        return files.filter { live.contains(LinkClassifier.normalizedKey(URL(string: $0.original) ?? URL(string: "x:")!)) }.count
    }
    private var unsupported: Int { chosen.filter { !$0.kind.isSupported }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("New package").font(.system(size: 13, weight: .semibold))
            TextField("Package name", text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
            Picker("Group", selection: $grouping) { ForEach(BatchGrouping.allCases) { Text($0.title).tag($0) } }.pickerStyle(.menu)
            VStack(alignment: .leading, spacing: 2) {
                TextField("Folder", text: $template).textFieldStyle(.roundedBorder).frame(width: 300)
                Text("Inside your Downloads folder. Use {package}, {host}, {directory}, {date}. Folder names are cleaned; nothing can leave Downloads.").font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
            }
            Divider()
            Text("\(files.count) file\(files.count == 1 ? "" : "s") will be added (at most \(LinkGrabberStore.maxBatchAdd)).").font(.system(size: 11.5))
            if duplicates > 0 { Text("\(duplicates) already downloading: skipped.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            if needOwn > 0 { Text("\(needOwn) need their own preview and approval (streams, magnet or eD2k links): not added here.").font(.system(size: 11.5)).foregroundStyle(.secondary).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
            if unsupported > 0 { Text("\(unsupported) not supported: skipped.").font(.system(size: 11.5)).foregroundStyle(.orange) }
            if store.isPrivate { Label("A private collection cannot make downloads: they would be kept in the ordinary list.", systemImage: "eye.slash").font(.system(size: 11.5)).foregroundStyle(.orange).frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true) }
            Text("They start in turn, within your limit for downloads at once.").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { task?.cancel(); done("") }
                Button("Create") { create() }.buttonStyle(.borderedProminent).disabled(files.isEmpty || busy || store.isPrivate).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }

    private func create() {
        busy = true
        let request = BatchRequest(name: name, grouping: grouping, folderTemplate: template)
        let links = chosen
        task = Task {
            let r = await BatchSubmitter.submit(request, links: links, isPrivate: store.isPrivate, coordinator: model.engine.downloads)
            store.remove(r.handled)
            busy = false
            var parts = ["\(r.started) added"]
            if r.alreadyDownloading > 0 { parts.append("\(r.alreadyDownloading) already downloading") }
            if !r.needsOwnApproval.isEmpty { parts.append("\(r.needsOwnApproval.count) need their own approval") }
            if !r.refused.isEmpty { parts.append("\(r.refused.count) skipped") }
            if r.tooMany { parts.append("limit reached") }
            if r.replayed { parts.append("this batch was already made") }
            done(parts.joined(separator: ", "))
        }
    }
}

/// The packages of this profile: progress worked out from their members, and actions that are the downloads' own actions.
struct PackagesSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { PackagesContent(store: model.packages, model: model, done: done) }
}

private struct PackagesContent: View {
    @ObservedObject var store: PackageStore
    @ObservedObject var model: BrowserModel
    var done: () -> Void
    @State private var expanded = Set<UUID>()
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox").foregroundStyle(Theme.accent)
                Text("Packages").font(.system(size: 15, weight: .semibold))
                Text("\(store.packages.count)").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if let message { Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
                Button("Done", action: done).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.5)
            if store.packages.isEmpty {
                Text("No packages yet. Select links in the LinkGrabber and choose Add as Package.").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List { ForEach(store.packages) { p in row(p) } }.listStyle(.inset)
            }
        }
        .frame(minWidth: 620, minHeight: 360)
    }

    private func report(_ o: PackageOutcome) { message = o.summary }

    @ViewBuilder private func row(_ p: DownloadPackage) -> some View {
        let r = store.progress(p)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button { if expanded.contains(p.id) { expanded.remove(p.id) } else { expanded.insert(p.id) } } label: { Image(systemName: expanded.contains(p.id) ? "chevron.down" : "chevron.right").frame(width: 12) }.buttonStyle(.plain).accessibilityLabel(expanded.contains(p.id) ? "Hide items" : "Show items").help(expanded.contains(p.id) ? "Hide items" : "Show items")
                Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(Self.statusText(r)).font(.system(size: 11.5)).foregroundStyle(r.status == .needsAttention ? .orange : .secondary)
                Spacer()
                Menu {
                    Button("Pause") { report(store.pause(p.id)) }
                    Button("Resume") { report(store.resume(p.id)) }
                    Button("Retry Failed") { report(store.retryFailed(p.id)) }.disabled(r.retryable == 0)
                    Button("Cancel Unfinished") { report(store.cancelUnfinished(p.id)) }
                    Divider()
                    Button("Clear Completed from Package") { message = "\(store.clearCompleted(p.id)) removed from the package" }.disabled(r.completed == 0)
                    Button("Rename…") { Task { if let t = await Dialogs.promptText(title: "Rename package", message: "", placeholder: p.name), !t.isEmpty { store.rename(p.id, to: t) } } }
                    Button("Remove Package (keeps the downloads)") { store.deletePackage(p.id) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28).accessibilityLabel("Package actions").help("Package actions")
            }
            if let f = r.fraction { ProgressView(value: f).controlSize(.small) }
            else if r.total > 0 { Text("Sizes not all known yet").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            if expanded.contains(p.id) {
                ForEach(p.members, id: \.self) { id in
                    if let rec = model.engine.downloads.ledger.record(id) {
                        HStack { Text(rec.file.filename).font(.system(size: 11.5)).lineLimit(1); Spacer(); Text(rec.state.rawValue).font(.system(size: 11)).foregroundStyle(.secondary) }.padding(.leading, 20)
                    }
                }
            }
        }.padding(.vertical, 3)
    }

    static func statusText(_ r: PackageProgress) -> String {
        guard r.total > 0 else { return "Empty" }
        var parts = ["\(r.completed) of \(r.total) done"]
        if r.active > 0 { parts.append("\(r.active) downloading") }
        if r.waiting > 0 { parts.append("\(r.waiting) waiting") }
        if r.paused > 0 { parts.append("\(r.paused) paused") }
        if r.failed > 0 { parts.append("\(r.failed) failed") }
        if r.recovery > 0 { parts.append("\(r.recovery) need a decision") }
        if r.cancelled > 0 { parts.append("\(r.cancelled) cancelled") }
        return parts.joined(separator: " · ")
    }
}
