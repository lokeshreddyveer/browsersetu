import Foundation
import CryptoKit
import Darwin

// An optional, person-chosen external extractor program (for example yt-dlp). Browser Setu does not include, install or update one. When it is configured and allowed, a video page address is
// handed to it and its structured answer (JSON on standard output) is turned into a NormalizedMediaSource; the media is then fetched by the existing engines. Nothing it prints is run or
// trusted: it is size-limited, parsed against a fixed shape, and every address in it is checked like any other. The program runs as a child process with the person's own permissions: that is the
// person's choice and risk, so what it is given is kept to the address alone.

enum ExtractorSettings {
    static let enabledKey = "bs.extractor.enabled", pathKey = "bs.extractor.path"
    static let bundledKey = "bs.extractor.bundled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    /// Use the extractor that ships with the app (on unless the person turns it off).
    static var useBundled: Bool { UserDefaults.standard.object(forKey: bundledKey) as? Bool ?? true }
    static var path: String? { UserDefaults.standard.string(forKey: pathKey) }
}

/// The actionable text for a YouTube JavaScript-challenge failure (the solver itself is macOS-only; this wording is shared so every platform's error reads the same).
enum JSChallengeProviderAdvice {
    /// Added by the lookup of the BUNDLED extractor only. A yt-dlp the person chose themselves never had Browser Setu's solver, so its failures are shown as they are.
    static let marker = "\u{1}bundled-yt-dlp-js:"
    static func matches(_ stderr: String) -> Bool {
        let t = stderr.lowercased()
        return ["javascript runtime", "n challenge", "challenge solving failed", "signature solving failed", "js challenge"].contains { t.contains($0) }
    }
    static let text = "YouTube hides some video addresses behind a small JavaScript puzzle. Browser Setu's built-in solver could not solve it for this page, or is not available in this copy of the app, so some formats may be missing or this video cannot be read. YouTube changes this often: try again later and check for a Browser Setu update. You can also choose a yt-dlp you installed yourself in Settings > Media. Other websites are not affected."
}

enum ExtractorFailure: Error, Equatable, LocalizedError, Sendable {
    case notConfigured, missing(String), notExecutable(String), unsafeLocation(String), badAddress, tooManyRunning, timedOut, tooMuchOutput, failed(Int32, String), malformed(String), wrongVideo, noFormats(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: "No external extractor is set up. Choose one in Settings › Media."
        case .missing(let p): "The extractor program is not there any more (\(p))."
        case .notExecutable(let p): "\(p) is not a program that can be run."
        case .unsafeLocation(let why): "The extractor cannot be used: \(why)."
        case .badAddress: "That address cannot be given to the extractor."
        case .tooManyRunning: "The extractor is already busy with other lookups."
        case .timedOut: "The extractor took too long and was stopped."
        case .tooMuchOutput: "The extractor produced more output than is allowed and was stopped."
        case .failed(let c, let s) where s.isEmpty && (c == 137 || c == 128 + SIGTRAP): "macOS stopped the extractor from starting (code \(c)). This usually means its code signature or notarization was rejected by Gatekeeper. Use the publisher's release package, or choose a different program in Settings › Media."
        case .failed(_, let s) where s.hasPrefix(JSChallengeProviderAdvice.marker): JSChallengeProviderAdvice.text
        case .failed(let c, let s): "The extractor reported an error (code \(c))" + (s.isEmpty ? "." : ": \(s)")
        case .malformed(let w): "The extractor's answer was not in the expected form (\(w))."
        case .wrongVideo: "The extractor answered about a different page than the one asked."
        case .noFormats(let why): "Source not resolved: \(why)"
        }
    }
}

struct ExtractorHealth: Equatable, Sendable { var version: String?; var problem: String?; var ok: Bool { problem == nil && version != nil } }

enum ExternalExtractor {
    static let maxOutput = 8 * 1024 * 1024
    static let defaultTimeout: TimeInterval = 60
    static let maxConcurrent = 2
    static let maxFormats = 400

    // MARK: Checking the program

