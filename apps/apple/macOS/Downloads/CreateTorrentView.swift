import SwiftUI
import AppKit

/// Makes a .torrent from a file or folder on this Mac. Everything happens here: nothing is uploaded or published; the person saves the file or copies the magnet link themselves.
@MainActor
final class CreateTorrentModel: ObservableObject {
    @Published var source: URL?
    @Published var plan: TorrentCreator.Plan?
    @Published var format: TorrentCreator.Format = .v1 { didSet { refresh() } }
    @Published var pieceChoice: Int64 = 0 { didSet { refresh() } }          // 0 = automatic
    @Published var trackerText = "" { didSet { refresh() } }
    @Published var webSeedText = "" { didSet { refresh() } }
    @Published var isPrivate = false
    @Published var comment = "" { didSet { refresh() } }
    @Published var layout: TorrentCreator.Layout?
    @Published var problem: String?
    @Published var progress: TorrentCreator.Progress?
    @Published var working = false
    @Published var result: TorrentCreator.CreatedTorrent?
    @Published var savedNote: String?

    private var task: Task<Void, Never>?
    private var scoped: URL?
    private let creator = TorrentCreator()

    deinit { if let scoped { scoped.stopAccessingSecurityScopedResource() } }

    var options: TorrentCreator.Options {
        var o = TorrentCreator.Options()
        o.format = format
        o.pieceSize = pieceChoice == 0 ? .automatic : .fixed(pieceChoice)
        o.trackerTiers = TorrentCreator.parseTrackerText(trackerText)
        o.webSeeds = TorrentCreator.parseLines(webSeedText)
        o.isPrivate = isPrivate
        o.comment = comment
        o.creationDate = Date()
        return o
    }

    var automaticLabel: String {
        guard let plan else { return "Automatic" }
        return "Automatic (" + TorrentCreator.describe(TorrentCreator.recommendedPieceLength(totalBytes: plan.totalBytes)) + ")"
    }

    var layoutLine: String {
        guard let layout else { return "" }
        let pieces = "\(layout.pieceCount) piece\(layout.pieceCount == 1 ? "" : "s")"
        let size = "about " + ByteCountFormatter.string(fromByteCount: Int64(layout.estimatedMetadataBytes), countStyle: .file) + " torrent file"
        return pieces + ", " + size
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the file or folder to make a torrent from."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        releaseScope()
        if url.startAccessingSecurityScopedResource() { scoped = url }
        source = url; result = nil; savedNote = nil; problem = nil; progress = nil
        do { plan = try creator.plan(root: url) } catch { plan = nil; problem = Self.message(error) }
        refresh()
    }

    private func releaseScope() { if let scoped { scoped.stopAccessingSecurityScopedResource(); self.scoped = nil } }

    func refresh() {
        guard let plan, !working else { layout = nil; return }
        do { layout = try creator.layout(plan: plan, options: options); problem = nil }
        catch { layout = nil; problem = Self.message(error) }
    }

    static func message(_ error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    func start() {
        guard let plan, layout != nil, !working else { return }
        working = true; problem = nil; result = nil; savedNote = nil
        progress = TorrentCreator.Progress(bytesDone: 0, totalBytes: plan.totalBytes, currentFile: "", filesDone: 0)
        let options = self.options
        let creator = self.creator
        let box = ProgressBox { [weak self] p in Task { @MainActor in self?.progress = p } }
        task = Task { [weak self] in
            do {
                let made = try await creator.create(plan: plan, options: options) { box.report($0) }
                self?.result = made
            } catch is CancellationError {
                self?.problem = "Cancelled. Nothing was created."
            } catch {
                self?.problem = Self.message(error)
            }
            self?.working = false; self?.progress = nil; self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    func save() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = result.summary.suggestedFileName
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.init(filenameExtension: "torrent") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // The save panel already asked about replacing an existing file; otherwise the file is written without ever replacing one.
            if FileManager.default.fileExists(atPath: url.path) { try result.data.write(to: url, options: .atomic); savedNote = "Saved " + url.lastPathComponent }
            else { let written = try TorrentCreator.write(result.data, named: url.lastPathComponent, in: url.deletingLastPathComponent()); savedNote = "Saved " + written.lastPathComponent }
        } catch { problem = Self.message(error) }
    }

    func copyMagnet() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.magnet, forType: .string)
        savedNote = "Magnet link copied"
    }
}

