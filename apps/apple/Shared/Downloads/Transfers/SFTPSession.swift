import Foundation

// SFTP over the system's own OpenSSH client. `ssh -s <host> sftp` carries the connection (key exchange, host-key checking, password / key / agent authentication, keep-alive); this file speaks the
// SFTP protocol on its standard input and output. No third-party code is shipped, and every OpenSSH feature that matters for trust is the reference implementation's.
//
// What it will not do: it never turns host-key checking off, never reads the person's ~/.ssh/config or known_hosts (so a stray setting cannot weaken it), never forwards anything, and the
// password goes to ssh through a private temporary file (mode 0600, in a folder only this user can open) that is removed as soon as the connection is up.

struct SFTPConfig: Sendable {
    var host: String
    var port: Int = 22
    var user: String
    /// A private key file the person chose. Without one, ssh offers the agent's keys.
    var identityFile: String?
    /// The password, or the passphrase of the key. Never logged, never stored by this type beyond a connection attempt.
    var secret: String?
    var useAgent = true
    var knownHosts: URL
    var connectTimeout = 15
    /// The profile's proxy, if it has one: the connection to the server goes through it (see ProxyRelay).
    var proxy: RemoteProxy?
}

#if os(macOS)
final class SFTPSession: RemoteSession, @unchecked Sendable {
    struct Packet { var kind: UInt8; var id: UInt32; var body: Data }

    private let config: SFTPConfig
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [UInt32: CheckedContinuation<Packet, Error>] = [:]
    private var nextID: UInt32 = 1
    private var closed = false
    private var stderrText = Data()
    private var helperDir: URL?
    private var relay: ProxyRelay?
    private var versionWaiter: CheckedContinuation<Void, Error>?
    private var gotVersion = false
    private var failure: RemoteError?
    private(set) var serverVersion: UInt32 = 0

    init(config: SFTPConfig) { self.config = config }
    deinit { close() }

    // MARK: Connecting

