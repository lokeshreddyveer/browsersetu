import CryptoKit
import Foundation

// FTP and FTPS through the system's own `curl` (the same libcurl Apple ships and updates). The password never appears in the command line (where `ps` shows it): it goes in on standard input
// as a curl config. FTP and TLS details curl already handles well (passive/extended passive, the TLS upgrade of explicit FTPS, REST, certificate checking) are left to it; this file only builds
// the request, reads the answer and turns curl's exit status into something a person can act on.
//
// Choices that matter for safety: the address in a server's PASV answer is ignored (the data connection goes to the host that was asked for, never to an address a server names), no proxy
// is taken from the environment, certificates are checked with the system's trust (a server's own certificate is only trusted if the person looked at it and saved it), and a plain `ftp://`
// connection is labelled as unencrypted in the interface.

struct FTPConfig: Sendable {
    var host: String
    var port: Int = 21
    /// nil: anonymous.
    var user: String?
    var password: String?
    /// AUTH TLS on a normal connection (what "FTPS" usually means, port 21).
    var explicitTLS = false
    /// TLS from the first byte (port 990).
    var implicitTLS = false
    /// A certificate (PEM) the person looked at and chose to trust for this server. Hostname checking still applies.
    var trustedCertificate: URL?
    var rateLimit: Int?
    var connectTimeout = 15
    /// The profile's proxy: FTP can go through a SOCKS 5 proxy (curl carries the data connection through it too); an HTTP proxy cannot carry FTP.
    var proxy: RemoteProxy?
}

#if os(macOS)
final class FTPSession: RemoteSession, @unchecked Sendable {
    private let config: FTPConfig
    private let lock = NSLock()
    private var running: [Process] = []
    private var closed = false

    init(config: FTPConfig) { self.config = config }
    deinit { close() }

    static func validate(_ c: FTPConfig) throws {
        if let p = c.proxy, p.kind == .httpConnect { throw RemoteError.unsupported("FTP cannot go through an HTTP proxy. Use a SOCKS 5 proxy in Settings, or connect directly.") }
        guard c.host.range(of: #"^[A-Za-z0-9.\-:_\[\]%]+$"#, options: .regularExpression) != nil, !c.host.hasPrefix("-") else { throw RemoteError.invalidAddress("That server name is not usable.") }
        guard (1...65535).contains(c.port) else { throw RemoteError.invalidAddress("That port is not usable.") }
        if (c.user ?? "").contains(":") { throw RemoteError.invalidAddress("A user name cannot contain a colon for FTP.") }
        for s in [c.user, c.password].compactMap({ $0 }) where s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { throw RemoteError.invalidAddress("A user name or password cannot contain control characters.") }
    }

    // MARK: Requests

    /// `ftp://host:port//absolute/path`: the double slash makes the path absolute instead of relative to the login folder.
    func url(for path: String, directory: Bool = false) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? "" }
        let scheme = config.implicitTLS ? "ftps" : "ftp"
        return "\(scheme)://\(config.host):\(config.port)//" + parts.joined(separator: "/") + (directory && !parts.isEmpty ? "/" : "")
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func arguments(extra: [String]) -> [String] {
        var a = ["-q", "-s", "-S"] + (config.proxy == nil ? ["--noproxy", "*"] : []) + ["--connect-timeout", String(config.connectTimeout), "--speed-limit", "1", "--speed-time", "30", "--ftp-skip-pasv-ip", "--tlsv1.2", "-K", "-"]
        if config.explicitTLS && !config.implicitTLS { a += ["--ssl-reqd"] }
        if let cert = config.trustedCertificate { a += ["--cacert", cert.path] }
        if let r = config.rateLimit, r > 0 { a += ["--limit-rate", String(r)] }
        if let p = config.proxy, p.kind == .socks5 { a += ["--socks5-hostname", "\(p.host):\(p.port)"] }
        return a + extra
    }

    private func stdinConfig(url: String) -> Data {
        var text = ""
        text += "user = \(Self.quoted((config.user ?? "anonymous") + ":" + (config.user == nil ? "browsersetu@localhost" : (config.password ?? ""))))\n"
        if let p = config.proxy, p.kind == .socks5, let u = p.username, let pw = p.password { text += "proxy-user = \(Self.quoted(u + ":" + pw))\n" }
        text += "url = \(Self.quoted(url))\n"
        return Data(text.utf8)
    }

    private func register(_ p: Process) -> Bool { lock.lock(); defer { lock.unlock() }; if closed { return false }; running.append(p); return true }
    private func unregister(_ p: Process) { lock.lock(); running.removeAll { $0 === p }; lock.unlock() }

