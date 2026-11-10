#if os(macOS)
import Foundation
import CryptoKit
import Darwin

// The optional "Advanced Media Downloads" component: a pinned, verified copy of the extractor (yt-dlp, onedir) that Browser Setu downloads into its own folder, with no administrator rights,
// no Homebrew, no Terminal and no system Python. What may be installed is decided by the app, not by the server: the pinned manifest (Contents/Resources/BundledTools.json) names the one
// release, its address, its size and its SHA-256. Nothing is run before the whole package has been downloaded, unpacked, compared byte for byte (a digest of the entire tree) and checked for
// the right architecture and signature; it is then moved into a new, versioned folder in one step. A failed or cancelled install leaves what was active untouched.
//
//   ~/Library/Application Support/BrowserSetu/MediaTools/
//       state.json                     { "active": "2026.10.26" }   (written atomically, last)
//       versions/<version>/<name>/...  immutable once activated; replaced only by a whole new folder
//       staging/<id>/                  downloads and unpacking; wiped at launch and after every install
//       .lock                          one installer at a time (flock), across processes

enum MediaToolsError: Error, Equatable, LocalizedError {
    case alreadyRunning, noPackage, insecureAddress, wrongArchitecture(String), notEnoughSpace(needed: Int64, available: Int64)
    case badSize(Int64), badChecksum, badArchive(String), unsafeEntry(String), treeMismatch, badSignature(String), notExecutable, cancelled, transport(String), notInstalled
    case blockedByMacOS, wontStart(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Media tools are already being installed."
        case .noPackage: "This version of Browser Setu has no media-tools package to install."
        case .insecureAddress: "The package address is not an approved secure address, so nothing was downloaded."
        case .wrongArchitecture(let a): "The package does not run on this Mac's processor (\(a))."
        case .notEnoughSpace(let n, let a): "There is not enough free space: about \(ByteCountFormatter.string(fromByteCount: n, countStyle: .file)) is needed and \(ByteCountFormatter.string(fromByteCount: a, countStyle: .file)) is free."
        case .badSize: "The downloaded file is not the expected size, so it was discarded."
        case .badChecksum: "The downloaded file does not match the published checksum, so it was discarded."
        case .badArchive(let s): "The package could not be unpacked (\(s))."
        case .unsafeEntry(let s): "The package contains an unsafe file (\(s)), so it was discarded."
        case .treeMismatch: "The unpacked files are not exactly the expected ones, so nothing was installed."
        case .badSignature(let s): "The package's code signature is not acceptable (\(s)), so nothing was installed."
        case .notExecutable: "The package has no runnable extractor."
        case .cancelled: "Installation was cancelled."
        case .transport(let s): "The download failed: \(s)"
        case .notInstalled: "Media tools are not installed."
        case .blockedByMacOS: "macOS (Gatekeeper) blocked the media tools from starting because this package is not signed and notarized by its publisher. Nothing was installed. This needs the release package from the publisher."
        case .wontStart(let s): "The media tools were downloaded and checked but would not start (\(s)), so nothing was installed."
        }
    }
}

