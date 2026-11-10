import Foundation

// The Remote Files sheet's logic: choose or type a server, trust its key or certificate, sign in, browse folders a page at a time, choose files and folders, and hand them to the download queue as
// a collection. Nothing here is a transfer engine: the files become ordinary tasks (RemoteFileRunner for FTP/SFTP, the HTTP engine for WebDAV).

@MainActor
final class RemoteBrowserModel: ObservableObject {
    enum Phase: Equatable {
        case idle, connecting, browsing
        case hostKey(HostKeyInfo)
        case hostKeyChanged(old: [String], new: HostKeyInfo)
        case certificate(fingerprint: String)
        case failed(String)
    }

    let coordinator: DownloadCoordinator
    init(coordinator: DownloadCoordinator) { self.coordinator = coordinator }

    // The form.
    @Published var scheme: RemoteScheme = .sftp { didSet { if port.isEmpty || Int(port) == oldValue.defaultPort { port = String(scheme.defaultPort) }; if scheme == .sftp, auth == .anonymous { auth = .agent }; if scheme != .sftp, auth == .agent || auth == .key { auth = .password } } }
    @Published var host = ""
    @Published var port = "22"
    @Published var user = ""
    @Published var password = ""
    @Published var auth: RemoteConnection.Auth = .agent
    @Published var keyPath = ""
    @Published var remember = true
    @Published var address = ""
    @Published var startPath = "/"

    // State.
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var connection: RemoteConnection?
    @Published private(set) var path = "/"
    @Published private(set) var entries: [RemoteEntry] = []
    @Published private(set) var listing = false
    @Published private(set) var truncated = false
    @Published var selection = Set<String>()
    @Published var search = ""
    @Published var message: String?
    /// A change being made on the server (an upload or a delete): shown with its progress and a Cancel.
    @Published private(set) var operation: Operation?
    struct Operation: Equatable { var title: String; var done: Int; var total: Int; var current: String }
    private var operationTask: Task<Void, Never>?
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// True for a private tab: nothing is remembered.
    var isPrivate = false { didSet { if isPrivate != oldValue { reset() } } }
    private(set) var origin: DownloadRequestOrigin = .user

    private var session: RemoteSession?
    /// The session that is still signing in: held here so Disconnect (or another connection) can end its ssh process.
    private var connecting: RemoteSession?
    private var back: [String] = [], forward: [String] = []
    private var pending: (connection: RemoteConnection, secret: String?)?
    private var pendingCertificate: String?
    private var task: Task<Void, Never>?
    private var listTask: Task<Void, Never>?
    /// Counts connection attempts: an attempt that was replaced or cancelled while it waited on the network must not change what the person sees.
    private var generation = 0

    var saved: [RemoteConnection] { coordinator.remotes.connections }
    private var network: DownloadNetworkSetup { coordinator.http.engine.currentNetwork }

    var visible: [RemoteEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? entries : entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return base
    }
    var selectedEntries: [RemoteEntry] { entries.filter { selection.contains($0.name) && ($0.isDirectory || $0.isDownloadable) } }
    var selectedBytes: Int64 { selectedEntries.filter { !$0.isDirectory }.reduce(0) { $0 + ($1.size ?? 0) } }
    /// A sentence when the connection is not encrypted (FTP, WebDAV over http): it says what that means.
    var securityNote: String? {
        let s = connection?.scheme ?? scheme
        return s.isEncrypted ? nil : "This connection is not encrypted: a password and the files can be read by anyone on the network."
    }

    // MARK: Opening

    func reset() {
        generation += 1; listing = false; search = ""; truncated = false
        task?.cancel(); listTask?.cancel(); connecting?.close(); connecting = nil; session?.close(); session = nil
        endPrivateTrustIfIdle()
        phase = .idle; connection = nil; entries = []; selection = []; message = nil; pending = nil; pendingCertificate = nil; back = []; forward = []; canGoBack = false; canGoForward = false
    }

