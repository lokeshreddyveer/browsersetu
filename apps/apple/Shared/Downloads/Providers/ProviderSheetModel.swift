import Foundation
import SwiftUI

/// State of the "Repositories & Models" sheet: an address, what was found there, what the person ticked, and the hand-off to the ordinary download queue.
@MainActor
final class ProviderSheetModel: ObservableObject {
    enum Phase: Equatable { case idle, loading, listed, failed(String) }

    @Published var address = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var listing: ProviderListing?
    @Published private(set) var routeLabel = ""
    @Published var selection = Set<String>()
    @Published var filter = ""
    @Published var format: String?                  // nil = all
    @Published var release: String?                 // nil = all (GitHub)
    @Published private(set) var message: String?
    @Published private(set) var working = false
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var recommendation: GitHubRecommendation.Result?
    @Published var isPrivate = false

    let service: ProviderService
    private var loadTask: Task<Void, Never>?, runTask: Task<Void, Never>?
    /// More files than this ask first, naming the count, the size and where they come from.
    static let confirmAbove = 200
    static let rowLimit = 1000

    init(coordinator: DownloadCoordinator, service: ProviderService? = nil) { self.service = service ?? ProviderService(coordinator: coordinator) }

    // MARK: Finding

    func open(address: String) { self.address = address; load() }

    func load() {
        loadTask?.cancel(); runTask?.cancel()
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        reset()
        guard !isPrivate else { phase = .failed("Repository and model downloads are not available in a private tab: they use saved access tokens and are kept in a collection. Open this in a normal tab."); return }
        guard let url = URL(string: text), url.scheme != nil, let route = service.route(for: url) else {
            phase = .failed(text.isEmpty ? "Paste the address of a GitHub repository or release, a Hugging Face model or dataset, a storage bucket, or a signed link." : ProviderError.unsupportedAddress.localizedDescription)
            return
        }
        routeLabel = route.label
        phase = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let l = try await service.listing(for: route)
                guard !Task.isCancelled else { return }
                var seen = Set<String>(); var unique = l; unique.files = l.files.filter { seen.insert($0.id).inserted }; listing = unique
                if case .github = route { recommendation = GitHubRecommendation.pick(l.files, arch: ProviderPlatform.currentArch); if let id = recommendation?.fileID { selection = [id] } }
                else if l.files.count == 1 { selection = [l.files[0].id] }
                phase = .listed
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled else { return }
                phase = .failed((error as? ProviderError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func reset() { listing = nil; selection = []; filter = ""; format = nil; release = nil; message = nil; progress = nil; recommendation = nil; phase = .idle; routeLabel = "" }

    // MARK: Choosing

    var formats: [String] { Array(Set((listing?.files ?? []).map { ProviderFormats.group($0.name) })).sorted() }
    var releases: [String] { listing?.releaseNames ?? [] }
    var showsFormats: Bool { if case .listed = phase, !(listing?.releaseNames.isEmpty == false) { return formats.count > 1 } else { return false } }

    /// Every file matching the filters (not only the ones on screen).
    var matching: [ProviderFile] {
        guard let l = listing else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return l.files.filter { f in
            (needle.isEmpty || f.relativePath.lowercased().contains(needle))
            && (format == nil || ProviderFormats.group(f.name) == format)
            && (release == nil || f.group == release)
        }
    }
    var shown: [ProviderFile] { Array(matching.prefix(Self.rowLimit)) }
    var selectedFiles: [ProviderFile] { (listing?.files ?? []).filter { selection.contains($0.id) } }
    var selectedBytes: Int64 { ProviderNames.sum(selectedFiles) }
    var unknownSizes: Int { selectedFiles.filter { $0.size == nil }.count }

    func toggle(_ id: String) { if selection.contains(id) { selection.remove(id) } else { selection.insert(id) } }
    func selectMatching() { selection.formUnion(matching.map(\.id)) }
    func clearSelection() { selection = [] }
    func selectRecommended() { if let id = recommendation?.fileID { selection = [id] } }

    // MARK: Downloading

    func summary(of files: [ProviderFile]) -> String {
        let bytes = ProviderNames.sum(files)
        let unknown = files.filter { $0.size == nil }.count
        return "\(files.count) file\(files.count == 1 ? "" : "s"), " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + (unknown > 0 ? " plus \(unknown) of unknown size" : "")
    }

    func startDownload() {
        guard let l = listing, !working, !selectedFiles.isEmpty else { return }
        let files = selectedFiles
        working = true
        runTask = Task { [weak self] in
            guard let self else { return }
            do { try service.checkSpace(files) } catch { working = false; message = (error as? ProviderError)?.errorDescription ?? error.localizedDescription; return }
            if files.count > Self.confirmAbove {
                let answer = await Dialogs.choose(title: "Download \(files.count) files?", message: "From \(l.title) (\(routeLabel)):\n\(summary(of: files)).\nThey are added to one collection and use the normal download queue. You can pause or cancel from the Downloads window.", buttons: ["Cancel", "Download"])
                guard answer == 1 else { working = false; message = "Nothing was started."; return }
            }
            progress = (0, files.count); message = nil
            let out = await service.download(l, files: files, isPrivate: isPrivate) { [weak self] done, total in self?.progress = (done, total) }
            working = false; progress = nil
            message = Self.sentence(out)
            if out.started > 0 { selection = [] }
        }
    }

    func cancel() { runTask?.cancel() }

    static func sentence(_ o: ProviderService.Outcome) -> String {
        var parts = ["Started \(o.started)"]
        if o.alreadyThere > 0 { parts.append("\(o.alreadyThere) already in the collection") }
        if o.failedToStart > 0 { parts.append("\(o.failedToStart) could not be started (an expired link or a refused address)") }
        if o.notStarted > 0 { parts.append("\(o.notStarted) not started") }
        var s = parts.joined(separator: ", ") + "."
        if let why = o.stoppedBy { s += " " + (why == "cancelled" ? "Stopped. Choose the same files again later to add the rest." : why) }
        return s
    }
}