/// Where bytes come from. The real one is an HTTPS download restricted to approved hosts; tests give it a local file.
protocol MediaToolsTransport: Sendable {
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

/// HTTPS only, no cookies or credentials, redirects only to approved hosts.
final class HTTPSMediaToolsTransport: NSObject, MediaToolsTransport, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let approvedHosts: Set<String> = ["github.com"]
    static let approvedSuffixes = [".githubusercontent.com"]
    static func approved(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443, url.user == nil, let h = url.host?.lowercased() else { return false }
        return approvedHosts.contains(h) || approvedSuffixes.contains { h.hasSuffix($0) }
    }
    private var progress: (@Sendable (Int64, Int64) -> Void)?

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard Self.approved(url) else { throw MediaToolsError.insecureAddress }
        self.progress = progress
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never; cfg.httpShouldSetCookies = false; cfg.urlCredentialStorage = nil; cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30; cfg.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url); req.setValue("BrowserSetu", forHTTPHeaderField: "User-Agent")
        do {
            let (tmp, resp) = try await session.download(for: req, delegate: self)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw MediaToolsError.transport("the server answered \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch is CancellationError { throw MediaToolsError.cancelled }
        catch let e as MediaToolsError { throw e }
        catch let e as URLError where e.code == .cancelled { throw MediaToolsError.cancelled }
        catch { throw MediaToolsError.transport(MediaToolsInstall.friendly(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url, Self.approved(u) { completionHandler(request) } else { completionHandler(nil) }   // nil: the redirect is not followed
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { progress?(totalBytesWritten, totalBytesExpectedToWrite) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

/// The installation itself: pure file work, off the main thread, testable with a fake transport and a temporary folder.
enum MediaToolsInstall {
    struct Policy {
        var requiredSignature: String   // "adhoc" (the upstream build) or "teamID:XXXXXXXXXX" (the release pipeline's re-signed package)
    }

    /// Compile-time, not a setting: a release build can never run with a development policy.
    static let isReleaseBuild: Bool = {
        #if DEBUG
        false
        #else
        true
        #endif
    }()
    /// The publisher policy is the only one a release build accepts. The ad-hoc policy (the unmodified upstream package) is for approved development fixtures in Debug builds.
    static func policyAllowed(_ p: Policy, release: Bool) -> Bool { p.requiredSignature.hasPrefix("teamID:") || (!release && p.requiredSignature == "adhoc") }

    /// Text shown to the person never carries the home folder or temporary-folder paths.
    static func redact(_ s: String) -> String {
        var t = s
        for (p, r) in [(NSTemporaryDirectory(), "…/"), (NSHomeDirectory(), "~")] where !p.isEmpty && p != "/" { t = t.replacingOccurrences(of: p, with: r) }
        return String(t.prefix(300))
    }
    static func friendly(_ e: Error) -> String {
        if let u = e as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "there is no internet connection"
            case .timedOut: return "the connection timed out"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "the secure connection could not be verified"
            default: return "a network error (\(u.code.rawValue))"
            }
        }
        return redact(e.localizedDescription)
    }

    static var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    static func defaultRoot() -> URL { ManagedToolFolder.defaultRoot() }
    static func activeVersion(root: URL) -> String? { ManagedToolFolder.activeVersion(root: root) }
    static func isSafeName(_ s: String) -> Bool { ManagedToolFolder.isSafeName(s) }

    static func neededSpace(_ m: BundledToolManifest) -> Int64 { (m.size ?? 60_000_000) + (m.unpackedBytes ?? 200_000_000) * 2 }

    @discardableResult
    static func run(_ launch: String, _ args: [String], timeout: TimeInterval = 120, limit: Int = 20_000) -> (status: Int32, out: String, truncated: Bool) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: launch); p.arguments = args
        // A clean environment: the app's own PATH, DYLD_* and TMPDIR are not handed to the system tools (unzip, codesign, lipo) or to a package being checked.
        p.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error)", false) }
        // Terminate, and if it ignores that, kill it: a child that will not stop must not hold the read below open forever.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } } } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit(); killer.cancel()
        return (p.terminationStatus, String(decoding: data.prefix(limit), as: UTF8.self), data.count > limit)
    }

    /// Download → check size and SHA-256 → unpack → check every entry → compare the whole tree → check architecture and signature → activate. Throws before anything is activated.
    static func install(_ m: BundledToolManifest, root: URL, transport: MediaToolsTransport, policy: Policy, availableBytes: () -> Int64 = { availableSpace() },
                        launchCheck: ((URL, BundledToolManifest) async throws -> Void)? = nil,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let fm = FileManager.default
        guard policyAllowed(policy, release: isReleaseBuild) else { throw MediaToolsError.badSignature("this build only accepts a package signed by the publisher") }
        guard let pinnedTree = m.treeSHA256?.lowercased(), let pkgURL = URL(string: m.sourceURL) else { throw MediaToolsError.noPackage }
        guard isSafeName(m.name), isSafeName(m.version), let exeName = m.executable, isSafeName(exeName) else { throw MediaToolsError.noPackage }
        guard m.architectures?.contains(hostArchitecture) ?? true else { throw MediaToolsError.wrongArchitecture(hostArchitecture) }
        guard pkgURL.scheme == "https" else { throw MediaToolsError.insecureAddress }
        let need = neededSpace(m), have = availableBytes()
        guard have >= need else { throw MediaToolsError.notEnoughSpace(needed: need, available: have) }

        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // One installer at a time, across processes.
        let lockFD = open(root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        // The launch-time cleanup holds this lock for a moment: wait a little for it instead of calling that "already being installed". A real second installer holds it far longer.
        guard lockFD >= 0, lockBriefly(lockFD) else { if lockFD >= 0 { close(lockFD) }; throw MediaToolsError.alreadyRunning }
        defer { flock(lockFD, LOCK_UN); close(lockFD) }

        let staging = root.appendingPathComponent("staging/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }

        // 1. Download to a partial file; it is only ever renamed to .zip once it is complete and checked.
        let part = staging.appendingPathComponent("package.zip.part")
        progress(0, "Downloading…")
        try await transport.download(pkgURL, to: part) { done, total in
            let t = total > 0 ? total : (m.size ?? 0)
            if t > 0 { progress(min(0.8, Double(done) / Double(t) * 0.8), "Downloading…") }
        }
        try Task.checkCancellation()
        let got = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? -1
        if let want = m.size, got != want { throw MediaToolsError.badSize(got) }
        progress(0.82, "Checking the download…")
        guard BundledExtractor.sha256(of: part)?.lowercased() == m.sha256.lowercased() else { throw MediaToolsError.badChecksum }
        let zip = staging.appendingPathComponent("package.zip"); try fm.moveItem(at: part, to: zip)

        // 2. Check the archive's entries before unpacking anything: no absolute paths, no "..", no odd names.
        progress(0.84, "Unpacking…")
        let listing = run("/usr/bin/unzip", ["-Z1", zip.path], limit: 8_000_000)
        guard listing.status == 0, !listing.truncated else { throw MediaToolsError.badArchive("unreadable") }
        for line in listing.out.split(separator: "\n") {
            let e = String(line)
            if e.hasPrefix("/") || e.contains("\0") || e.split(separator: "/").contains("..") { throw MediaToolsError.unsafeEntry(String(e.prefix(60))) }
        }
        let unpacked = staging.appendingPathComponent("tree", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let x = run("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", unpacked.path], timeout: 300)       // the same unpacking the pin was computed from
        guard x.status == 0 else { throw MediaToolsError.badArchive("unzip \(x.status)") }
        try Task.checkCancellation()

        // 3. Links must stay inside the tree; then the whole tree must be exactly the pinned one.
        progress(0.9, "Verifying…")
        try checkLinks(in: unpacked)
        guard BundledExtractor.treeDigest(of: unpacked) == pinnedTree else { throw MediaToolsError.treeMismatch }
        let exe = unpacked.appendingPathComponent(exeName)
        guard fm.isExecutableFile(atPath: exe.path) else { throw MediaToolsError.notExecutable }
        let archs = run("/usr/bin/lipo", ["-archs", exe.path])
        guard archs.status == 0, archs.out.split(whereSeparator: { $0 == " " || $0 == "\n" }).contains(Substring(hostArchitecture)) else { throw MediaToolsError.wrongArchitecture(hostArchitecture) }
        try checkSignature(exe, unpacked: unpacked, policy: policy)
        try checkEveryMachO(in: unpacked, policy: policy)
        // The program must actually start under the system's own rules (Gatekeeper included, quarantine intact) before anything is activated: "Ready" always means "has been started successfully".
        progress(0.94, "Starting it once…")
        try await (launchCheck ?? defaultLaunchCheck)(exe, m)
        try Task.checkCancellation()

        // 4. Activate: the verified folder becomes versions/<version>/<name> in one rename; state.json is written last and atomically. The previous version stays until this succeeds.
        progress(0.96, "Finishing…")
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        try fm.createDirectory(at: versions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dest = versions.appendingPathComponent(m.version, isDirectory: true)
        let target = dest.appendingPathComponent(m.name, isDirectory: true)
        var old: URL?
        if fm.fileExists(atPath: dest.path) { old = versions.appendingPathComponent(".old-\(m.version)"); try? fm.removeItem(at: old!); try fm.moveItem(at: dest, to: old!) }
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try fm.moveItem(at: unpacked, to: target)
            let state = try JSONSerialization.data(withJSONObject: ["active": m.version, "tree": pinnedTree])
            try state.write(to: root.appendingPathComponent("state.json"), options: .atomic)
        } catch {
            try? fm.removeItem(at: dest)
            if let old { try? fm.moveItem(at: old, to: dest) }          // rollback: what was there is put back
            throw error
        }
        if let old { try? fm.removeItem(at: old) }
        // Older versions are removed only now that the new one is active.
        for u in (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent != m.version { try? fm.removeItem(at: u) }
        progress(1, "Ready")
    }

    static func checkLinks(in root: URL) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { throw MediaToolsError.badArchive("unreadable tree") }
        for case let u as URL in e {
            guard (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            guard let t = try? fm.destinationOfSymbolicLink(atPath: u.path) else { throw MediaToolsError.unsafeEntry("link") }
            let resolved = URL(fileURLWithPath: t, relativeTo: u.deletingLastPathComponent()).standardizedFileURL.path
            if t.hasPrefix("/") || !(resolved + "/").hasPrefix(root.standardizedFileURL.path + "/") { throw MediaToolsError.unsafeEntry("link leaves the package: \(u.lastPathComponent)") }
        }
    }

    /// The package's own signature, checked with the system tool: it must verify strictly, and it must be the kind the manifest requires.
    static func checkSignature(_ exe: URL, unpacked: URL, policy: Policy) throws {
        let v = run("/usr/bin/codesign", ["--verify", "--strict", exe.path])
        guard v.status == 0 else { throw MediaToolsError.badSignature("does not verify") }
        let d = run("/usr/bin/codesign", ["-dv", "--verbose=2", exe.path])
        let isAdhoc = d.out.contains("Signature=adhoc")
        if policy.requiredSignature == "adhoc" { guard isAdhoc else { throw MediaToolsError.badSignature("expected the upstream ad-hoc signature") } }
        else if policy.requiredSignature.hasPrefix("teamID:") {
            let team = String(policy.requiredSignature.dropFirst(7))
            guard !team.isEmpty, !isAdhoc, d.out.split(separator: "\n").contains(Substring("TeamIdentifier=\(team)")) else { throw MediaToolsError.badSignature("not signed by the expected publisher") }
            guard d.out.contains("flags=0x10000(runtime)") || d.out.contains("(runtime)") else { throw MediaToolsError.badSignature("the hardened runtime is not enabled") }
            // Notarization: the system's own assessment must accept it as a notarized Developer ID program. This is fail-closed. Verified on a real notarized package: `--type install` reports "source=Notarized Developer ID" (`--type execute` rejects any bare program).
            let a = run("/usr/sbin/spctl", ["--assess", "--type", "install", "--verbose=4", exe.path])      // "execute" is for app bundles ("does not seem to be an app"); "install" accepts a notarized bare program
            guard a.status == 0, a.out.contains("Notarized Developer ID") else { throw MediaToolsError.badSignature("not accepted as notarized by the system") }
        } else { throw MediaToolsError.badSignature("unknown policy") }
    }

    /// Every Mach-O file in the package (the program, Python, every library and extension) that does not verify strictly, or, under a publisher policy, does not carry that publisher's Team ID.
    static func machOFailures(in root: URL, policy: Policy) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root.path) else { return ["<unreadable>"] }
        let magics: Set<UInt32> = [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0xcafebabe, 0xbebafeca]
        var failures: [String] = []
        for case let rel as String in e {
            let u = root.appendingPathComponent(rel)
            guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let h = try? FileHandle(forReadingFrom: u) else { continue }
            let head = (try? h.read(upToCount: 4)) ?? Data(); try? h.close()
            guard head.count == 4, magics.contains(head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) else { continue }
            if run("/usr/bin/codesign", ["--verify", "--strict", u.path]).status != 0 { failures.append(rel); continue }
            if policy.requiredSignature.hasPrefix("teamID:") {
                let team = String(policy.requiredSignature.dropFirst(7))
                let d = run("/usr/bin/codesign", ["-dv", "--verbose=2", u.path])
                if !d.out.split(separator: "\n").contains(Substring("TeamIdentifier=\(team)")) { failures.append(rel) }
            }
        }
        return failures
    }

    /// Under a publisher policy (the release package) every file must pass, or nothing is installed. The ad-hoc development pin is the unmodified upstream build, whose Python.framework copies do not
    /// verify in this layout (a defect of that package, fixed only by re-signing), so there the result is reported by `machOFailures` and the main program is still checked strictly.
    static func checkEveryMachO(in root: URL, policy: Policy) throws {
        guard policy.requiredSignature.hasPrefix("teamID:") else { return }
        let f = machOFailures(in: root, policy: policy)
        if !f.isEmpty { throw MediaToolsError.badSignature("\(f.count) file(s) do not verify, for example \(f[0])") }
    }

    /// Starts the program once (`--version`) with the app's own launcher, and requires the pinned version back. A system refusal (killed before it could answer) is reported as such.
    /// FFmpeg: `-version` must answer with the pinned version. A system refusal is reported as such.
    static let ffmpegLaunchCheck: (URL, BundledToolManifest) async throws -> Void = { exe, m in
        do {
            let out = try await ExternalExtractor.run(exe, arguments: ["-hide_banner", "-version"], timeout: 30, maxBytes: 16_384)
            guard String(decoding: out, as: UTF8.self).contains("ffmpeg version \(m.version)") else { throw MediaToolsError.wontStart("it reported another version") }
            try await ffprobeCheck(next: exe, m)
        } catch let e as ExtractorFailure {
            if case .failed(let code, let msg) = e, code == 137 || code == 128 + SIGKILL || code == 128 + SIGTRAP, msg.isEmpty { throw MediaToolsError.blockedByMacOS }
            throw MediaToolsError.wontStart(MediaToolsInstall.redact(e.localizedDescription))
        }
    }

    /// FFprobe is the other half of the tool: every output is checked with it, so the one beside `exe` must exist, start, and be the pinned version.
    static func ffprobeCheck(next exe: URL, _ m: BundledToolManifest) async throws {
        let probe = exe.deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { throw MediaToolsError.wontStart("the checking program is missing") }
        let out = try await ExternalExtractor.run(probe, arguments: ["-hide_banner", "-version"], timeout: 30, maxBytes: 16_384)
        guard String(decoding: out, as: UTF8.self).contains("ffprobe version \(m.version)") else { throw MediaToolsError.wontStart("the checking program reported another version") }
    }

    static let defaultLaunchCheck: (URL, BundledToolManifest) async throws -> Void = { exe, m in
        do {
            let out = try await ExternalExtractor.run(exe, arguments: ["--version"] + BundledExtractor.extraArguments, timeout: 30, maxBytes: 4096)
            guard String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == m.version else { throw MediaToolsError.wontStart("it reported another version") }
        } catch let e as ExtractorFailure {
            if case .failed(let code, let msg) = e, code == 137 || code == 128 + SIGKILL || code == 128 + SIGTRAP, msg.isEmpty { throw MediaToolsError.blockedByMacOS }
            throw MediaToolsError.wontStart(MediaToolsInstall.redact(e.localizedDescription))
        }
    }

    static func availableSpace() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }

    /// Removes leftovers of an interrupted install (staging) and returns whether an active, intact-looking version exists.
    static func cleanup(root: URL) {
        // Not while another installer (this or another app instance) is running: its staging folder is in use.
        let fd = open(root.path + "/.lock", O_RDWR)
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 { return }
        let fm = FileManager.default
        try? fm.removeItem(at: root.appendingPathComponent("staging"))
        let versions = root.appendingPathComponent("versions")
        let active = activeVersion(root: root)
        let entries = (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? []
        // Crash recovery: an update that died after moving the active version aside leaves `.old-<version>` and no `<version>`. Put it back; otherwise it is only a leftover.
        for u in entries where u.lastPathComponent.hasPrefix(".old-") {
            let v = String(u.lastPathComponent.dropFirst(5))
            let dest = versions.appendingPathComponent(v)
            let destEmpty = ((try? fm.contentsOfDirectory(atPath: dest.path))?.isEmpty) ?? true          // the new folder was created but the verified tree never arrived in it
            if let active, v == active, destEmpty { try? fm.removeItem(at: dest); try? fm.moveItem(at: u, to: dest) }
            else { try? fm.removeItem(at: u) }
        }
        // Retired versions (anything that is not the active one) are removed once the active one is in place.
        if let active, fm.fileExists(atPath: versions.appendingPathComponent(active).path) {
            for u in (try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)) ?? [] where u.lastPathComponent != active { try? fm.removeItem(at: u) }
        }
    }

    /// Takes the installer lock, trying again for up to `seconds` (the cleanup that runs when the app starts holds it only briefly). False if it is still held.
    static func lockBriefly(_ fd: Int32, seconds: Double = 1) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            usleep(50_000)
        } while Date() < end
        return false
    }

    static func remove(root: URL) throws {
        let fm = FileManager.default
        let lockFD = open(root.path + "/.lock", O_CREAT | O_RDWR, 0o600)
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        if lockFD >= 0, !lockBriefly(lockFD) { throw MediaToolsError.alreadyRunning }
        for n in ["state.json", "versions", "staging"] {
            let u = root.appendingPathComponent(n)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
    }
}