    /// An address from the address bar, a link or the field: filled into the form. A typed address connects at once when nothing more is needed; an address that a page supplied only fills the form
    /// (the person presses Connect), so a page can never make the browser contact a server by itself.
    func open(address text: String, origin: DownloadRequestOrigin) {
        self.origin = origin
        guard let parsed = RemoteConnection.from(address: text) else { reset(); message = "That is not an address this can open. Use ftp://, ftps://, sftp:// or dav(s)://."; return }
        reset()
        fill(from: parsed.connection); startPath = parsed.path; address = text
        // A server the person already saved is reused with its own settings.
        if let known = saved.first(where: { $0.host.lowercased() == parsed.connection.host.lowercased() && $0.port == parsed.connection.port && $0.scheme == parsed.connection.scheme && ($0.user ?? "") == (parsed.connection.user ?? "") }) {
            fill(from: known); if known.auth != .agent || true { startPath = parsed.path == "/" ? known.path : parsed.path }
        }
        if origin == .page { message = "A web page asked to open this server. Check the address, then press Connect."; return }
        if auth == .password, (coordinator.remotes.secret(for: saved.first(where: { $0.host.lowercased() == host.lowercased() && $0.port == Int(port) })?.id ?? UUID()) ?? "").isEmpty, password.isEmpty { return }          // asks for the password
        connectFromForm()
    }

    func use(_ c: RemoteConnection) {
        reset(); fill(from: c); startPath = c.path
        connectFromForm()
    }

    private func fill(from c: RemoteConnection) {
        scheme = c.scheme; host = c.host; port = String(c.port); user = c.user ?? ""; auth = c.auth; keyPath = c.keyPath ?? ""; startPath = c.path
        #if DEBUG
        // Test seam (Debug builds only): lets a native UI test sign in to its own throwaway SSH server with a throwaway key, without a file dialog.
        if c.scheme == .sftp, let key = UserDefaults.standard.string(forKey: "UITestRemoteKey"), !key.isEmpty { auth = .key; keyPath = key }
        #endif
    }

    func forget(_ c: RemoteConnection) {
        // The website account made for this server's WebDAV downloads goes with it (it was shared by every download from that host and port).
        if let id = c.davAccountID { coordinator.accountStore?.delete(id) }
        coordinator.remotes.delete(c.id); objectWillChange.send()
    }

    /// A private session's trust (host keys, certificates) lasts only while it is in use: when nothing private is connected or downloading any more it is removed.
    func endPrivateTrustIfIdle() {
        guard coordinator.remotes.hasPrivateScratch else { return }
        let live = coordinator.ledger.records.values.contains { $0.protocolID == .remoteFile && $0.isPrivate && !$0.state.isFinal && $0.state != .failed }
        if !live { coordinator.remotes.wipePrivateScratch() }
    }

    func connectFromForm() {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, let p = Int(port), (1...65535).contains(p) else { message = "Enter the server's name and a port."; return }
        if auth == .password, user.trimmingCharacters(in: .whitespaces).isEmpty { message = "Enter the user name."; return }
        if auth == .key, keyPath.isEmpty { message = "Choose the key file."; return }
        var c = RemoteConnection(name: h, scheme: scheme, host: h, port: p, user: user.trimmingCharacters(in: .whitespaces).isEmpty ? nil : user.trimmingCharacters(in: .whitespaces), auth: auth, keyPath: auth == .key ? keyPath : nil, path: startPath.isEmpty ? "/" : startPath)
        if let existing = saved.first(where: { $0.host.lowercased() == h.lowercased() && $0.port == p && $0.scheme == scheme && ($0.user ?? "") == (c.user ?? "") }) { c.id = existing.id; c.createdAt = existing.createdAt; c.name = existing.name }
        var secret: String? = password.isEmpty ? nil : password
        if secret == nil, auth == .password || auth == .key { secret = coordinator.remotes.secret(for: c.id) }
        connect(c, secret: secret)
    }

    // MARK: Connecting

    private func connect(_ c: RemoteConnection, secret: String?) {
        task?.cancel(); connecting?.close(); connecting = nil; session?.close(); session = nil
        generation += 1; let gen = generation
        phase = .connecting; message = nil; entries = []; selection = []
        pending = (c, secret)
        task = Task { [weak self] in await self?.establish(c, secret: secret, generation: gen) }
    }

