import Foundation

/// The one capability layer for repositories, models, datasets and cloud storage. It recognises an address, lists what is there, and submits the chosen files as ordinary tasks of the ordinary HTTP engine,
/// grouped into one ordinary collection. It has no queue, no transfer code and no storage of its own.
enum ProviderRoute: Equatable {
    case github(GitHubProvider.Target)
    case huggingFace(HuggingFaceProvider.Target)
    case cloud(CloudStorageProvider.Target)
    case signedFile(URL)

    var label: String {
        switch self { case .github: "GitHub"; case .huggingFace(let t): t.kind == .model ? "Hugging Face model" : "Hugging Face dataset"; case .cloud: "Cloud storage"; case .signedFile: "Signed link" }
    }

    /// What the address is, or nil. Ordinary websites are never claimed: an address that is not clearly one of these stays an ordinary page.
    /// The web hosts treated as GitHub and Hugging Face. Debug builds can point them at local stand-ins for the UI tests; release builds always use the real ones.
    static var defaultGitHubHost: String {
        #if DEBUG
        if let v = UserDefaults.standard.string(forKey: "UIProviderGitHubHost") { return v }
        #endif
        return "github.com"
    }
    static var defaultHFHost: String {
        #if DEBUG
        if let v = UserDefaults.standard.string(forKey: "UIProviderHFHost") { return v }
        #endif
        return "huggingface.co"
    }

    static func recognise(_ url: URL, githubHost: String = ProviderRoute.defaultGitHubHost, hfHost: String = ProviderRoute.defaultHFHost) -> ProviderRoute? {
        if SignedURL.isSigned(url) { return .signedFile(url) }          // a signed address is a link to one object, whatever its host
        if let t = GitHubProvider.parse(url, webHost: githubHost) { return .github(t) }
        if let t = HuggingFaceProvider.parse(url, host: hfHost) { return .huggingFace(t) }
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".blob.core.windows.net"), let t = CloudStorageProvider.parse(url) { return .cloud(t) }
        if SignedURL.isSigned(url) { return .signedFile(url) }
        if host.contains(".s3.") || host.contains(".s3-") || host == "storage.googleapis.com", let t = CloudStorageProvider.parse(url) { return .cloud(t) }
        return nil
    }
}

@MainActor
final class ProviderService {
    struct Outcome: Equatable { var started = 0, alreadyThere = 0, failedToStart = 0, notStarted = 0, stoppedBy: String?, source = "" }

    private weak var weakCoordinator: DownloadCoordinator?
    private var coordinator: DownloadCoordinator { weakCoordinator! }          // (callers check `alive` first; a profile switch replaces the coordinator)
    var alive: Bool { weakCoordinator != nil }
    let transport: ProviderTransport
    var githubAPI = URL(string: "https://api.github.com")!
    var githubHost = "github.com"
    var hfEndpoint = URL(string: "https://huggingface.co")!
    var hfHost = "huggingface.co"
    /// Files started per second at most (the services count requests; a burst of thousands is how a token gets limited).
    var pacing: TimeInterval = 0.01

    init(coordinator: DownloadCoordinator, transport: ProviderTransport? = nil) {
        self.weakCoordinator = coordinator
        if let transport { self.transport = transport; return }
        let router = coordinator.accountStore?.router
        #if DEBUG
        // Native UI tests point the services at local stand-ins. Not compiled into a release build.
        let d = UserDefaults.standard
        if let v = d.string(forKey: "UIProviderGitHubAPI"), let u = URL(string: v) { githubAPI = u }
        if let v = d.string(forKey: "UIProviderGitHubHost") { githubHost = v }
        if let v = d.string(forKey: "UIProviderHFEndpoint"), let u = URL(string: v) { hfEndpoint = u }
        if let v = d.string(forKey: "UIProviderHFHost") { hfHost = v }
        #endif
        self.transport = URLSessionProviderTransport(
            authorization: { url in if case .use(_, let header)? = router?.decide(url, origin: .user) { return header } else { return nil } },
            policyCheck: { try HTTPRequestPolicy(origin: .user).check($0) })
    }

    private var tokenCheck: @Sendable (URL) -> Bool {
        let router = coordinator.accountStore?.router
        return { url in if case .use? = router?.decide(url, origin: .user) { return true } else { return false } }
    }

    func route(for url: URL) -> ProviderRoute? { ProviderRoute.recognise(url, githubHost: githubHost, hfHost: hfHost) }

    func listing(for route: ProviderRoute) async throws -> ProviderListing {
        switch route {
        case .github(let t):
            var p = GitHubProvider(transport: transport); p.apiBase = githubAPI; p.webHost = githubHost; p.hasToken = tokenCheck
            return try await p.listing(t)
        case .huggingFace(let t):
            var p = HuggingFaceProvider(transport: transport); p.endpoint = hfEndpoint; p.hasToken = tokenCheck
            return try await p.listing(t)
        case .cloud(let t):
            return try await CloudStorageProvider(transport: transport).listing(t)
        case .signedFile(let url):
            if SignedURL.isExpired(url) { throw ProviderError.expiredLink }
            let name = DownloadFilename.derive(contentDisposition: nil, url: url).name
            var f = ProviderFile(id: "signed:0", name: name, url: url, kind: .object)
            if let end = SignedURL.expiry(url) { f.note = "Link valid until \(end.formatted(date: .abbreviated, time: .shortened))." }
            return ProviderListing(title: "Signed link — \(url.host ?? "")", source: "signed:\(url.host ?? "")/\(name)", files: [f], notices: ["This address contains a secret. It is shown here without its secret part and is never written to logs."])
        }
    }