/// What the screens observe. One installation at a time; browsing and downloads are not affected while it runs.
@MainActor
final class MediaToolsStore: ObservableObject {
    static let shared = MediaToolsStore()
    /// The optional media processing tool (FFmpeg and FFprobe): same installer, its own folder, state and lock.
    static let ffmpeg = MediaToolsStore(root: FFmpegTool.tool.managedRoot, tool: FFmpegTool.tool, launchCheck: MediaToolsInstall.ffmpegLaunchCheck, choiceKey: "mediaProcessing.choice")

    enum Phase: Equatable {
        case checking, notInstalled, working(Double, String), ready(String), failed(String), updateAvailable(installed: String)
        var isFailed: Bool { if case .failed = self { return true }; return false }
    }
    /// What the person chose in setup: nothing recorded, accepted, or declined (never asked again).
    enum Choice: String { case undecided, accepted, declined }

    @Published private(set) var phase: Phase = .checking
    @Published private(set) var choice: Choice
    var root: URL
    var transport: MediaToolsTransport
    var policy: MediaToolsInstall.Policy
    var availableBytes: () -> Int64 = { MediaToolsInstall.availableSpace() }
    private var task: Task<Void, Never>?
    private var generation = 0
    /// Removals that have started and not finished (install waits for them).
    private var removalsPending = 0
    /// Starts the program once before it is activated; tests give it a stand-in outcome.
    var launchCheck: ((URL, BundledToolManifest) async throws -> Void)?
    var defaults: UserDefaults