    private func establish(_ c: RemoteConnection, secret: String?, generation gen: Int) async {
        func current() -> Bool { gen == generation && !Task.isCancelled }
        do {
            if c.auth == .password, (secret ?? "").isEmpty { phase = .idle; message = "Enter the password."; return }
            if c.scheme == .sftp {
                let offered = try await SSHHostKeyStore.scan(host: c.host, port: c.port)
                guard current() else { return }
                if offered.isEmpty { throw RemoteError.unreachable("the server did not offer a host key (is SFTP/SSH running on port \(c.port)?)") }
                switch coordinator.remotes.hostKeys(isPrivate: isPrivate).verdict(host: c.host, port: c.port, offered: offered) {
                case .trusted: break
                case .unknown(let k): phase = .hostKey(k); return
                case .changed(let old, let new): phase = .hostKeyChanged(old: old, new: new); return
                }
            }
            if c.scheme.isWebDAV, c.auth == .password, c.scheme == .webdav { message = "This WebDAV address is not encrypted (http). The password is not sent over it by this app: browsing and downloads will be anonymous." }
            let s = try coordinator.remotes.makeSession(for: c, secret: secret, network: network, origin: origin == .page ? .user : origin, isPrivate: isPrivate)
            connecting = s
            if let sftp = s as? SFTPSession { do { try await sftp.connect() } catch { sftp.close(); if connecting === sftp { connecting = nil }; throw error } }
            guard current() else { s.close(); return }
            connecting = nil
            session = s; connection = c
            // Kept only now that the sign-in worked.
            if remember && !isPrivate { if !coordinator.remotes.save(c, secret: secret) { coordinator.remotes.useOnce(c, secret: secret); message = "The Keychain would not save the password, so this server was not remembered." } }
            else { coordinator.remotes.useOnce(c, secret: secret) }
            var start = c.path.isEmpty ? "/" : c.path
            if c.scheme == .sftp, start == "/" { start = (try? await s.canonical(".")) ?? "/" }
            phase = .browsing
            await listFolder(start, pushHistory: false)
        } catch is CancellationError { return }
        catch let e as RemoteError {
            guard current() else { return }
            if case .certificateRejected = e, c.scheme == .ftps { await offerCertificate(c); return }
            phase = .failed(e.errorDescription ?? "The connection failed.")
        } catch { guard current() else { return }; phase = .failed((error as? LocalizedError)?.errorDescription ?? "The connection failed.") }
    }

    private func offerCertificate(_ c: RemoteConnection) async {
        do {
            let cert = try await FTPSession.presentedCertificate(host: c.host, port: c.port, implicit: c.port == 990)
            pendingCertificate = cert.pem; phase = .certificate(fingerprint: cert.fingerprint)
        } catch { phase = .failed((error as? RemoteError)?.errorDescription ?? "The server's certificate could not be checked.") }
    }

    func trustAndContinue() {
        guard let (c, secret) = pending else { return }
        switch phase {
        case .hostKey(let key): do { try coordinator.remotes.hostKeys(isPrivate: isPrivate).trust(key, host: c.host, port: c.port) } catch { phase = .failed("The key could not be saved."); return }
        case .hostKeyChanged(_, let key): coordinator.remotes.hostKeys(isPrivate: isPrivate).forget(host: c.host, port: c.port); do { try coordinator.remotes.hostKeys(isPrivate: isPrivate).trust(key, host: c.host, port: c.port) } catch { phase = .failed("The key could not be saved."); return }
        case .certificate:
            guard let pem = pendingCertificate else { return }
            do { try coordinator.remotes.trustCertificate(pem: pem, for: c.id, isPrivate: isPrivate) } catch { phase = .failed("The certificate could not be saved."); return }
        default: return
        }
        connect(c, secret: secret)
    }

    func cancelPending() { reset() }

    // MARK: Browsing

    func open(_ entry: RemoteEntry) {
        guard entry.isDirectory, let full = RemoteNames.join(path, entry.name) else { return }
        listTask?.cancel(); listTask = Task { [weak self] in await self?.listFolder(full, pushHistory: true) }
    }
    func goUp() { let parent = RemoteNames.parent(of: path); guard parent != path else { return }; listTask?.cancel(); listTask = Task { [weak self] in await self?.listFolder(parent, pushHistory: true) } }
    func goBack() { guard let p = back.popLast() else { return }; forward.append(path); sync(); listTask?.cancel(); listTask = Task { [weak self] in await self?.listFolder(p, pushHistory: false) } }
    func goForward() { guard let p = forward.popLast() else { return }; back.append(path); sync(); listTask?.cancel(); listTask = Task { [weak self] in await self?.listFolder(p, pushHistory: false) } }
    func go(to p: String) { listTask?.cancel(); listTask = Task { [weak self] in await self?.listFolder(p, pushHistory: true) } }
    func reload(keepingMessage: Bool = false) { listTask?.cancel(); let p = path; listTask = Task { [weak self] in await self?.listFolder(p, pushHistory: false, keepMessage: keepingMessage) } }
    private func sync() { canGoBack = !back.isEmpty; canGoForward = !forward.isEmpty }