    /// Runs curl to the end. `output` is where a transfer goes (a file) or nil to read standard output (bounded).
    private func run(url: String, extra: [String], capture: Bool = true, maxBytes: Int = 16 << 20) async throws -> (out: Data, err: String, status: Int32) {
        try Self.validate(config)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); p.arguments = arguments(extra: extra)
                p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
                let i = Pipe(), o = Pipe(), e = Pipe(); p.standardInput = i; p.standardOutput = capture ? o : FileHandle.nullDevice; p.standardError = e
                guard register(p) else { cont.resume(throwing: RemoteError.connectionLost("")); return }
                do { try p.run() } catch { unregister(p); cont.resume(throwing: RemoteError.unsupported("The system's curl could not be started.")); return }
                try? i.fileHandleForReading.close(); try? o.fileHandleForWriting.close(); try? e.fileHandleForWriting.close()
                _ = fcntl(i.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? i.fileHandleForWriting.write(contentsOf: stdinConfig(url: url)); try? i.fileHandleForWriting.close()
                var out = Data(), err = Data(), tooBig = false
                let group = DispatchGroup()
                if capture { group.enter(); DispatchQueue.global().async { while true { let d = o.fileHandleForReading.availableData; if d.isEmpty { break }; if out.count + d.count > maxBytes { tooBig = true; p.terminate(); break }; out.append(d) }; group.leave() } }
                group.enter(); DispatchQueue.global().async { while true { let d = e.fileHandleForReading.availableData; if d.isEmpty { break }; if err.count < 8192 { err.append(d) } }; group.leave() }
                p.waitUntilExit(); group.wait(); unregister(p)
                if tooBig { cont.resume(throwing: RemoteError.tooLarge("That folder listing is larger than this app will read.")); return }
                cont.resume(returning: (out, String(decoding: err, as: UTF8.self), p.terminationStatus))
            }
        }
    }

    // MARK: Mapping curl's answer

    static func map(status: Int32, stderr: String) -> RemoteError? {
        if status == 0 { return nil }
        let t = stderr.lowercased()
        switch status {
        case 6, 7: return .unreachable(stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "")
        case 28: return .timedOut
        case 67, 69: return .authenticationFailed
        case 78, 19: return .notFound
        case 9: return t.contains("not found") || t.contains("no such") ? .notFound : .permissionDenied
        case 31, 33, 36: return .unsupported("resume")
        case 35, 51, 58, 59, 60, 64, 66, 77, 80, 83, 90, 91: return .certificateRejected(stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "the TLS connection failed")
        case 21: return .failed("The server refused that (the file may not exist, or this account may not be allowed to change it).")
        case 25: return .failed("The server did not accept the upload (this account may not be allowed to write there).")
        case 23: return .failed("The file could not be written.")
        case 18, 52, 55, 56: return .connectionLost("")
        case 63: return .tooLarge("The server's file is larger than allowed.")
        case 2, 1, 3: return .invalidAddress("That address is not usable for FTP.")
        default: return .failed("The FTP transfer failed (\(status)).")
        }
    }

    // MARK: Listing

    func canonical(_ path: String) async throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }

    func list(_ path: String, limit: Int = 100_000, onBatch: @Sendable ([RemoteEntry]) -> Void) async throws -> (count: Int, truncated: Bool) {
        var result = try await run(url: url(for: path, directory: true), extra: ["-X", "MLSD"])
        var mlsd = true
        // A server without MLSD answers 500/502 (curl exit 8 or 9 on the command): the older LIST format is read instead.
        if result.status != 0, result.status == 8 || result.status == 9 || result.err.contains("500") || result.err.contains("502") || result.err.lowercased().contains("unknown") {
            let again = try await run(url: url(for: path, directory: true), extra: [])
            if again.status == 0 { result = again; mlsd = false }
        }
        if let e = Self.map(status: result.status, stderr: result.err) { throw e }
        var entries = Self.parseListing(String(decoding: result.out, as: UTF8.self), mlsd: mlsd)
        entries = await resolveLinks(entries, in: path)
        var truncated = false
        if entries.count > limit { entries = Array(entries.prefix(limit)); truncated = true }
        for chunk in stride(from: 0, to: entries.count, by: 500) { onBatch(Array(entries[chunk ..< min(chunk + 500, entries.count)])) }
        return (entries.count, truncated)
    }

    /// A symbolic link in an FTP listing does not say what it points at. Up to a hundred are asked: a link with a size is a file, one that can be listed is a folder, one that is neither is shown as broken.
    private func resolveLinks(_ entries: [RemoteEntry], in folder: String) async -> [RemoteEntry] {
        var out = entries, probed = 0
        for i in out.indices where out[i].kind == .symlink {
            guard probed < 100, let full = RemoteNames.join(folder, out[i].name) else { out[i].isBroken = true; continue }
            probed += 1
            if let info = try? await info(full), let size = info.size { out[i].kind = .file; out[i].size = size; out[i].modified = info.modified ?? out[i].modified; continue }
            var isFolder = (try? await run(url: url(for: full, directory: true), extra: ["-X", "MLSD"]))?.status == 0
            if !isFolder { isFolder = (try? await run(url: url(for: full, directory: true), extra: []))?.status == 0 }
            if isFolder { out[i].kind = .directory; continue }
            out[i].isBroken = true
        }
        return out
    }

    static func parseListing(_ text: String, mlsd: Bool) -> [RemoteEntry] {
        var out: [RemoteEntry] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if mlsd {
                guard let space = line.firstIndex(of: " ") else { continue }
                let facts = line[..<space], name = String(line[line.index(after: space)...])
                var dict: [String: String] = [:]
                for f in facts.split(separator: ";") { if let eq = f.firstIndex(of: "=") { dict[f[..<eq].lowercased()] = String(f[f.index(after: eq)...]) } }
                guard RemoteNames.isSafeComponent(name) else { continue }
                let type = dict["type"]?.lowercased() ?? "file"
                if type == "cdir" || type == "pdir" { continue }
                let kind: RemoteEntry.Kind = type == "dir" ? .directory : (type.hasPrefix("os.unix=slink") ? .symlink : (type == "file" ? .file : .other))
                out.append(RemoteEntry(name: name, kind: kind, size: dict["size"].flatMap { Int64($0) }, modified: dict["modify"].flatMap(parseMLSDTime), isLink: kind == .symlink))
            } else {
                guard let m = unixLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), m.numberOfRanges == 5 else { continue }
                func g(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
                var name = g(4)
                if g(1) == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
                guard RemoteNames.isSafeComponent(name) else { continue }
                let kind: RemoteEntry.Kind = g(1) == "d" ? .directory : (g(1) == "-" ? .file : (g(1) == "l" ? .symlink : .other))
                out.append(RemoteEntry(name: name, kind: kind, size: Int64(g(2)), modified: nil, isLink: kind == .symlink))
            }
        }
        return out
    }

    /// Groups: 1 type, 2 size, 3 date, 4 name.
    private static let unixLine = try! NSRegularExpression(pattern: #"^([-dlbcps])[-rwxsStT]{9}[+@.]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w{3}\s+\d+\s+[\d:]+)\s+(.+)$"#)

    static func parseMLSDTime(_ s: String) -> Date? {
        let base = s.prefix(14)
        guard base.count == 14 else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyyMMddHHmmss"
        return f.date(from: String(base))
    }

    // MARK: Metadata and transfer

    struct FileInfo: Equatable { var size: Int64?; var modified: Date? }

    func info(_ path: String) async throws -> FileInfo {
        let r = try await run(url: url(for: path), extra: ["-I"])
        if let e = Self.map(status: r.status, stderr: r.err) { throw e }
        var size: Int64?, modified: Date?
        for line in String(decoding: r.out, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let l = line.lowercased()
            if l.hasPrefix("content-length:") { size = Int64(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) }
            if l.hasPrefix("last-modified:") {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                modified = f.date(from: String(line.dropFirst(14)).trimmingCharacters(in: .whitespaces))
            }
        }
        return FileInfo(size: size, modified: modified)
    }

    /// Fetches `path` into `file`, from `offset` when the file already holds that many bytes. curl appends when resuming; the caller makes sure the file is exactly `offset` bytes long first.
    /// `onProgress` is called with the file's size about four times a second.
    func download(_ path: String, to file: URL, from offset: Int64, onProgress: @Sendable @escaping (Int64) -> Void) async throws {
        var extra = ["-o", file.path]
        if offset > 0 { extra += ["-C", String(offset)] }
        let watcher = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value { onProgress(size) }
            }
        }
        defer { watcher.cancel() }
        let r = try await withTaskCancellationHandler { try await run(url: url(for: path), extra: extra, capture: false) } onCancel: { [weak self] in self?.terminateAll() }
        try Task.checkCancellation()
        if let e = Self.map(status: r.status, stderr: r.err) { throw e }
    }

    // MARK: Changing the server (only what the person chose; see RemoteBrowserModel)

    private static func commandSafe(_ path: String) throws {
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw RemoteError.invalidAddress("That name cannot be used on the server.") }
    }

    func remove(_ path: String, isDirectory: Bool) async throws {
        try Self.commandSafe(path)
        // DELE / RMD run on the control connection; the listing the request also makes is ignored.
        let r = try await run(url: url(for: RemoteNames.parent(of: path), directory: true), extra: ["-Q", "\(isDirectory ? "RMD" : "DELE") \(path)"])
        if let e = Self.map(status: r.status, stderr: r.err) { throw e }
    }

    /// Sends `local` to a hidden name beside `path`, checks the size the server reports, and renames it into place. A file already at `path` is kept (nothing is sent).
    func upload(_ local: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws {
        try Self.commandSafe(path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: local.path), let total = (attrs[.size] as? NSNumber)?.int64Value, (attrs[.type] as? FileAttributeType) == .typeRegular else { throw RemoteError.failed("That is not a file this app can upload.") }
        if (try? await info(path)) != nil { throw RemoteError.alreadyExists }
        guard let temp = RemoteNames.join(RemoteNames.parent(of: path), ".\((path as NSString).lastPathComponent).bsetu-\(UUID().uuidString.prefix(8))") else { throw RemoteError.invalidAddress("That name cannot be used on the server.") }
        var kept = false
        defer { if !kept { Task { [self] in try? await remove(temp, isDirectory: false) } } }
        let sent = try await withTaskCancellationHandler { try await run(url: url(for: temp), extra: ["-T", local.path]) } onCancel: { [weak self] in self?.terminateAll() }
        try Task.checkCancellation()
        if let e = Self.map(status: sent.status, stderr: sent.err) { throw e }
        guard (try? await info(temp))?.size == total else { throw RemoteError.failed("The server did not keep all of the file, so it was not uploaded.") }
        progress(total)
        let moved = try await run(url: url(for: RemoteNames.parent(of: path), directory: true), extra: ["-Q", "RNFR \(temp)", "-Q", "RNTO \(path)"])
        if let e = Self.map(status: moved.status, stderr: moved.err) { throw e }
        kept = true
    }

    // MARK: Certificates

    /// The certificate an FTPS server presents (for the person to look at before trusting it): PEM text and SHA-256 fingerprint. Reads nothing else from the server.
    static func presentedCertificate(host: String, port: Int, implicit: Bool) async throws -> (pem: String, fingerprint: String) {
        var args = ["s_client", "-connect", "\(host):\(port)", "-servername", host]
        if !implicit { args += ["-starttls", "ftp"] }
        let (out, _, _) = try await SSHProcess.run("/usr/bin/openssl", args, timeout: 12)
        guard let b = out.range(of: "-----BEGIN CERTIFICATE-----"), let e = out.range(of: "-----END CERTIFICATE-----", range: b.upperBound..<out.endIndex) else { throw RemoteError.certificateRejected("the server did not present a certificate") }
        let pem = String(out[b.lowerBound..<e.upperBound]) + "\n"
        let body = out[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: String(body)) else { throw RemoteError.certificateRejected("the certificate could not be read") }
        let hex = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        return (pem, "SHA256:" + hex)
    }

    // MARK: Ending

    private func terminateAll() { lock.lock(); let all = running; lock.unlock(); for p in all where p.isRunning { p.terminate() } }
    func close() { lock.lock(); closed = true; lock.unlock(); terminateAll() }
}
#endif

#if !os(macOS)
/// The iPhone cannot start the helper programs (curl and ssh) the Mac uses to talk to FTP and SFTP servers, so on the iPhone these two session types exist only to say so.
/// Saved servers and their addresses are still understood; connecting to one answers "not available on iPhone".
final class FTPSession: RemoteSession, @unchecked Sendable {
    struct FileInfo: Equatable { var size: Int64?; var modified: Date? }
    private static let unavailable = RemoteError.unsupported("FTP servers are not available on iPhone.")
    init(config: FTPConfig) {}
    func list(_ path: String, limit: Int, onBatch: @Sendable ([RemoteEntry]) -> Void) async throws -> (count: Int, truncated: Bool) { throw Self.unavailable }
    func canonical(_ path: String) async throws -> String { throw Self.unavailable }
    func info(_ path: String) async throws -> FileInfo { throw Self.unavailable }
    func download(_ path: String, to file: URL, from offset: Int64, onProgress: @Sendable @escaping (Int64) -> Void) async throws { throw Self.unavailable }
    static func presentedCertificate(host: String, port: Int, implicit: Bool) async throws -> (pem: String, fingerprint: String) { throw unavailable }
    func close() {}
}
#endif