    static func validate(_ c: SFTPConfig) throws {
        guard c.host.range(of: #"^[A-Za-z0-9.\-:_\[\]%]+$"#, options: .regularExpression) != nil, !c.host.hasPrefix("-") else { throw RemoteError.invalidAddress("That server name is not usable.") }
        guard (1...65535).contains(c.port) else { throw RemoteError.invalidAddress("That port is not usable.") }
        guard c.user.range(of: #"^[A-Za-z0-9._@\-+]+$"#, options: .regularExpression) != nil, !c.user.hasPrefix("-") else { throw RemoteError.invalidAddress("That user name is not usable for SFTP.") }
        if let k = c.identityFile, !FileManager.default.isReadableFile(atPath: k) { throw RemoteError.invalidAddress("The key file cannot be read.") }
    }

    func connect() async throws {
        // Whatever was set up before a failure (the proxy relay, the private helper folder with the askpass script) is removed again here, not left until close().
        do { try await establish() } catch {
            removeHelper()
            lock.lock(); let r = relay; relay = nil; lock.unlock()
            r?.stop()
            throw error
        }
    }

    private func establish() async throws {
        try Self.validate(config)
        var env: [String: String] = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory()]
        // Through a proxy: ssh connects to a loopback relay, and checks the server's key against the keys trusted for the REAL server (copied, for this session only, under the relay's address).
        var connectHost = config.host, connectPort = config.port, knownHostsPath = config.knownHosts.path
        if let proxy = config.proxy {
            let r = try ProxyRelay(target: config.host, port: config.port, proxy: proxy)
            let relayPort = try await r.start()
            lock.lock(); relay = r; lock.unlock()
            connectHost = "127.0.0.1"; connectPort = Int(relayPort)
            let trusted = SSHHostKeyStore(file: config.knownHosts).trusted(host: config.host, port: config.port)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bsetu-ssh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            lock.lock(); helperDir = dir; lock.unlock()
            let file = dir.appendingPathComponent("known_hosts")
            try Data(trusted.map { "[127.0.0.1]:\(relayPort) \($0.type) \($0.key)\n" }.joined().utf8).write(to: file)
            knownHostsPath = file.path
        }
        var args = ["-F", "/dev/null",
                    "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"\(knownHostsPath)\"", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "UpdateHostKeys=no", "-o", "VerifyHostKeyDNS=no",
                    "-o", "ConnectTimeout=\(config.connectTimeout)", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                    "-o", "NumberOfPasswordPrompts=1", "-o", "PreferredAuthentications=publickey,password,keyboard-interactive",
                    "-o", "ClearAllForwardings=yes", "-o", "ProxyCommand=none", "-o", "PermitLocalCommand=no", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "LogLevel=ERROR", "-o", "Compression=no",
                    "-p", String(connectPort), "-l", config.user]
        if let key = config.identityFile { args += ["-i", key, "-o", "IdentitiesOnly=yes"] }
        // A password (or no credential at all) never offers the person's own keys to the server: public-key sign-in is off unless a key file or the agent was chosen.
        else if !config.useAgent { args += ["-o", "PubkeyAuthentication=no"] }
        if config.useAgent, let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], config.identityFile == nil { env["SSH_AUTH_SOCK"] = sock } else { args += ["-o", "IdentityAgent=none"] }
        if let secret = config.secret, !secret.isEmpty { env.merge(try prepareAskpass(secret)) { $1 } }
        args += ["-s", "--", connectHost, "sftp"]

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh"); p.arguments = args; p.environment = env
        let toServer = Pipe(), fromServer = Pipe(), errors = Pipe()
        p.standardInput = toServer; p.standardOutput = fromServer; p.standardError = errors
        _ = fcntl(toServer.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        p.terminationHandler = { [weak self] _ in self?.processEnded() }
        do { try p.run() } catch { removeHelper(); throw RemoteError.unsupported("The system's ssh could not be started.") }
        // The ends of the pipes that belong to the child are closed in this process (otherwise every session leaks descriptors).
        try? toServer.fileHandleForReading.close(); try? fromServer.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        lock.lock(); process = p; input = toServer.fileHandleForWriting; lock.unlock()
        let out = fromServer.fileHandleForReading, err = errors.fileHandleForReading
        Thread.detachNewThread { [weak self] in self?.readLoop(out) }
        Thread.detachNewThread { [weak self] in
            while true { let d = err.availableData; if d.isEmpty { break }; self?.lock.lock(); if (self?.stderrText.count ?? 0) < 16_384 { self?.stderrText.append(d) }; self?.lock.unlock() }
        }
        try send(SFTPWire.Writer.packet(.initialize) { $0.u32(3) })
        // A cancelled connect (the person pressed Disconnect, or chose another server) ends the ssh process at once; nothing is left running or on disk.
        do { try await withTaskCancellationHandler { try await waitForVersion(timeout: TimeInterval(config.connectTimeout + 10)) } onCancel: { [self] in abort() } }
        catch { removeHelper(); close(); throw (Task.isCancelled ? CancellationError() : error) }          // a failed login leaves nothing behind either
        removeHelper()          // the secret has done its job
    }

    private func prepareAskpass(_ secret: String) throws -> [String: String] {
        lock.lock(); let existing = helperDir; lock.unlock()
        let dir = existing ?? FileManager.default.temporaryDirectory.appendingPathComponent("bsetu-ssh-\(UUID().uuidString)", isDirectory: true)
        if existing == nil { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        lock.lock(); helperDir = dir; lock.unlock()          // (registered at once: if anything below fails, the folder is still removed)
        let secretFile = dir.appendingPathComponent("s"), script = dir.appendingPathComponent("askpass")
        guard FileManager.default.createFile(atPath: secretFile.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else { throw RemoteError.failed("A temporary file for the password could not be made.") }
        // Answers only password / passphrase prompts; anything else (a host-key question) is refused.
        let text = "#!/bin/sh\ncase \"$1\" in\n  *assword*|*assphrase*) /bin/cat \"$BSETU_SECRET_FILE\" ;;\n  *) exit 1 ;;\nesac\n"
        guard FileManager.default.createFile(atPath: script.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o700]) else { throw RemoteError.failed("A temporary helper could not be made.") }
        lock.lock(); helperDir = dir; lock.unlock()
        return ["SSH_ASKPASS": script.path, "SSH_ASKPASS_REQUIRE": "force", "BSETU_SECRET_FILE": secretFile.path, "DISPLAY": ":0"]
    }

    private func removeHelper() {
        lock.lock(); let d = helperDir; helperDir = nil; lock.unlock()
        if let d { try? FileManager.default.removeItem(at: d) }
    }

    private func waitForVersion(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if gotVersion { lock.unlock(); c.resume(); return }
                    if let f = failure { lock.unlock(); c.resume(throwing: f); return }
                    versionWaiter = c; lock.unlock()
                }
            }
            group.addTask { [self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                abort(); throw RemoteError.timedOut
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    // MARK: Reading what the server sends

    /// Reads what the server sends with plain `read` into one reusable buffer (no per-chunk Foundation objects, which a long transfer would pile up) and cuts it into frames. Each frame is copied out once.
    private func readLoop(_ h: FileHandle) {
        let fd = h.fileDescriptor
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 65_536); defer { chunk.deallocate() }
        var buffer = [UInt8](); buffer.reserveCapacity(1 << 17)
        while true {
            let n = read(fd, chunk, 65_536)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            buffer.append(contentsOf: UnsafeBufferPointer(start: chunk, count: n))
            var offset = 0
            while buffer.count - offset >= 4 {
                let len = (Int(buffer[offset]) << 24) | (Int(buffer[offset + 1]) << 16) | (Int(buffer[offset + 2]) << 8) | Int(buffer[offset + 3])
                if len > SFTPWire.maxPacket || len < 1 { fail(.protocolViolation("a packet of \(len) bytes")); abort(); return }
                guard buffer.count - offset >= 4 + len else { break }
                handle(Data(buffer[(offset + 4) ..< (offset + 4 + len)]))
                offset += 4 + len
            }
            if offset > 0 { buffer.removeFirst(offset) }
        }
    }

    private func handle(_ body: Data) {
        var r = SFTPWire.Reader(body)
        guard let kind = try? r.u8() else { return }
        if kind == SFTPWire.Kind.version.rawValue {
            lock.lock(); serverVersion = (try? r.u32()) ?? 0; lock.unlock()
            if serverVersion < 3 { fail(.unsupported("The server speaks an SFTP version this app does not.")); return }          // (this also ends the wait for the version)
            lock.lock(); gotVersion = true; let w = versionWaiter; versionWaiter = nil; lock.unlock()
            w?.resume(); return
        }
        guard let id = try? r.u32() else { return }
        let rest = body[r.pos...]          // (a view of the same bytes, not a copy)
        lock.lock(); let c = pending.removeValue(forKey: id); lock.unlock()
        c?.resume(returning: Packet(kind: kind, id: id, body: rest))
    }

    private func processEnded() {
        // The error text is still being read when the process ends: give the reader a moment so the reason is not lost.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let text = String(decoding: self.stderrText, as: UTF8.self); let status = self.process?.terminationStatus ?? 0
            self.process?.terminationHandler = nil; self.process = nil          // (the Process object holds the pipes: letting it go closes them)
            self.lock.unlock()
            self.fail(Self.mapSSHError(text, status: status))
        }
    }

    static func mapSSHError(_ text: String, status: Int32) -> RemoteError {
        let t = text.lowercased()
        if t.contains("permission denied") || t.contains("authentication failed") || t.contains("too many authentication failures") { return .authenticationFailed }
        if t.contains("host key verification failed") || t.contains("host identification has changed") || t.contains("no matching host key") { return .failed("The server's key does not match the one you trusted, so the connection was refused.") }
        if t.contains("subsystem request failed") { return .unsupported("This server does not offer SFTP.") }
        if t.contains("timed out") || t.contains("timeout") { return .timedOut }
        if t.contains("connection refused") || t.contains("no route to host") || t.contains("could not resolve") || t.contains("network is unreachable") || t.contains("name or service not known") { return .unreachable(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "") }
        if t.contains("connection closed") || t.contains("connection reset") || t.contains("broken pipe") { return .connectionLost("") }
        return status == 0 ? .connectionLost("") : .connectionLost(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
    }

    private func fail(_ e: RemoteError) {
        lock.lock()
        if failure == nil { failure = e }
        let all = pending; pending = [:]; let w = versionWaiter; versionWaiter = nil; let f = failure!
        lock.unlock()
        for (_, c) in all { c.resume(throwing: f) }
        w?.resume(throwing: f)
    }

    // MARK: Requests

    private func send(_ data: Data) throws {
        lock.lock(); let h = input; let isClosed = closed; let f = failure; lock.unlock()
        if let f { throw f }
        guard let h, !isClosed else { throw RemoteError.connectionLost("") }
        // One packet at a time: a write larger than the pipe's atomic size can be interleaved with another thread's, which corrupts the stream.
        sendLock.lock(); defer { sendLock.unlock() }
        do { try h.write(contentsOf: data) } catch { throw RemoteError.connectionLost("") }
    }
    private let sendLock = NSLock()

    private func call(_ kind: SFTPWire.Kind, _ build: (inout SFTPWire.Writer) -> Void) async throws -> Packet {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Packet, Error>) in
            lock.lock()
            if let f = failure { lock.unlock(); c.resume(throwing: f); return }
            let id = nextID; nextID &+= 1
            pending[id] = c
            lock.unlock()
            let packet = SFTPWire.Writer.packet(kind) { w in w.u32(id); build(&w) }
            do { try send(packet) } catch {
                lock.lock(); let still = pending.removeValue(forKey: id); lock.unlock()
                still?.resume(throwing: error)
            }
        }
    }