/// Hands progress from the hashing thread to the main actor, at most about 20 times a second.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let deliver: @Sendable (TorrentCreator.Progress) -> Void
    init(_ deliver: @escaping @Sendable (TorrentCreator.Progress) -> Void) { self.deliver = deliver }
    func report(_ p: TorrentCreator.Progress) {
        lock.lock(); let due = Date().timeIntervalSince(last) > 0.05; if due { last = Date() }; lock.unlock()
        if due { deliver(p) }
    }
}

struct CreateTorrentView: View {
    @StateObject private var model = CreateTorrentModel()
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Torrent").font(.system(size: 15, weight: .semibold))
            sourceRow
            if model.plan != nil {
                optionsForm.disabled(model.working)
                if let layout = model.layout { Text(model.layoutLine).font(.system(size: 11.5)).foregroundStyle(.secondary).help("Piece size \(TorrentCreator.describe(layout.pieceLength))") }
            }
            if let note = model.problem { Text(note).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            progressRow
            if let result = model.result { resultBox(result) }
            Spacer(minLength: 0)
            footer
        }
        .padding(18)
        .frame(width: 520, height: 600)
        .animation(.easeOut(duration: 0.18), value: model.result != nil)
        .animation(.easeOut(duration: 0.18), value: model.working)
        .animation(.easeOut(duration: 0.18), value: model.problem)
    }

    private var sourceRow: some View {
        HStack(spacing: 8) {
            Button("Choose File or Folder…") { model.choose() }.disabled(model.working)
            if let plan = model.plan {
                Text(plan.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(sourceSummary(plan)).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceSummary(_ plan: TorrentCreator.Plan) -> String {
        let size = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        let files = "\(plan.fileCount) file\(plan.fileCount == 1 ? "" : "s")"
        let skipped = plan.skipped.isEmpty ? "" : ", \(plan.skipped.count) skipped"
        return size + ", " + files + skipped
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Format", selection: $model.format) {
                ForEach(TorrentCreator.Format.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("Piece size", selection: $model.pieceChoice) {
                Text(model.automaticLabel).tag(Int64(0))
                Divider()
                ForEach(TorrentCreator.validPieceLengths, id: \.self) { Text(TorrentCreator.describe($0)).tag($0) }
            }
            labeledEditor("Trackers (one per line, blank line starts a new tier)", text: $model.trackerText, height: 64)
            labeledEditor("Web seeds (one per line)", text: $model.webSeedText, height: 40)
            TextField("Comment", text: $model.comment).textFieldStyle(.roundedBorder)
            Toggle("Private torrent (no DHT or peer exchange)", isOn: $model.isPrivate)
        }
    }

    private func labeledEditor(_ title: String, text: Binding<String>, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(size: 12, design: .monospaced)).frame(height: height)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15)))
        }
    }

    @ViewBuilder private var progressRow: some View {
        if model.working, let p = model.progress {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p.fraction)
                Text(p.currentFile.isEmpty ? "Starting…" : "Reading " + p.currentFile).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func resultBox(_ r: TorrentCreator.CreatedTorrent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Torrent ready").font(.system(size: 12.5, weight: .semibold))
            Text(r.summary.name + " — " + ByteCountFormatter.string(fromByteCount: r.summary.totalBytes, countStyle: .file) + ", \(r.summary.fileCount) file\(r.summary.fileCount == 1 ? "" : "s")").font(.system(size: 12))
            Text("Pieces: \(r.summary.pieceCount) of " + TorrentCreator.describe(r.summary.pieceLength)).font(.system(size: 12)).foregroundStyle(.secondary)
            if let v1 = r.infoHashV1 { hashLine("Info hash (v1)", v1) }
            if let v2 = r.infoHashV2 { hashLine("Info hash (v2)", v2) }
            if !r.summary.skipped.isEmpty { Text("Skipped \(r.summary.skipped.count) item\(r.summary.skipped.count == 1 ? "" : "s") (links and system files are not included).").font(.system(size: 11.5)).foregroundStyle(.secondary) }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .transition(.opacity)
    }

    private func hashLine(_ title: String, _ hash: Data) -> some View {
        Text(title + ": " + hash.map { String(format: "%02x", $0) }.joined()).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).lineLimit(2)
    }

    private var footer: some View {
        HStack {
            if let note = model.savedNote { Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            Spacer()
            if model.working {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Close") { done() }.keyboardShortcut(.cancelAction)
                if model.result != nil {
                    Button("Copy Magnet") { model.copyMagnet() }
                    Button("Save .torrent…") { model.save() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Create") { model.start() }.keyboardShortcut(.defaultAction).disabled(model.layout == nil)
                }
            }
        }
    }
}