    /// The program must be an absolute path to a regular, executable file that only its owner (or root) can change.
    /// This app runs in the macOS App Sandbox, which does not let it start programs from arbitrary places. Apple's route for that (NSUserUnixTask) runs a script the person has put in this app's own
    /// Application Scripts folder, outside the sandbox. So the extractor is such a script (typically a few lines that call the tool the person installed); anything elsewhere is refused.
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }
    #if os(macOS)
    static var scriptsFolder: URL? { try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: false) }
    #else
    static var scriptsFolder: URL? { nil }          // the iPhone has no Application Scripts folder and cannot start other programs
    #endif

    static func validateLocation(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ExtractorFailure.unsafeLocation("the path is not absolute") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if isSandboxed {
            guard let folder = scriptsFolder?.resolvingSymlinksInPath(), url.deletingLastPathComponent().path == folder.path else {
                throw ExtractorFailure.unsafeLocation("choose a script in this app's Application Scripts folder (Settings › Media › Open Scripts Folder)")
            }
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ExtractorFailure.missing(path) }
        guard !isDir.boolValue, fm.isExecutableFile(atPath: url.path) else { throw ExtractorFailure.notExecutable(url.lastPathComponent) }
        try requireOwnerOnlyWritable(url, what: "the program")
        // Whoever can change the folder can swap the program after it has been checked, so the folder must be as closed as the file.
        try requireOwnerOnlyWritable(url.deletingLastPathComponent(), what: "its folder")
        // Every folder above it too: whoever can rename one of them can put another program in its place. (A sticky folder such as /tmp only lets each person rename their own entries.)
        var dir = url.deletingLastPathComponent().deletingLastPathComponent()
        while dir.path != "/" {
            let a = try? FileManager.default.attributesOfItem(atPath: dir.path)
            let perm = (a?[.posixPermissions] as? NSNumber)?.intValue ?? 0
            let owner = (a?[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0
            if perm & 0o022 != 0, perm & 0o1000 == 0 { throw ExtractorFailure.unsafeLocation("a folder above it (\(dir.lastPathComponent)) can be changed by other users") }
            if owner != 0, owner != getuid() { throw ExtractorFailure.unsafeLocation("a folder above it belongs to another user") }
            dir = dir.deletingLastPathComponent()
        }
        return url
    }

    /// Owned by this person or root, not writable by group or others, and without an access-control list (which can grant others write access the permission bits do not show).
    private static func requireOwnerOnlyWritable(_ url: URL, what: String) throws {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let perm = attrs?[.posixPermissions] as? NSNumber, perm.intValue & 0o022 != 0 { throw ExtractorFailure.unsafeLocation("other users can change \(what)") }
        if let owner = attrs?[.ownerAccountID] as? NSNumber, owner.uint32Value != 0, owner.uint32Value != getuid() { throw ExtractorFailure.unsafeLocation("\(what) belongs to another user") }
        if let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) { acl_free(UnsafeMutableRawPointer(acl)); throw ExtractorFailure.unsafeLocation("\(what) has an access-control list") }
    }

    /// Which program this is: its resolved path and a fingerprint of its contents. A grant is made for exactly this; a different or changed program asks again.
    static func identity(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return url.path + "|" + digest          // the full SHA-256: a grant must not be satisfiable by a different file that shares a prefix
    }

    static func health(path: String) async -> ExtractorHealth {
        do {
            let url = try validateLocation(path)
            let out = try await run(url, arguments: ["--version"], timeout: 10, maxBytes: 4096)
            let v = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !v.isEmpty, v.count <= 80, !v.contains("\n") else { return ExtractorHealth(version: nil, problem: "it did not report a version") }
            return ExtractorHealth(version: v, problem: nil)
        } catch { return ExtractorHealth(version: nil, problem: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    // MARK: Asking for a page's formats

    /// Only an http(s) address with no control characters or spaces; it goes after `--`, so it can never be read as an option.
    static func arguments(for page: URL) throws -> [String] {
        let text = page.absoluteString
        // A sign-in typed into the address would show in the program's argument list: never passed on.
        guard let s = page.scheme?.lowercased(), s == "http" || s == "https", page.host != nil, page.user == nil, page.password == nil, text.count <= 2048,
              !text.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }) else { throw ExtractorFailure.badAddress }
        return ["--dump-single-json", "--no-playlist", "--no-warnings", "--", text]
    }

    /// The complete argument list for one lookup. ONLY the bundled, digest-verified extractor gets the app's options (no config file, no plugin folders except the verified provider, the verified runtime); a program
    /// the person chose themselves gets exactly the page arguments it always got: no plugin folder and no JavaScript runtime is ever handed to an executable the app has not verified.
    static func launchArguments(for page: URL, bundled: Bool, bundledExtras: [String] = BundledExtractor.extraArguments) throws -> [String] {
        let pageArguments = try arguments(for: page)
        return bundled ? bundledExtras + pageArguments : pageArguments
    }

    static func lookup(page: URL, path: String, isPrivate: Bool, allowLocal: Bool = false, timeout: TimeInterval = defaultTimeout, expectedIdentity: String? = nil) async throws -> NormalizedMediaSource {
        guard !isPrivate else { throw ExtractorFailure.unsafeLocation("it is never used in a private tab") }
        var args = try launchArguments(for: page, bundled: false)
        let exe: URL
        var tool: (name: String, version: String) = (URL(fileURLWithPath: path).lastPathComponent, "unknown")
        if let expectedIdentity, expectedIdentity.hasPrefix("bundled:") {
            // The bundled program: trusted because its bytes equal the pinned digest, not because of where it sits (an app folder may be writable by an administrator).
            guard let v = BundledExtractor.verify(), v.identity == expectedIdentity, v.url.path == path else { throw ExtractorFailure.unsafeLocation("the bundled extractor does not match its pinned digest") }
            exe = v.url; args = try launchArguments(for: page, bundled: true); tool = (v.manifest.name, v.manifest.version)
        } else {
            exe = try validateLocation(path)
            if let expectedIdentity, identity(of: exe) != expectedIdentity { throw ExtractorFailure.unsafeLocation("the program changed after you allowed it") }
        }
        let data: Data
        do { data = try await run(exe, arguments: args, timeout: timeout, maxBytes: maxOutput) }
        catch ExtractorFailure.failed(let code, let message) where expectedIdentity?.hasPrefix("bundled:") == true && JSChallengeProviderAdvice.matches(message) {
            throw ExtractorFailure.failed(code, JSChallengeProviderAdvice.marker + message)         // only the bundled extractor is told the built-in solver may be at fault
        }
        return try ExtractorParser.parse(data, asked: page, allowLocal: allowLocal, tool: tool)
    }

    // MARK: Running it

    private actor Slots {
        var running = 0
        let limit: Int
        init(limit: Int) { self.limit = limit }
        func take() -> Bool { guard running < limit else { return false }; running += 1; return true }
        func give() { running = max(0, running - 1) }
    }
    /// Which program a run is for: lookups by the extractor, or media processing (FFmpeg and FFprobe). Each has its own places, so a long join is not refused because two lookups are running, and a long
    /// job does not block every lookup.
    enum Pool { case extractor, processing }
    private static let slots = Slots(limit: maxConcurrent)
    private static let processingSlots = Slots(limit: 3)

    /// The environment the program gets: nothing inherited, and a PATH of the system's own folders only (a wrapper script that needs another folder sets its own PATH, with absolute paths).
    static let childEnvironment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSTemporaryDirectory(), "PYTHONDONTWRITEBYTECODE": "1"]

    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data(); var errData = Data(); var overflow = false; var timedOut = false; var done = false; var cancelled = false
        var pid: pid_t = 0
        var reaped = false
        var stopper: (() -> Void)?
        /// Collects the program's exit once (blocking or not), and says so; nil if it is still running or was already collected.
        func reap(blocking: Bool) -> Int32? {
            lock.lock(); defer { lock.unlock() }
            guard !reaped, pid > 0 else { return nil }
            var st: Int32 = 0
            guard waitpid(pid, &st, blocking ? 0 : WNOHANG) == pid else { return nil }
            reaped = true
            return (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
        }
        /// Ends the program and everything it started: SIGTERM to its whole process group, SIGKILL to the group two seconds later whether or not it listened.
        func stop() {
            lock.lock(); cancelled = true; let p = pid; let custom = stopper; lock.unlock()
            if let custom { custom(); return }
            guard p > 0 else { return }                       // not started yet: the start sees `cancelled` and ends it at once
            kill(-p, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in                // only while the leader has not been reaped: after that its number may belong to something else (the exit path already ended the group)
                lock.lock(); let gone = reaped; lock.unlock()
                if !gone { kill(-p, SIGKILL) }
            }
        }
    }

    /// Starts the program directly (never through a shell) with a fixed small environment, no input, a time limit and an output limit. Unsandboxed it is its own session, so a timeout or cancel ends
    /// the whole tree. In a sandboxed build it is started with NSUserUnixTask, which cannot kill: the pipe is closed instead and the wait is abandoned.
    #if DEBUG
    nonisolated(unsafe) static var trace: ((String) -> Void)?
    #endif
    static func run(_ exe: URL, arguments: [String], timeout: TimeInterval, maxBytes: Int, pool: Pool = .extractor) async throws -> Data {
        let slots = pool == .processing ? processingSlots : Self.slots
        guard await slots.take() else { throw ExtractorFailure.tooManyRunning }
        defer { Task { await slots.give() } }
        let out = Pipe(), err = Pipe()
        let box = Box()
        let resumeOnce: (CheckedContinuation<Int32, Never>, Int32) -> Void = { c, code in box.lock.lock(); let first = !box.done; box.done = true; box.lock.unlock(); if first { c.resume(returning: code) } }
        out.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            box.lock.lock()
            if box.data.count + chunk.count > maxBytes { box.overflow = true; box.lock.unlock(); box.stop(); return }
            box.data.append(chunk); box.lock.unlock()
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            box.lock.lock(); defer { box.lock.unlock() }
            if box.errData.count < 2048 { box.errData.append(chunk.prefix(2048 - box.errData.count)) }
        }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                if isSandboxed {
                    guard let task = try? NSUserUnixTask(url: exe) else { return c.resume(returning: -1) }
                    let inp = Pipe(); try? inp.fileHandleForWriting.close()
                    task.standardOutput = out.fileHandleForWriting; task.standardError = err.fileHandleForWriting; task.standardInput = inp.fileHandleForReading
                    box.lock.lock(); box.stopper = { try? out.fileHandleForReading.close(); resumeOnce(c, -2) }; box.lock.unlock()
                    task.execute(withArguments: arguments) { error in
                        try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                        let code: Int32 = (error as NSError?).flatMap { ($0.domain == NSPOSIXErrorDomain || $0.domain == NSCocoaErrorDomain) ? Int32(truncatingIfNeeded: $0.code) : 1 } ?? 0
                        resumeOnce(c, code)
                    }
                } else {
                    guard let pid = spawn(exe, arguments: arguments, stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor) else { return c.resume(returning: -1) }
                    // Our copies of the write ends are closed so the read ends see the end of the output when the program is gone.
                    try? out.fileHandleForWriting.close(); try? err.fileHandleForWriting.close()
                    #if DEBUG
                    trace?("spawned pid \(pid)")
                    #endif
                    box.lock.lock(); box.pid = pid; let cancelledEarly = box.cancelled; box.lock.unlock()
                    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
                    source.setEventHandler {
                        #if DEBUG
                        trace?("exit event")
                        #endif
                        if let code = box.reap(blocking: true) { source.cancel(); resumeOnce(c, code) } else {
                            #if DEBUG
                            trace?("reap returned nil errno=\(errno)")
                            #endif
                        }
                    }
                    source.resume()
                    // A program that was already gone before the watch began would never signal: look once now.
                    if let code = box.reap(blocking: false) { source.cancel(); resumeOnce(c, code) }
                    if cancelledEarly { box.stop() }
                }
                // The time limit.
                // Holds the box weakly: a sleeping limit must not keep a finished run's output alive for hours.
                Task { [weak box] in try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); guard let box else { return }; box.lock.lock(); let running = !box.done; if running { box.timedOut = true }; box.lock.unlock(); if running { box.stop() } }
            }
        } onCancel: { box.stop() }
        // The program has exited. Anything it left running in its group is ended now, so no stray holder of the pipe can keep the read below waiting.
        box.lock.lock(); let leader = box.pid; box.lock.unlock()
        if leader > 0 { kill(-leader, SIGKILL) }
        out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
        box.lock.lock(); let overflow = box.overflow, timedOut = box.timedOut, errData = box.errData; box.lock.unlock()
        try Task.checkCancellation()
        if timedOut { throw ExtractorFailure.timedOut }
        if overflow { throw ExtractorFailure.tooMuchOutput }
        if let rest = drainWithoutBlocking(out.fileHandleForReading.fileDescriptor, limit: maxBytes), !rest.isEmpty {
            box.lock.lock(); defer { box.lock.unlock() }
            guard box.data.count + rest.count <= maxBytes else { throw ExtractorFailure.tooMuchOutput }
            box.data.append(rest)
        }
        guard status == 0 else {
            if status == -1 { throw ExtractorFailure.notExecutable(exe.lastPathComponent) }
            let reason = String(decoding: errData, as: UTF8.self).split(separator: "\n").last.map { String($0.prefix(700)) } ?? ""
            throw ExtractorFailure.failed(status, DiagnosticRedactor.text(reason, limit: 700) ?? "")
        }
        box.lock.lock(); defer { box.lock.unlock() }
        return box.data
    }

    /// Reads what is already in the pipe and stops when there is nothing more to read right now (never waits).
    private static func drainWithoutBlocking(_ fd: Int32, limit: Int) -> Data? {
        let flags = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var out = Data(); var buf = [UInt8](repeating: 0, count: 65_536)
        while out.count <= limit {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    /// posix_spawn into a new session (so the program is the leader of its own process group), with standard input from /dev/null, output to the given descriptors, and every other descriptor closed.
    private static func spawn(_ exe: URL, arguments: [String], stdout: Int32, stderr: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var attr: posix_spawnattr_t?; posix_spawnattr_init(&attr); defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([exe.path] + arguments).map { strdup($0) } + [nil]
        let envp = childEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exe.path, &actions, &attr, argv, envp)
        return rc == 0 ? pid : nil
    }
}

