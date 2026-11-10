import SwiftUI

/// The files of a torrent as a tree: choose files or whole folders, set a priority for each, search a long list, and (for a running torrent) see how much of each file has arrived.
/// Used by the Add sheet (before anything is downloaded) and by the inspector (while it runs). Rows are a flat list built for the visible folders only, so thousands of files stay quick.
struct TorrentFilesView: View {
    let meta: TorrentMetainfo
    @Binding var selection: TorrentSelection
    /// Bytes of each file that are in verified pieces (by file index); nil before a download has begun.
    var progress: [Int: Int64]? = nil
    var maxHeight: CGFloat = 220
    /// Called after the person changes anything (the inspector applies the change to the running torrent).
    var changed: () -> Void = {}

    @State private var tree: TorrentFileTree
    @State private var expanded = Set<String>()
    @State private var query = ""

    init(meta: TorrentMetainfo, selection: Binding<TorrentSelection>, progress: [Int: Int64]? = nil, maxHeight: CGFloat = 220, changed: @escaping () -> Void = {}) {
        self.meta = meta; _selection = selection; self.progress = progress; self.maxHeight = maxHeight; self.changed = changed
        _tree = State(initialValue: TorrentFileTree(meta))
    }

    private var rows: [TorrentFileTree.Row] { tree.rows(expanded: expanded, selection: selection, filter: query, meta: meta) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Search files", text: $query).textFieldStyle(.roundedBorder).controlSize(.small).accessibilityLabel("Search files")
                Button("All") { apply { TorrentFileTree.set(files: matching, chosen: true, in: &selection) } }.controlSize(.small).help(query.isEmpty ? "Choose every file" : "Choose the files found")
                Button("None") { apply { TorrentFileTree.set(files: matching, chosen: false, in: &selection) } }.controlSize(.small).help(query.isEmpty ? "Choose no file" : "Skip the files found")
            }
            List(rows) { row in rowView(row).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4)) }
                .listStyle(.plain).frame(height: min(maxHeight, CGFloat(max(1, rows.count)) * 26 + 8))
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Files in the torrent")
            if rows.count >= TorrentFileTree.maxRows { Text("Showing the first \(TorrentFileTree.maxRows) rows. Search to narrow the list.").font(.system(size: 11)).foregroundStyle(.tertiary) }
            if query.isEmpty == false, rows.isEmpty { Text("No file matches.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }

    /// With a search typed, All and None act on the files found; otherwise on every file.
    private var matching: [Int] {
        query.trimmingCharacters(in: .whitespaces).isEmpty ? meta.files.map(\.index) : rows.compactMap(\.fileIndex)
    }

    private func apply(_ change: () -> Void) { change(); changed() }

    @ViewBuilder private func rowView(_ row: TorrentFileTree.Row) -> some View {
        HStack(spacing: 5) {
            Color.clear.frame(width: CGFloat(row.depth) * 14, height: 1)
            if row.isFolder && query.isEmpty {
                let key = row.path.joined(separator: "\u{1}")
                Button { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } } label: {
                    Image(systemName: expanded.contains(key) ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                }.buttonStyle(.plain).accessibilityLabel(expanded.contains(key) ? "Collapse \(row.name)" : "Expand \(row.name)")
            } else { Color.clear.frame(width: 12) }
            Button { toggle(row) } label: {
                Image(systemName: row.state == .all ? "checkmark.square.fill" : (row.state == .some ? "minus.square.fill" : "square")).foregroundStyle(row.state == .none ? Color.secondary : Theme.accent)
            }.buttonStyle(.plain).accessibilityLabel(row.name).accessibilityValue(row.state == .all ? "chosen" : (row.state == .some ? "partly chosen" : "skipped"))
            Image(systemName: row.isFolder ? "folder" : "doc").font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text(row.name).lineLimit(1).truncationMode(.middle).help(row.path.joined(separator: "/"))
            Spacer(minLength: 4)
            if let p = progress, let index = row.fileIndex, row.state != .none {
                let done = p[index] ?? 0
                Text(row.size > 0 ? "\(Int(min(1, Double(done) / Double(row.size)) * 100))%" : "—").foregroundStyle(.secondary).monospacedDigit()
            }
            Text(DownloadStats.bytes(row.size)).foregroundStyle(.secondary).monospacedDigit()
            priorityMenu(row)
        }
        .font(.system(size: 11.5)).opacity(row.state == .none ? 0.6 : 1)
    }

    private func toggle(_ row: TorrentFileTree.Row) {
        apply {
            if let index = row.fileIndex { selection.priorities[index] = selection.priority(of: index) > .skip ? .skip : .normal }
            else { tree.set(folder: row.path, chosen: row.state != .all, in: &selection) }
        }
    }

    private func priorityMenu(_ row: TorrentFileTree.Row) -> some View {
        let current: FilePriority? = row.fileIndex.map { selection.priority(of: $0) }
        return Menu {
            ForEach(FilePriority.allCases, id: \.self) { p in
                Button { apply { if let index = row.fileIndex { selection.priorities[index] = p } else { tree.set(folder: row.path, priority: p, in: &selection) } } } label: {
                    if current == p { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                }
            }
        } label: { Text(current.map { $0 > .skip && $0 != .normal ? $0.title : "" } ?? "").font(.system(size: 10.5)).foregroundStyle(Theme.accent).frame(minWidth: 52, alignment: .trailing) }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .accessibilityLabel("Priority of \(row.name)")
    }
}


/// The files of a torrent that is already added: what has arrived of each, and (while it runs) changing which files are wanted, their priorities and the order. A paused torrent shows its files
/// but is changed after it is resumed, because the files on disk are rearranged only while the download is running.
struct TorrentLiveFilesPanel: View {
    @ObservedObject var vm: DownloadsViewModel
    let id: UUID
    let running: Bool
    @State private var meta: TorrentMetainfo?
    @State private var selection = TorrentSelection(priorities: [:])
    @State private var progress: [Int: Int64] = [:]
    @State private var message: String?
    @State private var applying = false
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                if let meta {
                    TorrentFilesView(meta: meta, selection: $selection, progress: running ? progress : nil, maxHeight: 220, changed: apply).id(meta.infoHashHex).disabled(!running || applying)
                    HStack(spacing: 8) {
                        Text("Order").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        Picker("Order", selection: Binding(get: { selection.mode }, set: { selection.mode = $0; apply() })) { ForEach(ScheduleMode.allCases, id: \.self) { Text($0.title).tag($0) } }
                            .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize().disabled(!running || applying)
                    }
                    if selection.mode == .streaming, running { playbackPosition(meta) }
                    if !running { Text("Resume the download to change its files.").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                } else { Text("The list of files is not available.").font(.system(size: 11)).foregroundStyle(.secondary) }
                if let message { Text(message).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            }.padding(.top, 4)
        } label: { Text("Choose files").font(.system(size: 12)) }
        .task(id: id) { load() }
        .task(id: "\(id.uuidString)-\(running)-\(open)") {
            guard open, running else { return }
            while !Task.isCancelled { refresh(); try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
    }

    /// Where playback is. A player that reads this torrent tells the engine through the same call; without one, this lets the person say which part of a file they want first.
    @ViewBuilder private func playbackPosition(_ meta: TorrentMetainfo) -> some View {
        let candidates = meta.files.filter { selection.priority(of: $0.index) > .skip && $0.length > 0 }
        if let first = candidates.first {
            let file = candidates.first { $0.index == (selection.streamFile ?? first.index) } ?? first
            HStack(spacing: 8) {
                Text("Play from").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Picker("File", selection: Binding(get: { file.index }, set: { selection.streamFile = $0; selection.streamPosition = 0; vm.setTorrentStreamPosition(id, file: $0, byte: 0) })) {
                    ForEach(candidates.prefix(200), id: \.index) { Text($0.relativePath).lineLimit(1).tag($0.index) }
                }.labelsHidden().controlSize(.small).frame(maxWidth: 160)
                Slider(value: Binding(get: { Double(selection.streamPosition) / Double(max(1, file.length)) },
                                      set: { v in let byte = Int64(v * Double(file.length)); selection.streamFile = file.index; selection.streamPosition = byte; vm.setTorrentStreamPosition(id, file: file.index, byte: byte) }), in: 0...1)
                    .controlSize(.small).accessibilityLabel("Playback position")
            }
        }
    }

    private func load() {
        guard let saved = vm.torrentSavedSelection(id) else { meta = nil; return }
        meta = saved.meta; selection = saved.selection
    }

    private func refresh() {
        vm.torrentFileProgress(id) { rows in
            guard !rows.isEmpty else { return }
            progress = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0.verified) })
            if !applying, selection.priorities.isEmpty == false || meta != nil {
                var fresh = selection
                for r in rows { fresh.priorities[r.index] = r.priority }
                if fresh.priorities != selection.priorities { selection.priorities = fresh.priorities }
            }
        }
    }

    private func apply() {
        applying = true; message = nil
        vm.updateTorrentSelection(id, selection) { result in
            applying = false
            if case .failure(let error) = result { message = (error as? LocalizedError)?.errorDescription ?? "The files could not be changed."; load() }
        }
    }
}