    let tool: ManagedTool
    private let choiceKey: String
    init(root: URL = MediaToolsInstall.defaultRoot(), tool: ManagedTool = BundledExtractor.tool, transport: MediaToolsTransport = HTTPSMediaToolsTransport(), defaults: UserDefaults = .standard,
         policy: MediaToolsInstall.Policy = .init(requiredSignature: "adhoc"), launchCheck: ((URL, BundledToolManifest) async throws -> Void)? = nil, choiceKey: String = "mediaTools.choice") {
        self.root = root; self.tool = tool; self.transport = transport; self.defaults = defaults; self.policy = policy; self.launchCheck = launchCheck; self.choiceKey = choiceKey
        choice = Choice(rawValue: defaults.string(forKey: choiceKey) ?? "") ?? .undecided
    }

    var manifest: BundledToolManifest? { tool.manifest() }
    var isReady: Bool { if case .ready = phase { return true }; return false }
    var isBusy: Bool { if case .working = phase { return true }; return false }
    /// "54 MB download · about 124 MB on disk" from the pinned manifest.
    var sizeSummary: String? {
        guard let m = manifest, let s = m.size else { return nil }
        let f = ByteCountFormatter(); f.countStyle = .file
        let disk = m.unpackedBytes.map { " · about \(f.string(fromByteCount: $0)) on disk" } ?? ""
        return "\(f.string(fromByteCount: s)) download\(disk)"
    }