    private func checked(_ p: Packet, expecting kind: SFTPWire.Kind) throws -> SFTPWire.Reader {
        var r = SFTPWire.Reader(p.body)
        if p.kind == kind.rawValue { return r }
        if p.kind == SFTPWire.Kind.status.rawValue {
            let code = (try? r.u32()) ?? 4, message = (try? r.string()) ?? ""
            throw Self.statusError(code, message)
        }
        throw RemoteError.protocolViolation("an unexpected answer (\(p.kind))")
    }

    static func statusError(_ code: UInt32, _ message: String) -> RemoteError {
        switch SFTPWire.Status(rawValue: code) {
        case .noSuchFile: .notFound
        case .permissionDenied: .permissionDenied
        case .opUnsupported: .unsupported("The server does not support that.")
        case .noConnection, .connectionLost: .connectionLost(message)
        default: .failed(message.isEmpty ? "The server reported an error." : String(message.prefix(200)))
        }
    }

    private func isEOF(_ p: Packet) -> Bool {
        guard p.kind == SFTPWire.Kind.status.rawValue else { return false }
        var r = SFTPWire.Reader(p.body); return (try? r.u32()) == SFTPWire.Status.eof.rawValue
    }

    // MARK: Operations

    func canonical(_ path: String) async throws -> String {
        var r = try checked(try await call(.realpath) { $0.string(path) }, expecting: .name)
        guard let first = try SFTPWire.names(&r).first else { throw RemoteError.protocolViolation("no path") }
        return first.name
    }

