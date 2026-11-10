import SwiftUI

struct ArchiveTarget: Identifiable { let url: URL; var id: URL { url } }

/// Looks inside a finished archive and takes chosen files out into a new folder beside it. The archive is never changed.
struct ArchiveBrowserSheet: View {
    let file: URL
    let roots: [URL]
    let done: () -> Void
    @State private var listing: ArchiveListing?
    @State private var problem: String?
    @State private var selection = Set<Int>()
    @State private var filter = ""
    @State private var working = false
    @State private var fraction = 0.0
    @State private var cancelFlag = CancelFlag()
    @State private var result: ArchiveManager.Result?
    @State private var destination: URL?

    final class CancelFlag: @unchecked Sendable { private let l = NSLock(); private var v = false; var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } } }

    private var shown: [ArchiveItem] {
        guard let items = listing?.items else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(file.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle); Spacer(); if let l = listing { Text(l.kind.title).font(.caption).foregroundStyle(.secondary) } }
            if let problem { Text(problem).foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let listing {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
                Table(shown, selection: $selection) {
                    TableColumn("Name") { item in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name).lineLimit(1).truncationMode(.middle).foregroundStyle(item.isSupported ? Color.primary : Color.secondary)
                            if case .unsupported(let why) = item.status { Text(why).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1) }
                        }
                    }
                    TableColumn("Size") { item in Text(item.isDirectory ? "" : DownloadStats.bytes(Int64(min(item.size, UInt64(Int64.max))))).monospacedDigit().foregroundStyle(.secondary) }.width(80)
                    TableColumn("Method") { item in Text(item.encrypted ? "password-protected" : item.method).font(.caption).foregroundStyle(.secondary) }.width(110)
                }.frame(minHeight: 240).alternatingRowBackgrounds(.disabled)
                HStack {
                    Text("\(listing.items.count) entries · \(DownloadStats.bytes(Int64(min(listing.totalSize, UInt64(Int64.max))))) unpacked · \(listing.supportedCount) can be taken out").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                if listing.hasUnsafeEntries { Text("Some entries have names that could land outside the folder. “Extract All” is off; choose the safe entries you want.").font(.caption).foregroundStyle(.orange) }
                ForEach(listing.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            } else if problem == nil { ProgressView("Reading the archive…") }
            if working { ProgressView(value: fraction); Button("Cancel") { cancelFlag.value = true } }
            if let result {
                Text("Taken out into “\(result.folder.lastPathComponent)” (\(result.extracted) files).").font(.callout)
                if !result.skipped.isEmpty { DisclosureGroup("\(result.skipped.count) not taken") { ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, s in Text("\(s.name.prefix(50)) — \(s.reason)").font(.caption) } } }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.folder]) }
            }
            HStack {
                Text("To: " + ((destination ?? file.deletingLastPathComponent()).path as NSString).abbreviatingWithTildeInPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Choose Folder…") { choose() }.controlSize(.small).disabled(working)
                Spacer()
                Button("Close") { cancelFlag.value = true; done() }
                Button("Extract Selected") { run(selection) }.disabled(working || selection.isEmpty || listing == nil)
                Button("Extract All") { run(nil) }.keyboardShortcut(.defaultAction).disabled(working || listing == nil || listing?.hasUnsafeEntries == true)
            }
        }
        .padding(16).frame(minWidth: 620, minHeight: 440)
        .task { await load() }
    }

    private func load() async {
        let url = file, flag = cancelFlag
        do { listing = try await Task.detached(priority: .userInitiated) { try ArchiveManager.list(url, isCancelled: { flag.value }) }.value }
        catch { problem = (error as? LocalizedError)?.errorDescription ?? "The archive could not be read." }
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if DownloadPathPolicy.isAuthorized(url.path, roots: roots) { destination = url; problem = nil } else { problem = "Files can only be taken out inside your downloads folder." }
    }

    private func run(_ chosen: Set<Int>?) {
        working = true; fraction = 0; result = nil; problem = nil; cancelFlag.value = false
        let url = file, target = destination ?? file.deletingLastPathComponent(), roots = roots, flag = cancelFlag
        Task {
            do {
                let r = try await Task.detached(priority: .userInitiated) {
                    try ArchiveManager.extract(url, selection: chosen, destination: target, roots: roots, progress: { done, total in Task { @MainActor in fraction = total > 0 ? Double(done) / Double(total) : 0 } }, isCancelled: { flag.value })
                }.value
                result = r
            } catch { problem = (error as? LocalizedError)?.errorDescription ?? "Could not take the files out." }
            working = false
        }
    }
}
