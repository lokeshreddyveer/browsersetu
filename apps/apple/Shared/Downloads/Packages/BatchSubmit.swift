import Foundation

// Phase 19: making many downloads from a reviewed selection. Each one is an ordinary task made the ordinary way (`scheduleDownload`), so the shared scheduler decides when it runs and
// the "downloads at once" limit holds; submitting two hundred is two hundred records, not two hundred transfers at once. The package is only the grouping.

enum BatchGrouping: String, CaseIterable, Identifiable, Sendable {
    case none, host, type
    var id: String { rawValue }
    var title: String { switch self { case .none: "One package"; case .host: "By website"; case .type: "By type" } }
}

struct BatchRequest: Sendable {
    /// Asking again with the same id finds what the first ask made instead of making it again.
    var id = UUID()
    var name: String
    var grouping = BatchGrouping.none
    /// Folders for the files, built from {package}, {host}, {directory}, {date}.
    var folderTemplate = "{package}"
    /// Where the items come from ("feed:<address>"). With it, items already collected from the same source are not made again and new ones join the collection that source already has.
    var source: String?
}

struct BatchResult: Equatable {
    var packages: [UUID] = []
    var started = 0
    var alreadyDownloading = 0
    var duplicatesInSelection = 0
    /// Items already part of this source's collection (running, or finished with their file still there).
    var alreadyCollected = 0
    /// Understood, but each needs its own preview and approval (streams, magnets, eD2k links, torrent files on this Mac): never made here.
    var needsOwnApproval: [String] = []
    var refused: [String] = []
    var tooMany = false
    var replayed = false
    var cancelled = false
    /// The selected links that now are tasks (or already were), so the collection can let them go.
    var handled: Set<String> = []
}

@MainActor
enum BatchSubmitter {
    static let chunk = 20
    /// Items being made into tasks right now by some submit (source + item identity). A second submit of the same items while the first is still working skips them: two quick clicks, or two
    /// windows, make each item once.
    private static var inFlight = Set<String>()

    static func submit(_ request: BatchRequest, links: [DetectedLink], isPrivate: Bool, coordinator: DownloadCoordinator) async -> BatchResult {
        var result = BatchResult()
        // The same batch asked for again finds what it made. Nothing is looked at or made a second time.
        let earlier = coordinator.packages.packages.filter { $0.batchKey?.hasPrefix(request.id.uuidString + "|") == true }
        if !earlier.isEmpty { result.packages = earlier.map(\.id); result.replayed = true; return result }
        // A private collection never makes tasks: they would be kept in the ordinary list.
        if isPrivate { result.refused = links.map { _ in "Downloads from a private session are not made here: they would be kept in the ordinary list." }; return result }

        let live = LinkClassifier.liveKeys(coordinator.ledger.records.values)
        var seen = Set<String>()
        var reserved: [String] = []
        defer { for k in reserved { inFlight.remove(k) } }
        var eligible: [(link: DetectedLink, url: URL)] = []
        for link in links {
            guard seen.insert(link.id).inserted else { result.duplicatesInSelection += 1; continue }
            if let source = request.source, let key = link.metadata["itemKey"], coordinator.packages.isCollected(key, source: source) { result.alreadyCollected += 1; result.handled.insert(link.id); continue }
            switch LinkRouter.route(link) {
            case .download(let url):
                guard link.kind == .httpResource || link.kind == .torrentURL else { result.refused.append("\(link.name): a web page, not a file"); continue }
                if LinkClassifier.isLive(url, in: live) { result.alreadyDownloading += 1; result.handled.insert(link.id); continue }
                if eligible.count >= LinkGrabberStore.maxBatchAdd { result.tooMany = true; continue }
                let flight = (request.source ?? "") + "|" + (link.metadata["itemKey"] ?? link.id)
                guard inFlight.insert(flight).inserted else { result.alreadyDownloading += 1; result.handled.insert(link.id); continue }
                reserved.append(flight)
                eligible.append((link, url))
            case .preview, .previewLocalTorrent, .mediaPreview, .videoPage: result.needsOwnApproval.append(link.name)
            case .refused(let why): result.refused.append("\(link.name): \(why)")
            }
        }
        guard !eligible.isEmpty else { return result }

        var groups: [(key: String, items: [(link: DetectedLink, url: URL)])] = []
        func place(_ key: String, _ item: (link: DetectedLink, url: URL)) {
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].items.append(item) } else { groups.append((key, [item])) }
        }
        for item in eligible {
            switch request.grouping {
            case .none: place("", item)
            case .host: place(item.link.host ?? "other", item)
            case .type: place(item.link.kind.label, item)
            }
        }

        let packages = coordinator.packages
        var made = 0
        for group in groups {
            let name = group.key.isEmpty ? request.name : "\(request.name) – \(group.key)"
            let key = "\(request.id.uuidString)|\(group.key)"
            if let existing = packages.packages.first(where: { $0.batchKey == key }) { result.packages.append(existing.id); result.replayed = true; continue }
            // More from a source that already has a collection joins it; otherwise a collection is made (and remembers its source).
            let joined = request.source.flatMap { src in groups.count == 1 ? packages.package(withSource: src) : nil }
            guard let package = joined ?? packages.create(name: name, members: [], batchKey: key, source: request.source)?.package else { result.refused.append("\(name): too many packages"); continue }
            result.packages.append(package.id)
            packages.noteChosen(group.items.count, in: package.id)
            for item in group.items {
                if Task.isCancelled { result.cancelled = true; if package.members.isEmpty || packages.package(package.id)?.members.isEmpty == true { packages.deletePackage(package.id); result.packages.removeAll { $0 == package.id } }; return result }
                let origin: DownloadRequestOrigin = item.link.provenance == .pasted ? .user : .page
                guard let id = coordinator.scheduleDownload(url: item.url, at: Date(), filename: item.link.suggestedFilename, origin: origin) else { result.refused.append("\(item.link.name): could not be added"); continue }
                if !item.link.metadata.isEmpty { coordinator.ledger.update(id) { for (k, v) in item.link.metadata { $0.engineMetadata[k] = v } } }
                let folders = PackageFolderTemplate.components(request.folderTemplate, package: package.name, host: item.link.host, directory: PackageFolderTemplate.directory(of: item.url))
                packages.add([id], to: package.id)
                if request.source != nil, let itemKey = item.link.metadata["itemKey"] { packages.recordIdentity(itemKey, task: id, in: package.id) }
                if !folders.isEmpty { coordinator.ledger.update(id) { $0.engineMetadata["packageFolder"] = folders.joined(separator: "/") } }
                result.started += 1; result.handled.insert(item.link.id)
                made += 1
                if made % chunk == 0 { await Task.yield() }          // the interface stays responsive while a large batch is made
            }
        }
        return result
    }
}
