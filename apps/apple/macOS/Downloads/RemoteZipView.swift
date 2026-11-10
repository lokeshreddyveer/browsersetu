import SwiftUI

/// "Open Archive from Address…": the contents of a ZIP archive on a website, read from a few small pieces of it. Nothing is downloaded until the person chooses entries and presses Download.
@MainActor
final class RemoteZipModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, ready, failed(String, canTakeWhole: Bool) }
    let coordinator: DownloadCoordinator
    @Published var address = ""
    @Published var phase = Phase.idle
    @Published var listing: RemoteZipListing?
    @Published var selection = Set<Int>()
    @Published var search = ""
    @Published var onlyTakeable = false
    @Published var busy = false
    @Published var message: String?
    private var task: Task<Void, Never>?
    /// Where the address came from. A typed address is the person's own; one supplied by a page keeps the page rules until they change it.
    private var supplied: String?
    var suppliedOrigin: DownloadRequestOrigin = .user

    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    func prefill(_ text: String, origin: DownloadRequestOrigin) { address = text; supplied = text; suppliedOrigin = origin }
    private var origin: DownloadRequestOrigin { address.trimmingCharacters(in: .whitespaces) == supplied ? suppliedOrigin : .user }
    /// The origin the contents were read under. The download is made under the same one, whatever the address field says by then.
    private var loadedOrigin: DownloadRequestOrigin = .user

    var visible: [ZipEntry] {
        guard let l = listing else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return l.entries.filter { (q.isEmpty || $0.name.lowercased().contains(q)) && (!onlyTakeable || $0.isSupported) }
    }

    func load() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), DownloadSchedule.canSchedule(url) else { phase = .failed("That is not a web address.", canTakeWhole: false); return }
        task?.cancel(); phase = .loading; listing = nil; selection = []; message = nil
        let o = origin
        loadedOrigin = o
        task = Task {
            do {
                let l = try await coordinator.remoteZip.inspect(url, origin: o)
                guard !Task.isCancelled else { return }
                listing = l; phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                let z = error as? RemoteZipError
                phase = .failed((error as? LocalizedError)?.errorDescription ?? HTTPResponseRules.failure(for: error).info.reason, canTakeWhole: z == .rangesUnavailable || z == .noValidator)
            }
        }
    }
    func cancel() { task?.cancel() }

    func selectAllTakeable() { selection = Set(visible.filter(\.isSupported).map(\.id)) }

    /// The chosen entries, and the folders among them with everything inside.
    func toggle(_ e: ZipEntry) {
        guard e.isSupported else { return }
        var ids: Set<Int> = [e.id]
        if e.isDirectory, let l = listing { ids = Set(l.entries.filter { $0.isSupported && ($0.name.hasPrefix(e.name) || $0.id == e.id) }.map(\.id)) }
        if selection.contains(e.id) { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func download() {
        guard let listing, !selection.isEmpty, !busy else { return }
        busy = true
        let o = loadedOrigin
        Task {
            do { _ = try await coordinator.remoteZip.add(listing, selecting: selection, origin: o); message = "Started. The files are saved in a folder in Downloads when all are in." }
            catch { message = (error as? LocalizedError)?.errorDescription ?? "It could not be started." }
            busy = false
        }
    }
}

struct RemoteZipSheet: View {
    @EnvironmentObject var model: BrowserModel
    var done: () -> Void
    var body: some View { RemoteZipContent(model: model.remoteZipModel, done: done) }
}

private struct RemoteZipContent: View {
    @ObservedObject var model: RemoteZipModel
    var done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.zipper").foregroundStyle(Theme.accent)
                Text("Open Archive from Address").font(.system(size: 15, weight: .semibold))
                if model.phase == .loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { model.cancel(); done() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 8) {
                TextField("https://example.com/files/archive.zip", text: $model.address).textFieldStyle(.roundedBorder).onSubmit { model.load() }
                Button("Read Contents") { model.load() }.buttonStyle(.borderedProminent).disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty || model.phase == .loading)
            }.controlSize(.small).padding(.horizontal, 16).padding(.bottom, 8)
            Divider().opacity(0.5)
            content
            Divider().opacity(0.5)
            footer
        }
        .frame(minWidth: 720, minHeight: 440)
        .onDisappear { model.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            Text("Enter the address of a ZIP archive. Only its table of contents is read (a few kilobytes); the archive itself is not downloaded.").font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            Text("Reading the contents…").font(.system(size: 12.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let why, let whole):
            VStack(spacing: 10) {
                Label(why, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(.orange).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                if whole { Text("Downloading the whole archive is a separate choice: use Add Download. Nothing has been downloaded.").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if let l = model.listing {
                        Text("\(l.name).zip · \(DownloadStats.bytes(l.total)) · \(l.entries.count) entries" + (l.zip64 ? " · ZIP64" : "")).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 160)
                    Toggle("Only what can be taken", isOn: $model.onlyTakeable).toggleStyle(.checkbox)
                }.controlSize(.small).font(.system(size: 11.5)).padding(.horizontal, 16).padding(.vertical, 6)
                List {
                    ForEach(model.visible) { e in
                        HStack(spacing: 8) {
                            Image(systemName: model.selection.contains(e.id) ? "checkmark.square.fill" : "square").foregroundStyle(e.isSupported ? Theme.accent : Color.secondary.opacity(0.4)).onTapGesture { model.toggle(e) }
                            Image(systemName: e.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.name).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle).foregroundStyle(e.isSupported ? Color.primary : Color.secondary)
                                if case .unsupported(let why) = e.status { Text(why).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2) }
                            }
                            Spacer()
                            if !e.isDirectory { Text("\(DownloadStats.bytes(Int64(clamping: e.compressedSize))) → \(DownloadStats.bytes(Int64(clamping: e.uncompressedSize)))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                        }
                    }
                }.listStyle(.inset)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Select All That Can Be Taken") { model.selectAllTakeable() }.disabled(model.listing == nil)
            Button("Clear") { model.selection = [] }.disabled(model.selection.isEmpty)
            Spacer()
            if let m = model.message { Text(m).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1) }
            else if let l = model.listing, !model.selection.isEmpty {
                Text("\(model.selection.count) chosen · about \(DownloadStats.bytes(l.bytesToFetch(model.selection))) to download, \(DownloadStats.bytes(l.uncompressed(model.selection))) when unpacked").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else { Text("Choose entries to take").font(.system(size: 11.5)).foregroundStyle(.secondary) }
            Button("Download Selected") { model.download() }.buttonStyle(.borderedProminent).disabled(model.selection.isEmpty || model.busy)
        }.controlSize(.small).padding(.horizontal, 16).frame(height: 40)
    }
}