    func reloadChoice() { choice = Choice(rawValue: defaults.string(forKey: choiceKey) ?? "") ?? .undecided }
    func setChoice(_ c: Choice) { choice = c; defaults.set(c.rawValue, forKey: choiceKey) }

    /// Looks at what is installed, off the main thread (hashing the tree takes a moment).
    func refresh() {
        // Not while a removal is going: reading the folder half-deleted would show "Installed" for tools being deleted, or offer Install that cannot start; the removal sets the state when it ends.
        guard !isBusy, removalsPending == 0 else { return }
        let r0 = root
        Task.detached { MediaToolsInstall.cleanup(root: r0) }          // file work, off the main thread
        guard let m = manifest else { phase = .notInstalled; return }
        guard let installed = MediaToolsInstall.activeVersion(root: root) else {
            if tool.isInAppBundle { phase = .ready(m.version) } else { phase = .notInstalled }
            return
        }
        phase = .checking
        generation += 1; let mine = generation
        let r = root
        Task { [weak self] in
            let ok = await tool.verifyAsync() != nil
            await MainActor.run {
                guard let self, !self.isBusy, self.generation == mine else { return }          // a newer install, remove or refresh owns the state now
                if !ok { self.phase = installed != m.version ? .updateAvailable(installed: installed) : .failed("The installed media tools do not match their published checksums. Retry downloads them again, or Remove them.") }
                else { self.phase = .ready(installed) }
                _ = r
            }
        }
    }