    /// Free space must cover the files with room to spare, or nothing is started.
    func checkSpace(_ files: [ProviderFile]) throws {
        let needed = ProviderNames.sum(files)
        guard needed > 0 else { return }
        let dir = DownloadCoordinator.directory
        let free = DiskSpace.available(at: dir) ?? Int64.max
        if !DiskSpace.fits(needed: needed, available: free, floor: 256_000_000, divisor: 50) { throw ProviderError.notEnoughSpace(needed: needed, available: free) }
    }

    /// A collection holds at most this many tasks (the Downloads list keeps a bounded history, so one collection for tens of thousands of files would lose track of the finished ones).
    static let chunkSize = 1000

    /// Makes (or finds) the collection(s) and starts one task per chosen file not already there. A refresh adds only what is new; a stop (rate limit, cancel) leaves collections that a second run completes.
    /// "Already there" is the collection's own record, or, when the Downloads history no longer remembers a finished file, the file itself at its place with the length the service states.
    func download(_ listing: ProviderListing, files: [ProviderFile], isPrivate: Bool, progress: ((Int, Int) -> Void)? = nil) async -> Outcome {
        var out = Outcome(); out.source = listing.source
        let baseName = PackageStore.cleanName(listing.title)
        let position = Dictionary(listing.files.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let chunks = max(1, (listing.files.count + Self.chunkSize - 1) / Self.chunkSize)
        var cache: [Int: (source: String, package: DownloadPackage?)] = [:]
        var chosenIn: [Int: Int] = [:]
        func place(_ chunk: Int) -> (source: String, package: DownloadPackage?, folder: String) {
            let source = chunk == 0 ? listing.source : listing.source + "#part\(chunk + 1)"
            let name = PackageStore.cleanName(chunks > 1 ? "\(baseName) (part \(chunk + 1) of \(chunks))" : baseName)
            if let c = cache[chunk] { return (c.source, c.package, PackageFolderTemplate.clean(name) ?? "Collection") }
            // A private session keeps no collection (a package never holds a private task); its files are plain tasks.
            let package = isPrivate ? nil : (coordinator.packages.package(withSource: source) ?? coordinator.packages.create(name: name, members: [], source: source)?.package)
            cache[chunk] = (source, package)
            return (source, package, (PackageFolderTemplate.clean(name) ?? "Collection"))
        }
        var recent: [UUID] = []
        for (index, file) in files.enumerated() {
            guard alive else { out.notStarted = files.count - index; out.stoppedBy = "cancelled"; break }
            if Task.isCancelled { out.notStarted = files.count - index; out.stoppedBy = "cancelled"; break }
            if recent.contains(where: { (coordinator.ledger.record($0)?.failure?.code == "http:429" || coordinator.ledger.record($0)?.engineMetadata["rateLimited"] == "1") }) {
                out.notStarted = files.count - index
                out.stoppedBy = "The service is limiting requests, so the rest was not started. Choose the same files again later: what is already there is kept and only the rest is added."
                break
            }
            let chunk = (position[file.id] ?? 0) / Self.chunkSize
            let spot = place(chunk)
            let key = file.id + "#0"
            if !isPrivate, coordinator.packages.isCollected(key, source: spot.source) { out.alreadyThere += 1; continue }
            if file.kind == .object, SignedURL.isExpired(file.url) { out.failedToStart += 1; continue }          // an expired address is not started; its owner must give a new one
            let folderPath = ([isPrivate ? nil : spot.folder].compactMap { $0 } + file.folders).joined(separator: "/")
            if !isPrivate, let want = file.size, Self.fileExists(DownloadCoordinator.directory, folderPath, file.name, size: want) { out.alreadyThere += 1; continue }
            chosenIn[chunk, default: 0] += 1
            var options = HTTPDownloadRunner.Options()
            options.origin = .user
            options.filename = file.name
            options.expectedSHA256 = file.sha256
            options.expectedSize = file.kind == .artifact ? nil : file.size
            options.accept = file.headers["Accept"]
            options.lfsPointerGuard = file.kind == .lfsFile
            options.provider = String(listing.source.prefix(while: { $0 != ":" }))
            options.packageFolder = folderPath
            options.headers = file.headers            // (Accept only: a service's token is added by the account router for its own host, never here)
            do {
                let id = try await coordinator.http.start(url: file.url, options: options)
                out.started += 1
                recent.append(id); if recent.count > 12 { recent.removeFirst() }
                if let package = spot.package {
                    coordinator.packages.add([id], to: package.id)
                    coordinator.packages.recordIdentity(key, task: id, in: package.id)
                    if !folderPath.isEmpty { coordinator.ledger.update(id) { if [.created, .queued, .scheduled].contains($0.state) { $0.engineMetadata["packageFolder"] = folderPath } } }
                }
            } catch { out.failedToStart += 1 }
            progress?(index + 1, files.count)
            if pacing > 0 { try? await Task.sleep(nanoseconds: UInt64(pacing * 1_000_000_000)) }
        }
        for (chunk, n) in chosenIn { if let package = cache[chunk]?.package { coordinator.packages.noteChosen(n, in: package.id) } }
        return out
    }

    static func fileExists(_ root: URL, _ folder: String, _ name: String, size: Int64) -> Bool {
        let url = (folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)).appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), (attrs[.type] as? FileAttributeType) == .typeRegular else { return false }
        return (attrs[.size] as? NSNumber)?.int64Value == size
    }
}