// MARK: - Reading the answer

/// The expected answer is one JSON object in the shape yt-dlp's `--dump-single-json` uses: `id`, `title`, `thumbnail`, `webpage_url`, and `formats` (each with `url`, `ext`, `vcodec`, `acodec`, `width`,
/// `height`, `fps`, `filesize`, `language`, `protocol`, and optionally `url_expires` in epoch seconds). Anything else is ignored.
enum ExtractorParser {
    static func parse(_ data: Data, asked page: URL, allowLocal: Bool = false, now: Date = Date(), tool: (name: String, version: String) = ("external", "unknown")) throws -> NormalizedMediaSource {
        guard data.count <= ExternalExtractor.maxOutput else { throw ExtractorFailure.tooMuchOutput }
        guard let any = try? JSONSerialization.jsonObject(with: data), let root = any as? [String: Any] else { throw ExtractorFailure.malformed("not a JSON object") }
        guard let id = root["id"] as? String, !id.isEmpty, id.count <= 200 else { throw ExtractorFailure.malformed("no id") }
        let title = String(((root["title"] as? String) ?? id).prefix(200))
        // The answer must be about the page that was asked: its own page address, when given, is on the same site.
        // The answer must say which page it is about, and that page must be on the site that was asked (no answer without it is believed).
        guard let w = (root["webpage_url"] as? String).flatMap({ $0.count <= 2048 ? URL(string: $0) : nil }), let a = w.host?.lowercased(), let b = page.host?.lowercased() else { throw ExtractorFailure.malformed("no webpage_url") }
        guard sameSite(a, b) else { throw ExtractorFailure.wrongVideo }
        // A single video has "formats" at the top. A page with several players comes back as a playlist whose "entries" each have their own formats (this is what the real tool does for a page
        // with HTML5 video). Formats from every entry are gathered, and a format id is made unique by its entry's id when there are several.
        var formats: [[String: Any]] = []
        var skippedEarly: [String] = []
        if let top = root["formats"] as? [[String: Any]] { formats = top }
        else if let entries = root["entries"] as? [[String: Any]] {
            guard entries.count <= 50 else { throw ExtractorFailure.malformed("too many entries") }
            for e in entries {
                if (e["_has_drm"] as? Bool) == true { skippedEarly.append("a protected (DRM) video"); continue }
                let prefix = entries.count > 1 ? (str(e["id"], max: 100) ?? "entry") + ":" : ""
                var list = (e["formats"] as? [[String: Any]]) ?? ((e["url"] as? String) != nil ? [e] : [])
                for i in list.indices { if let fid = str(list[i]["format_id"], max: 64) { list[i]["format_id"] = prefix + fid } else if !prefix.isEmpty { list[i]["format_id"] = prefix + String(i) } }
                formats += list
            }
        } else { throw ExtractorFailure.malformed("no formats") }
        guard formats.count <= ExternalExtractor.maxFormats else { throw ExtractorFailure.malformed("too many formats") }

        var reps: [NormalizedRepresentation] = [], manifests: [(height: Int, url: URL)] = [], skipped: [String] = skippedEarly
        for f in formats {
            guard let text = f["url"] as? String, text.count <= 4096, let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { skipped.append("a format without a web address"); continue }
            // Headers or cookies a format says it needs are not supplied: the browser deliberately shares none.
            if let h = f["http_headers"] as? [String: Any], h.keys.contains(where: { ["cookie", "authorization"].contains($0.lowercased()) }) { skipped.append("a format that needs the sign-in context"); continue }
            let proto = ((f["protocol"] as? String) ?? "https").lowercased()
            let height = num(f["height"], max: 20_000).map(Int.init)
            if proto.hasPrefix("m3u8") { manifests.append((height ?? 0, url)); continue }
            guard proto == "https" || proto == "http" else { skipped.append("a \(proto) format (not a plain file)"); continue }
            // yt-dlp: a codec of "none" means the track is absent; null (or "unknown") means the codec is not known, which for a plain file is a track that is there. So an unknown codec is read from
            // the type: an audio-only ending or an explicit "none" extension means no picture.
            let vraw = str(f["vcodec"])?.lowercased() == "none" ? "none" : str(f["vcodec"]), araw = str(f["acodec"])?.lowercased() == "none" ? "none" : str(f["acodec"])
            let audioEndings: Set<String> = ["m4a", "mp3", "aac", "ogg", "oga", "opus", "flac", "wav", "weba", "mka", "wma", "aiff", "aif", "m4b"]
            let extGuess = (str(f["ext"], max: 8) ?? url.pathExtension).lowercased()
            // `video_ext` is "none" for a sound-only format; `audio_ext` is not used: the tool sets it to "none" whenever the audio codec is merely unknown (a plain mp4 from an HTML5 player), which would
            // wrongly turn every such file into a silent video. Only an explicit "none" codec means no sound.
            var hasV = vraw != "none" && (str(f["video_ext"], max: 8) ?? "").lowercased() != "none"
            var hasA = araw != "none"
            if vraw == nil && araw == nil && audioEndings.contains(extGuess) { hasV = false }
            guard hasV || hasA else { continue }
            let v = vraw ?? "unknown", a = araw ?? "unknown"
            let ext = (str(f["ext"], max: 8) ?? url.pathExtension).lowercased()
            // Any well-formed ending is kept, familiar or not (mka, weba, ogv, flv, a new one): what can be done with it is the planner's decision, with a reason shown. Only something that cannot
            // honestly be a file ending (non-ASCII letters, symbols, a path) is refused, since it would be used in the saved file's name.
            guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { skipped.append("a format with an unreadable type"); continue }
            reps.append(NormalizedRepresentation(role: hasV && hasA ? .muxed : (hasV ? .video : .audio), url: url, container: ext, mime: nil, codecs: [hasV ? v : nil, hasA ? a : nil].compactMap { $0 }.joined(separator: ","),
                                                 width: num(f["width"], max: 20_000).map(Int.init), height: height, frameRate: num(f["fps"], max: 1000), bitrate: num(f["tbr"], max: 1_000_000).map { Int($0 * 1000) },
                                                 language: str(f["language"]), languagePreference: num(f["language_preference"], max: 1000).map(Int.init), channels: num(f["audio_channels"], max: 64).map(Int.init),
                                                 bytes: (num(f["filesize"], max: 1e13) ?? num(f["filesize_approx"], max: 1e13)).map { Int64($0) },
                                                 expires: num(f["url_expires"], max: 4_102_444_800).map { Date(timeIntervalSince1970: $0) }, formatID: str(f["format_id"], max: 64)))
        }
        var seenKeys = Set<String>()
        var seenURLs = Set<String>()
        reps = reps.filter { seenKeys.insert($0.pickKey).inserted && seenURLs.insert($0.url.absoluteString).inserted }          // the same file listed by two entries is one format          // a repeated format id would make two rows indistinguishable: the first stands
        let source: NormalizedMediaSource
        if !reps.isEmpty { source = NormalizedMediaSource(title: title, provider: nil, pageHost: page.host, isPrivate: false, shape: .tracks(reps)) }
        else if let best = manifests.max(by: { $0.height < $1.height }) { source = NormalizedMediaSource(title: title, provider: nil, pageHost: page.host, isPrivate: false, shape: .manifest(best.url)) }
        else { throw ExtractorFailure.noFormats(skipped.isEmpty ? "the extractor returned no downloadable formats." : "the extractor returned only formats this browser cannot fetch (" + Set(skipped).sorted().joined(separator: ", ") + ").") }
        var out = source
        out.origin = .extractor(tool: tool.name, version: tool.version); out.renewal = .rerunExtractor
        try out.validate(now: now, allowLocal: allowLocal)
        return out
    }