    private func listFolder(_ p: String, pushHistory: Bool, keepMessage: Bool = false) async {
        guard let session else { return }
        let previous = path
        listing = true; if !keepMessage { message = nil }; truncated = false
        if pushHistory, !entries.isEmpty || previous != p { back.append(previous); forward = [] }
        path = p; entries = []; selection = []; sync()
        let collector = Collector { [weak self] batch in Task { @MainActor [weak self] in
            guard let self, self.path == p else { return }
            self.entries = Self.sorted(self.entries + batch)
        } }
        do {
            let r = try await session.list(p, limit: 50_000) { collector.add($0) }
            try Task.checkCancellation()
            truncated = r.truncated
            if r.truncated { message = "Only the first 50,000 entries are listed." }
        } catch is CancellationError { return }
        catch let e as RemoteError {
            switch e {
            case .permissionDenied, .notFound:
                message = e.errorDescription
                if path == p, entries.isEmpty, let last = back.popLast() { path = last; sync(); await relist(last) }          // stay where the person was
            case .authenticationFailed, .connectionLost, .timedOut, .unreachable: phase = .failed(e.errorDescription ?? "The connection failed.")
            default: message = e.errorDescription
            }
        } catch { message = (error as? LocalizedError)?.errorDescription ?? "That folder could not be read." }
        listing = false
    }
    private func relist(_ p: String) async {
        guard let session else { return }
        let c = Collector { [weak self] batch in Task { @MainActor [weak self] in guard let self, self.path == p else { return }; self.entries = Self.sorted(self.entries + batch) } }
        _ = try? await session.list(p, limit: 50_000) { c.add($0) }
    }

    final class Collector: @unchecked Sendable {
        let sink: @Sendable ([RemoteEntry]) -> Void
        init(_ s: @escaping @Sendable ([RemoteEntry]) -> Void) { sink = s }
        func add(_ e: [RemoteEntry]) { sink(e) }
    }