    /// Install, update or repair: the same verified path. The person's confirmation happens before this is called.
    func install() {
        guard !isBusy, removalsPending == 0, let m = manifest, m.isInstallable else { return }          // not while a removal is still going: the two would fight over the folder
        setChoice(.accepted)
        phase = .working(0, "Starting…")
        generation += 1; let mine = generation
        let root = self.root, transport = self.transport, policy = m.signaturePolicy.map { MediaToolsInstall.Policy(requiredSignature: $0) } ?? (MediaToolsInstall.isReleaseBuild ? MediaToolsInstall.Policy(requiredSignature: "") : self.policy), avail = self.availableBytes, check = self.launchCheck
        // An update or repair swaps the installed version: jobs already using the tool finish first and none starts meanwhile.
        let leases: ToolLeases? = tool === FFmpegTool.tool ? FFmpegTool.leases : nil
        task = Task { [weak self] in
            leases?.close()
            defer { leases?.reopen() }
            await leases?.drain()
            do {
                let report: @Sendable (Double, String) -> Void = { frac, text in Task { @MainActor in if let self, self.generation == mine, self.isBusy { self.phase = .working(frac, text) } } }
                // The file work (hashing, unpacking) runs off the main thread; cancelling here cancels it.
                let work = Task.detached { try await MediaToolsInstall.install(m, root: root, transport: transport, policy: policy, availableBytes: avail, launchCheck: check, progress: report) }
                try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                tool.forgetCache()
                guard await tool.verifyAsync() != nil else { throw MediaToolsError.treeMismatch }
                if self?.generation == mine { self?.phase = .ready(m.version) }
            } catch {
                tool.forgetCache()
                guard let self, self.generation == mine else { return }
                if (error as? MediaToolsError) == .cancelled || error is CancellationError { self.refreshAfterCancel() }
                else { self.phase = .failed((error as? MediaToolsError)?.errorDescription ?? "The installation did not complete.") }
            }
            if self?.generation == mine { self?.task = nil }
        }
    }