    /// Same site: the same host, or one a subdomain of the other (a dot before the shorter name), or two names of one known provider (youtu.be and www.youtube.com). Two unrelated sites that merely
    /// share an ending (evil.co.uk and bbc.co.uk) are different.
    static func sameSite(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // One a subdomain of the other; the shorter name must itself have a dot (a bare "com" is not a site).
        if (a.hasSuffix("." + b) && b.contains(".")) || (b.hasSuffix("." + a) && a.contains(".")) { return true }
        if let pa = ProviderRecognizer.provider(forHost: a), let pb = ProviderRecognizer.provider(forHost: b), pa == pb, pa != .generic { return true }
        return false
    }

    // Numbers from the answer are checked before use: finite, within a sane range, never a boolean. A value outside its range makes the format unusable; it never reaches arithmetic that could trap.
    private static func num(_ v: Any?, max: Double) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite && d >= 0 && d <= max ? d : nil
    }
    private static func str(_ v: Any?, max: Int = 64) -> String? {
        guard let s = v as? String, !s.isEmpty, s.count <= max, !s.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return s
    }
}

#if !os(macOS)
/// The iPhone has no `NSUserUnixTask` (it cannot run scripts outside the app): this stand-in always fails to start, so an extractor program is never run there.
final class NSUserUnixTask {
    var standardOutput: FileHandle?
    var standardError: FileHandle?
    var standardInput: FileHandle?
    init(url: URL) throws { throw CocoaError(.featureUnsupported) }
    func execute(withArguments arguments: [String]?, completionHandler handler: ((Error?) -> Void)? = nil) { handler?(CocoaError(.featureUnsupported)) }
}
#endif