    struct FileInfo: Equatable { var size: UInt64?; var mtime: Date?; var kind: RemoteEntry.Kind }

    func info(_ path: String, followLinks: Bool = true) async throws -> FileInfo {
        var r = try checked(try await call(followLinks ? .stat : .lstat) { $0.string(path) }, expecting: .attrs)
        let a = try SFTPWire.attrs(&r)
        return FileInfo(size: a.size, mtime: a.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }, kind: a.kind)
    }

    private func openHandle(_ kind: SFTPWire.Kind, _ path: String, flags: UInt32 = 0) async throws -> Data {
        var r = try checked(try await call(kind) { w in w.string(path); if kind == .open { w.u32(flags); w.u32(0) } }, expecting: .handle)
        return try r.stringData()
    }

    private func closeHandle(_ h: Data) { Task { _ = try? await call(.close) { $0.string(h) } } }

    func list(_ path: String, limit: Int = 100_000, onBatch: @Sendable ([RemoteEntry]) -> Void) async throws -> (count: Int, truncated: Bool) {
        let h = try await openHandle(.opendir, path)
        defer { closeHandle(h) }
        var count = 0, reads = 0
        while true {
            try Task.checkCancellation()
            reads += 1
            if reads > 100_000 { throw RemoteError.protocolViolation("a folder listing that never ends") }
            let p = try await call(.readdir) { $0.string(h) }
            if isEOF(p) { return (count, false) }
            var r = try checked(p, expecting: .name)
            let names = try SFTPWire.names(&r)
            var batch: [RemoteEntry] = []
            for n in names where n.name != "." && n.name != ".." && RemoteNames.isSafeComponent(n.name) {
                var kind = n.attrs.kind, size = n.attrs.size.map { Int64(clamping: $0) }, mtime = n.attrs.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }, broken = false
                let isLink = kind == .symlink
                if kind == .symlink, let full = RemoteNames.join(path, n.name) {
                    // A link is described by what it points at; one that points nowhere (or at what this account may not see) is shown, but cannot be chosen.
                    if let target = try? await info(full) { kind = target.kind == .symlink ? .other : target.kind; size = target.size.map { Int64(clamping: $0) }; mtime = target.mtime ?? mtime } else { broken = true }
                }
                batch.append(RemoteEntry(name: n.name, kind: kind, size: size, modified: mtime, isBroken: broken, isLink: isLink))
            }
            count += batch.count
            if !batch.isEmpty { onBatch(batch) }
            if count >= limit { return (count, true) }
        }
    }

    /// Reads `path` from `start` into the open file `fd` (written at the same offsets), several requests in flight at once. Returns the bytes now in place from the start.
    /// `size` is what the server said the file holds; the read ends there (or at the server's end-of-file, if sooner).
    func download(_ path: String, into fd: Int32, from start: UInt64, size: UInt64?, rateLimit: (@Sendable () -> Int64?)? = nil, onProgress: @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let handle = try await openHandle(.open, path, flags: 0x1)          // SSH_FXF_READ
        defer { closeHandle(handle) }
        let chunk = 32_768, window = 64
        var next = start
        var end = size
        var ranges = SFTPWire.Ranges()
        ranges.insert(0, count: Int(start))
        var retries: [(UInt64, Int)] = []
        let began = Date(); var received: Int64 = 0
        struct Result { var offset: UInt64; var asked: Int; var data: Data? }

        do {
            try await withThrowingTaskGroup(of: Result.self) { group in
                var inflight = 0
                func schedule() {
                    while inflight < window, !Task.isCancelled {
                        let offset: UInt64, len: Int
                        if let r = retries.popLast() { (offset, len) = r }
                        else if let e = end, next >= e { break }
                        else { offset = next; len = end.map { Int(min(UInt64(chunk), $0 - next)) } ?? chunk; next += UInt64(len) }
                        inflight += 1
                        group.addTask { [self] in
                            let p = try await call(.read) { $0.string(handle); $0.u64(offset); $0.u32(UInt32(len)) }
                            if isEOF(p) { return Result(offset: offset, asked: len, data: nil) }
                            var r = try checked(p, expecting: .data)
                            return Result(offset: offset, asked: len, data: try r.stringData())
                        }
                    }
                }
                schedule()
                while inflight > 0 {
                    guard let r = try await group.next() else { break }
                    inflight -= 1
                    if let d = r.data {
                        guard !d.isEmpty else { throw RemoteError.protocolViolation("an empty read") }
                        guard d.count <= r.asked else { throw RemoteError.protocolViolation("more data than asked for") }
                        let written = d.withUnsafeBytes { pwrite(fd, $0.baseAddress, d.count, off_t(r.offset)) }
                        if written != d.count { throw errno == ENOSPC || errno == EDQUOT ? RemoteError.diskFull : RemoteError.failed("The file could not be written (\(String(cString: strerror(errno)))).") }
                        ranges.insert(r.offset, count: d.count)
                        received += Int64(d.count)
                        onProgress(ranges.total)
                        // A speed limit (the profile's, read again each time so a change takes effect at once): wait until the bytes received so far fit within it.
                        if let limit = rateLimit?(), limit > 0 { let due = Double(received) / Double(limit) - Date().timeIntervalSince(began); if due > 0.01 { try await Task.sleep(nanoseconds: UInt64(min(due, 2) * 1_000_000_000)) } }
                        if d.count < r.asked { retries.append((r.offset + UInt64(d.count), r.asked - d.count)) }
                    } else { end = min(end ?? r.offset, r.offset) }
                    schedule()
                }
            }
            try Task.checkCancellation()
            let have = ranges.contiguousPrefix
            if let end, have < end { throw RemoteError.connectionLost("the file ended early") }
        return have
        } catch {
            // Whatever stopped this (a pause, a lost connection): bytes beyond the first gap are not trusted. The file is cut back to the contiguous prefix, so the next try starts there and never over zero-filled holes.
            ftruncate(fd, off_t(ranges.contiguousPrefix))
            throw error
        }
    }

    // MARK: Changing the server (only what the person chose; see RemoteBrowserModel)

    private func expectOK(_ p: Packet) throws {
        var r = SFTPWire.Reader(p.body)
        guard p.kind == SFTPWire.Kind.status.rawValue else { throw RemoteError.protocolViolation("an unexpected answer (\(p.kind))") }
        let code = (try? r.u32()) ?? 4, message = (try? r.string()) ?? ""
        if code != SFTPWire.Status.ok.rawValue { throw Self.statusError(code, message) }
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        try expectOK(try await call(isDirectory ? .rmdir : .remove) { $0.string(path) })
    }

    /// Writes `local` to a hidden name beside `path` (created exclusively), checks its size, and renames it into place. A rename never replaces an existing file (the SFTP rule), so a file that is already
    /// there is kept and nothing is uploaded. If anything goes wrong or the upload is cancelled, the hidden file is removed.
    func upload(_ local: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path), let total = (attrs[.size] as? NSNumber)?.int64Value, (attrs[.type] as? FileAttributeType) == .typeRegular else { throw RemoteError.failed("That is not a file this app can upload.") }
        if (try? await info(path, followLinks: false)) != nil { throw RemoteError.alreadyExists }
        guard let temp = RemoteNames.join(RemoteNames.parent(of: path), ".\((path as NSString).lastPathComponent).bsetu-\(UUID().uuidString.prefix(8))") else { throw RemoteError.invalidAddress("That name cannot be used on the server.") }
        let handle: Data
        do { var r = try checked(try await call(.open) { $0.string(temp); $0.u32(0x2 | 0x8 | 0x20); $0.u32(0) }, expecting: .handle); handle = try r.stringData() }
        catch { throw error }
        var finished = false
        defer { if !finished { Task { [self] in _ = try? await call(.close) { $0.string(handle) }; _ = try? await call(.remove) { $0.string(temp) } } } }
        let fd = open(local.path, O_RDONLY)
        guard fd >= 0 else { throw RemoteError.failed("The file could not be read.") }
        defer { Darwin.close(fd) }
        let chunk = 32_768, window = 32
        var offset: Int64 = 0, sent: Int64 = 0
        try await withThrowingTaskGroup(of: Int.self) { group in
            var inflight = 0
            func more() throws {
                while inflight < window, offset < total, !Task.isCancelled {
                    var buf = Data(count: Int(min(Int64(chunk), total - offset)))
                    let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(offset)) }
                    guard n > 0 else { throw RemoteError.failed("The file could not be read (it changed while it was being uploaded?).") }
                    if n < buf.count { buf = buf.prefix(n) }
                    let at = UInt64(offset), data = buf
                    offset += Int64(n); inflight += 1
                    group.addTask { [self] in try expectOK(try await call(.write) { $0.string(handle); $0.u64(at); $0.string(data) }); return data.count }
                }
            }
            try more()
            while inflight > 0 {
                guard let n = try await group.next() else { break }
                inflight -= 1; sent += Int64(n); progress(sent)
                try more()
            }
        }
        try Task.checkCancellation()
        try expectOK(try await call(.close) { $0.string(handle) })
        let written = try await info(temp, followLinks: false)
        guard written.size == UInt64(total) else { throw RemoteError.failed("The server holds \(written.size.map(String.init) ?? "?") bytes, not \(total): the upload was not kept.") }
        do { try expectOK(try await call(.rename) { $0.string(temp); $0.string(path) }) }
        catch let e as RemoteError { if case .failed = e, (try? await info(path, followLinks: false)) != nil { throw RemoteError.alreadyExists }; throw e }
        finished = true
    }

    // MARK: Ending

    /// Stops everything now (a cancelled transfer must not wait for the network).
    func abort() {
        lock.lock(); let p = process; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true; let p = process; let h = input; input = nil; lock.unlock()
        try? h?.close()
        relay?.stop()
        if let p, p.isRunning { p.terminate() }          // (processEnded then releases it)
        fail(.connectionLost(""))
        removeHelper()
    }
}
#endif

#if !os(macOS)
/// See `FTPSession` for iPhone: the Mac's SFTP client is a helper program the iPhone cannot start.
final class SFTPSession: RemoteSession, @unchecked Sendable {
    struct FileInfo: Equatable { var size: UInt64?; var mtime: Date?; var kind: RemoteEntry.Kind }
    private static let unavailable = RemoteError.unsupported("SFTP servers are not available on iPhone.")
    init(config: SFTPConfig) {}
    func connect() async throws { throw Self.unavailable }
    func list(_ path: String, limit: Int, onBatch: @Sendable ([RemoteEntry]) -> Void) async throws -> (count: Int, truncated: Bool) { throw Self.unavailable }
    func canonical(_ path: String) async throws -> String { throw Self.unavailable }
    func info(_ path: String, followLinks: Bool = true) async throws -> FileInfo { throw Self.unavailable }
    func download(_ path: String, into fd: Int32, from start: UInt64, size: UInt64?, rateLimit: (@Sendable () -> Int64?)? = nil, onProgress: @Sendable (UInt64) -> Void) async throws -> UInt64 { throw Self.unavailable }
    func abort() {}
    func close() {}
}
#endif