    private func refreshAfterCancel() { phase = .notInstalled; if ManagedToolFolder.activeVersion(root: root) != nil { phase = .checking; refresh() } }

    func cancel() { task?.cancel() }

    /// Waits for a running install to unwind (it holds the installer lock), then removes; a failure to delete is shown, not hidden.
    func remove() {
        let running = task
        running?.cancel()
        generation += 1
        phase = .checking
        let mine = generation, root = self.root
        // Jobs that already use the tool finish first (no new one starts meanwhile); the files are deleted only when none is left.
        let leases: ToolLeases? = tool === FFmpegTool.tool ? FFmpegTool.leases : nil
        leases?.close()
        removalsPending += 1
        Task { [weak self] in
            await running?.value
            await leases?.drain()
            // Deleting about 100 MB is file work: off the main thread.
            let result: Result<Void, Error> = await Task.detached { Result { try MediaToolsInstall.remove(root: root) } }.value
            leases?.reopen()
            self?.removalsPending -= 1
            guard let self, self.generation == mine else { return }
            switch result {
            case .success: tool.forgetCache(); self.phase = .notInstalled
            case .failure(let e): self.phase = .failed((e as? MediaToolsError)?.errorDescription ?? "The media tools could not be removed completely.")
            }
        }
    }

    func decline() { cancel(); setChoice(.declined) }
}

