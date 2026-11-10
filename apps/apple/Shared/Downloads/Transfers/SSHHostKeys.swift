import CryptoKit
import Foundation

// SSH host-key trust. The app keeps its own known_hosts file (one per profile), never the person's ~/.ssh/known_hosts, and passes it to `ssh` with StrictHostKeyChecking=yes, so `ssh`
// itself refuses a key that is not in the file. Before connecting, the key the server offers is read (ssh-keyscan) so the person can be shown its fingerprint the first time, and be warned
// if it differs from the one they trusted. A changed key is never accepted on its own.

struct SSHHostKeyStore: Sendable {
    let file: URL

    enum Verdict: Equatable, Sendable {
        case trusted
        case unknown(HostKeyInfo)
        case changed(old: [String], new: HostKeyInfo)
    }

    static func entryHost(_ host: String, _ port: Int) -> String { port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)" }

    static func fingerprint(ofBase64 b64: String) -> String? {
        guard let raw = Data(base64Encoded: b64), !raw.isEmpty else { return nil }
        let digest = Data(SHA256.hash(data: raw)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
        return "SHA256:" + digest
    }

    /// The keys trusted for this server: (type, base64).
    func trusted(host: String, port: Int) -> [(type: String, key: String)] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let want = Self.entryHost(host, port)
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count >= 3, String(f[0]) == want else { return nil }
            return (String(f[1]), String(f[2]))
        }
    }

    func verdict(host: String, port: Int, offered: [HostKeyInfo]) -> Verdict {
        let known = trusted(host: host, port: port)
        guard !offered.isEmpty else { return known.isEmpty ? .trusted : .trusted }          // nothing was offered: ssh will decide
        if known.isEmpty { return .unknown(offered.first(where: { $0.type == "ssh-ed25519" }) ?? offered[0]) }
        // Any offered key that is trusted is enough (a server has several key types; ssh uses the one both sides prefer, and checks it against the file).
        if offered.contains(where: { o in known.contains { $0.type == o.type && $0.key == o.keyBase64 } }) { return .trusted }
        // The server is known, and nothing it offers is what was trusted: that is a CHANGE (different key, or a different kind of key where the trusted one is no longer offered: an interceptor
        // that only speaks another key type looks exactly like this), never a first meeting.
        let o = offered.first(where: { o in known.contains { $0.type == o.type } }) ?? offered[0]
        return .changed(old: known.compactMap { Self.fingerprint(ofBase64: $0.key) }, new: o)
    }

    /// Records a key the person accepted. Appends; never rewrites other servers' lines.
    func trust(_ key: HostKeyInfo, host: String, port: Int) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = "\(Self.entryHost(host, port)) \(key.type) \(key.keyBase64)\n"
        if let h = try? FileHandle(forWritingTo: file) { defer { try? h.close() }; try h.seekToEnd(); try h.write(contentsOf: Data(line.utf8)) }
        else { try Data(line.utf8).write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }

    /// Forgets every key of one server, for the person who has decided a changed key is right (after being shown it).
    func forget(host: String, port: Int) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let want = Self.entryHost(host, port)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix(want + " ") }.map(String.init)
        try? Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: file, options: .atomic)
    }

    #if os(macOS)
    /// Reads the keys a server offers with the system's `ssh-keyscan`. Network only; nothing is trusted by this call.
    static func scan(host: String, port: Int, timeout: Int = 8) async throws -> [HostKeyInfo] {
        guard host.range(of: #"^[A-Za-z0-9.\-:_\[\]%]+$"#, options: .regularExpression) != nil, !host.hasPrefix("-") else { throw RemoteError.invalidAddress("That server name is not usable.") }
        let (out, _, code) = try await SSHProcess.run("/usr/bin/ssh-keyscan", ["-T", String(timeout), "-p", String(port), "-t", "ed25519,ecdsa,rsa", host], timeout: TimeInterval(timeout + 4))
        _ = code
        var keys: [HostKeyInfo] = []
        for line in out.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let fp = fingerprint(ofBase64: String(f[2])) else { continue }
            keys.append(HostKeyInfo(type: String(f[1]), keyBase64: String(f[2]), fingerprint: fp))
        }
        return keys
    }
    #else
    /// The iPhone cannot run the system's `ssh-keyscan`.
    static func scan(host: String, port: Int, timeout: Int = 8) async throws -> [HostKeyInfo] { throw RemoteError.unsupported("SFTP servers are not available on iPhone.") }
    #endif
}

#if os(macOS)
/// Runs one of the system's own command-line tools to the end, with a time limit. Output is bounded.
enum SSHProcess {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval, maxBytes: Int = 1 << 20) async throws -> (stdout: String, stderr: String, status: Int32) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
                p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
                let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e; p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: RemoteError.unsupported("A system tool needed for this (\(path)) could not be started.")); return }
                try? o.fileHandleForWriting.close(); try? e.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } } } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var out = Data(), err = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { while true { let d = o.fileHandleForReading.availableData; if d.isEmpty { break }; if out.count < maxBytes { out.append(d) } }; group.leave() }
                group.enter(); DispatchQueue.global().async { while true { let d = e.fileHandleForReading.availableData; if d.isEmpty { break }; if err.count < maxBytes { err.append(d) } }; group.leave() }
                p.waitUntilExit(); group.wait(); killer.cancel()
                cont.resume(returning: (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self), p.terminationStatus))
            }
        }
    }
}
#endif