    nonisolated static func sorted(_ list: [RemoteEntry]) -> [RemoteEntry] {
        // A server may list one name twice (a file and a folder of the same name): only the first is kept, so every row and selection is one thing.
        var seen = Set<String>()
        return list.filter { seen.insert($0.name).inserted }.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    func selectAllFiles() { selection = Set(entries.filter { $0.isDirectory || $0.isDownloadable }.map(\.name)) }
    func selectNone() { selection = [] }

    // MARK: Changing the server: upload and delete (never sync)

    /// Only in a normal tab, only on what the person chose, only while connected and nothing else is changing.
    var canChange: Bool { !isPrivate && phase == .browsing && connection != nil && operation == nil }

    func cancelOperation() { operationTask?.cancel() }

    private func serverName(_ c: RemoteConnection) -> String { c.name == c.host ? c.host : "\(c.name) (\(c.host))" }

    /// Deletes the selected files and folders. First the exact list is worked out and shown (a folder with its counts); the default button is Cancel. Folders are emptied before they are removed,
    /// links are removed as links, and a failure stops the operation and says how far it got.
    func requestDelete() {
        guard canChange else { message = isPrivate ? "A server cannot be changed from a private tab." : nil; return }
        guard let session, let c = connection, !selectedEntries.isEmpty else { return }
        let chosen = selectedEntries, here = path
        message = "Counting what would be removed…"
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await RemoteDeletePlanner.plan(session: session, roots: chosen, base: here)
                guard !plan.roots.isEmpty else { self.message = nil; return }
                var lines: [String] = []
                for r in plan.roots.prefix(8) {
                    let name = (r.path as NSString).lastPathComponent
                    if r.isDirectory { let inside = plan.files.filter { $0.hasPrefix(r.path + "/") }.count, subs = plan.folders.filter { $0.hasPrefix(r.path + "/") }.count; lines.append("• \(name)/  (folder: \(inside) file\(inside == 1 ? "" : "s"), \(subs) folder\(subs == 1 ? "" : "s") inside)") }
                    else { lines.append("• \(name)") }
                }
                if plan.roots.count > 8 { lines.append("…and \(plan.roots.count - 8) more") }
                let text = "From \(self.serverName(c)), in \(here):\n" + lines.joined(separator: "\n") + "\n\nThis removes \(plan.count) item\(plan.count == 1 ? "" : "s") on the server and cannot be undone."
                let answer = await Dialogs.choose(title: plan.roots.count == 1 ? "Delete “\((plan.roots[0].path as NSString).lastPathComponent)” from the server?" : "Delete \(plan.roots.count) items from the server?", message: text, buttons: ["Cancel", "Delete"])
                guard answer == 1, !Task.isCancelled else { self.message = "Nothing was deleted."; return }
                self.operation = Operation(title: "Deleting", done: 0, total: plan.count, current: "")
                var done = 0
                // A WebDAV server removes a folder with what is in it in one request; the others are emptied first.
                let steps: [(String, Bool)] = c.scheme.isWebDAV ? plan.roots.map { ($0.path, $0.isDirectory) } : plan.files.map { ($0, false) } + plan.folders.map { ($0, true) }
                do {
                    for (p, isDir) in steps {
                        try Task.checkCancellation()
                        self.operation?.current = (p as NSString).lastPathComponent
                        try await session.remove(p, isDirectory: isDir)
                        done += c.scheme.isWebDAV ? 1 : 1; self.operation?.done = min(done, plan.count)
                    }
                    self.message = "Deleted \(plan.count) item\(plan.count == 1 ? "" : "s")."
                } catch is CancellationError { self.message = "Stopped after \(done) of \(steps.count)." }
                catch { self.message = "Stopped after \(done) of \(steps.count): \((error as? RemoteError)?.errorDescription ?? error.localizedDescription)" }
                self.operation = nil
                self.reload(keepingMessage: true)
            } catch is CancellationError { self.message = nil; self.operation = nil }
            catch { self.message = (error as? RemoteError)?.errorDescription ?? "That could not be checked."; self.operation = nil }
        }
    }

    /// Uploads the chosen files into the folder that is open. The names and sizes are shown with the server and folder first (default button Cancel). A file already there under the same name is kept and skipped:
    /// nothing is ever replaced. Folders are not uploaded; only files.
    func requestUpload(_ urls: [URL]) {
        guard canChange else { message = isPrivate ? "A server cannot be changed from a private tab." : nil; return }
        guard let session, let c = connection else { return }
        let files = urls.filter { u in (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && RemoteNames.isSafeComponent(u.lastPathComponent) }
        guard !files.isEmpty else { message = "Choose files (folders are not uploaded, and a name must be plain)."; return }
        let here = path
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard let self else { return }
            let size = { (u: URL) -> Int64 in ((try? u.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0 }
            let lines = files.prefix(8).map { "• \($0.lastPathComponent)  (\(ByteCountFormatter.string(fromByteCount: size($0), countStyle: .file)))" } + (files.count > 8 ? ["…and \(files.count - 8) more"] : [])
            let total = files.reduce(Int64(0)) { $0 + size($1) }
            let text = "To \(self.serverName(c)), in \(here):\n" + lines.joined(separator: "\n") + "\n\n\(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) will be sent. A file with the same name that is already there is kept, and not replaced."
            let answer = await Dialogs.choose(title: files.count == 1 ? "Upload “\(files[0].lastPathComponent)” to the server?" : "Upload \(files.count) files to the server?", message: text, buttons: ["Cancel", "Upload"])
            guard answer == 1, !Task.isCancelled else { self.message = "Nothing was uploaded."; return }
            self.operation = Operation(title: "Uploading", done: 0, total: files.count, current: "")
            var sent = 0, skipped = 0, failure: String?
            for u in files {
                if Task.isCancelled { break }
                self.operation?.current = u.lastPathComponent
                guard let remote = RemoteNames.join(here, u.lastPathComponent) else { continue }
                do { try await session.upload(u, to: remote) { _ in }; sent += 1 }
                catch RemoteError.alreadyExists { skipped += 1 }
                catch is CancellationError { break }
                catch { failure = "\(u.lastPathComponent): \((error as? RemoteError)?.errorDescription ?? error.localizedDescription)"; break }
                self.operation?.done = sent + skipped
            }
            var parts = ["Uploaded \(sent) of \(files.count)"]
            if skipped > 0 { parts.append("\(skipped) kept as they were (already there)") }
            if let failure { parts.append("stopped at \(failure)") } else if Task.isCancelled { parts.append("stopped") }
            self.message = parts.joined(separator: ", ") + "."
            self.operation = nil
            self.reload(keepingMessage: true)
        }
    }

    // MARK: Downloading

    /// The chosen files and folders become a collection of ordinary tasks. Folders are read below (bounded) and keep their structure under the collection's folder.
    func downloadSelection() {
        guard let session, let c = connection, !selectedEntries.isEmpty else { return }
        let chosen = selectedEntries, here = path
        message = "Reading the folders…"
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if c.scheme.isWebDAV { await self.downloadWebDAV(chosen, session: session, connection: c, base: here); return }
                let plan = try await RemoteFolderPlanner.plan(session: session, roots: chosen, base: here, limits: .default)
                guard !plan.files.isEmpty else { self.message = plan.skipped.isEmpty ? "There is nothing to download in that selection." : "Nothing could be read: \(plan.skipped.first!.why)."; return }
                let title = chosen.count == 1 ? chosen[0].name : (here == "/" ? c.name : (here as NSString).lastPathComponent)
                let out = await RemoteCollection.download(plan, from: c, base: here, title: title, isPrivate: self.isPrivate, coordinator: self.coordinator)
                self.report(out, plan: plan)
            } catch is CancellationError {} catch { self.message = (error as? RemoteError)?.errorDescription ?? "That could not be started." }
        }
    }

    private func report(_ out: RemoteCollection.Outcome, plan: RemotePlan) {
        var parts: [String] = []
        if out.started > 0 { parts.append("Started \(out.started) file\(out.started == 1 ? "" : "s")") }
        if out.alreadyThere > 0 { parts.append("\(out.alreadyThere) already downloaded") }
        if out.failedToStart > 0 { parts.append("\(out.failedToStart) could not be started") }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) skipped") }
        if plan.truncated { parts.append("the folder is larger than this lists") }
        message = parts.isEmpty ? "Nothing to download." : parts.joined(separator: ", ") + "."
        selection = []
    }

    private func downloadWebDAV(_ chosen: [RemoteEntry], session: RemoteSession, connection c: RemoteConnection, base: String) async {
        guard let dav = session as? WebDAVSession else { return }
        // A WebDAV file is an ordinary web file: the HTTP engine downloads it (resume, naming, history), signed in by a website account when the server needs one (https only).
        if c.auth == .password, c.scheme == .webdavs, let user = c.user, let secret = coordinator.remotes.secret(for: c.id), !isPrivate, let accounts = coordinator.accountStore {
            // One website account per server (it signs every download from that host and port in); its id is kept with the saved server so Forget removes it.
            if c.davAccountID == nil, case .ok(let accountID) = accounts.add(name: c.name, host: c.host, port: c.port == 443 ? nil : c.port, method: .httpBasic, username: user, secret: secret) {
                var updated = c; updated.davAccountID = accountID
                _ = coordinator.remotes.save(updated, secret: nil); connection = updated
            }
        }
        do {
            let plan = try await RemoteFolderPlanner.plan(session: session, roots: chosen, base: base, limits: .default)
            guard !plan.files.isEmpty else { message = "There is nothing to download in that selection."; return }
            let title = chosen.count == 1 ? chosen[0].name : c.name
            let source = RemoteCollection.source(for: c, base: base)
            let package = isPrivate ? nil : (coordinator.packages.package(withSource: source) ?? coordinator.packages.create(name: PackageStore.cleanName(title), members: [], source: source)?.package)
            var started = 0, there = 0
            for f in plan.files {
                let key = f.path + "#0"
                if !isPrivate, coordinator.packages.isCollected(key, source: source) { there += 1; continue }
                let url = dav.url(for: f.path)
                guard let id = coordinator.scheduleDownload(url: url, at: Date(), filename: f.name, origin: .user, isPrivate: isPrivate) else { continue }
                started += 1
                if let package {
                    let folder = ([PackageFolderTemplate.clean(PackageStore.cleanName(title))].compactMap { $0 } + f.subfolders).joined(separator: "/")
                    coordinator.packages.add([id], to: package.id); coordinator.packages.recordIdentity(key, task: id, in: package.id)
                    coordinator.ledger.update(id) { $0.engineMetadata["packageFolder"] = folder }          // after the collection set its own
                }
            }
            if let package, started > 0 { coordinator.packages.noteChosen(started, in: package.id) }
            message = (started > 0 ? "Started \(started) file\(started == 1 ? "" : "s")" : "Nothing new") + (there > 0 ? ", \(there) already downloaded" : "") + (plan.skipped.isEmpty ? "" : ", \(plan.skipped.count) skipped") + "."
            selection = []
        } catch is CancellationError {} catch { message = (error as? RemoteError)?.errorDescription ?? "That could not be started." }
    }
}