#if DEBUG
/// Debug only (`-MediaToolsFixture <folder>`): points the app at a package built by scripts/release-media-tools.sh, installs into an isolated throwaway folder, and serves the zip from disk instead of the
/// network, so UI tests can run the real install without touching Application Support. It does not exist in a release build and relaxes nothing: the package is still verified, signature-checked, notarization-assessed and started.
enum MediaToolsDebug {
    final class Counter: @unchecked Sendable { var failuresLeft: Int; init(_ n: Int) { failuresLeft = n } }
    struct DiskTransport: MediaToolsTransport {
        var zip: URL; var stepNanos: UInt64 = 15_000_000; var counter: Counter
        func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            let size = (try? FileManager.default.attributesOfItem(atPath: zip.path)[.size] as? Int64) ?? 0
            for i in 1...10 { try Task.checkCancellation(); progress(size * Int64(i) / 10, size); try await Task.sleep(nanoseconds: stepNanos) }
            if counter.failuresLeft > 0 { counter.failuresLeft -= 1; throw MediaToolsError.transport("the test server is not reachable") }
            try FileManager.default.copyItem(at: zip, to: destination)
        }
    }
    /// Options (all launch arguments): MediaToolsFixture <folder with the zip and manifest-fragment.json>, MediaToolsFixtureRoot <install folder; default a new temporary one>, MediaToolsFixtureSuite <defaults
    /// suite for the remembered choice; default a new one>, MediaToolsFixtureSlow YES (about 5 s download), MediaToolsFixtureFailFirst <n downloads that fail first>, MediaToolsFixtureSkipLaunch YES (only for a
    /// package that is not notarized: the fixture program is not started by the installer; the real start under Gatekeeper is covered by the notarized acceptance test).
    /// The same options exist for the media processing tool with the prefix `FFmpegToolsFixture` (`-FFmpegToolsFixture <folder>`, `-FFmpegToolsFixtureRoot`, …) and its own store, manifest and choice.
    @MainActor static func configure(folder: URL, prefix: String = "MediaToolsFixture", store: MediaToolsStore = .shared, resource: String = "BundledTools") {
        let fm = FileManager.default, d = UserDefaults.standard
        guard let zip = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "zip" }),
              let fragData = try? Data(contentsOf: folder.appendingPathComponent("manifest-fragment.json")),
              let frag = try? JSONSerialization.jsonObject(with: fragData) as? [String: Any],
              let base = Bundle.main.url(forResource: resource, withExtension: "json"), let baseData = try? Data(contentsOf: base),
              var m = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            // Never fall back to the real install folder, real defaults or the real network: a test run with a broken fixture must stop, not install for real.
            fatalError("MediaToolsFixture: the folder \(folder.path) has no usable zip and manifest-fragment.json")
        }
        for (k, v) in frag { m[k] = v }
        let root = d.string(forKey: prefix + "Root").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bs-ui-mediatools-\(UUID().uuidString)", isDirectory: true)
        let manifest = fm.temporaryDirectory.appendingPathComponent("bs-ui-manifest-\(UUID().uuidString).json")
        guard let out = try? JSONSerialization.data(withJSONObject: m), (try? out.write(to: manifest)) != nil else { fatalError("MediaToolsFixture: cannot write the test manifest") }
        store.tool.manifestURL = manifest; store.tool.managedRoot = root; store.tool.forgetCache()
        guard let suite = UserDefaults(suiteName: d.string(forKey: prefix + "Suite") ?? "bs-ui-mediatools-\(UUID().uuidString)") else { fatalError("MediaToolsFixture: no defaults suite") }
        store.defaults = suite
        store.reloadChoice()
        store.root = root
        store.transport = DiskTransport(zip: zip, stepNanos: d.bool(forKey: prefix + "Slow") ? 250_000_000 : 15_000_000, counter: Counter(d.integer(forKey: prefix + "FailFirst")))
        if d.bool(forKey: prefix + "SkipLaunch") { store.launchCheck = { _, _ in } }
        store.refresh()
    }
}
#endif

#endif
