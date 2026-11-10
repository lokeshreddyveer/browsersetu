import Foundation
import CryptoKit
import Darwin

// The extractor program (yt-dlp), installed on request into Browser Setu's own folder (Application Support/BrowserSetu/MediaTools) and never shipped inside the app, described by a pinned manifest (Contents/Resources/BundledTools.json, from ThirdParty/yt-dlp/MANIFEST.json). The app
// trusts it only if the file's SHA-256 equals the manifest's; there is no per-person hash prompt and no executable-path screen. It is started by exactly the same launcher as a person's own
// extractor (own session, fixed environment, output and time limits, never in a private tab), and the same per-site consent applies.

struct BundledToolManifest: Decodable, Equatable {
    var name: String
    var version: String
    var sha256: String
    var sourceURL: String
    /// "onedir": a folder `Helpers/<name>/` holding `executable` and its libraries; pinned by `treeSHA256`.
    var layout: String?
    var executable: String?
    var treeSHA256: String?
    var size: Int64?
    var unpackedBytes: Int64?
    var architectures: [String]?
    /// "adhoc" for the upstream build; "teamID:XXXXXXXXXX" once the release pipeline re-signs the package.
    var signaturePolicy: String?
    /// A package that can really be downloaded: an https address and a pinned digest. A manifest without them (not hosted yet) is shown as "no package", never offered for install.
    var hasPackage: Bool { URL(string: sourceURL)?.scheme == "https" && treeSHA256?.isEmpty == false && !sha256.isEmpty }
    /// Whether THIS build would accept the package's signature. A release build accepts only the publisher's ("teamID:..."); the ad-hoc upstream package is for Debug fixtures. Mirrors `MediaToolsInstall.policyAllowed`
    /// (macOS-only), so the screens can ask the question without importing the installer.
    var signatureAcceptedByThisBuild: Bool {
        let policy = signaturePolicy ?? ""
        if policy.hasPrefix("teamID:") { return true }
        #if DEBUG
        return policy == "adhoc" || policy.isEmpty
        #else
        return false
        #endif
    }
    /// Offered for install only when it can really succeed here: a hosted package AND a signature this build accepts. Anything else is "not available in this build yet": never offered, never started on its own.
    var isInstallable: Bool { hasPackage && signatureAcceptedByThisBuild }
}

/// Where installed tools live and which version is active: no platform-specific code, so shared files can use it.
enum ManagedToolFolder {
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("BrowserSetu/MediaTools", isDirectory: true)
    }
    static func isSafeName(_ s: String) -> Bool { !s.isEmpty && s.count < 64 && !s.contains("/") && !s.contains("..") && !s.hasPrefix(".") && !s.contains("\0") }
    static func activeVersion(root: URL) -> String? {
        guard let d = try? Data(contentsOf: root.appendingPathComponent("state.json")), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let v = o["active"] as? String, isSafeName(v) else { return nil }
        return v
    }
}

/// One managed tool: where it is (in the app, or in its own folder under Application Support), the app's pinned manifest for it, and whether what is on disk is exactly that. yt-dlp and FFmpeg are two
/// instances; each has its own install folder, state and lock. The pin always comes from the app, never from the installed folder.
final class ManagedTool: @unchecked Sendable {
    struct Verified: Equatable {
        var url: URL
        var manifest: BundledToolManifest
        /// The identity a consent grant is bound to: this exact tool at this exact version and digest.
        var identity: String { "bundled:\(manifest.name)|\(manifest.version)|\(manifest.treeSHA256 ?? manifest.sha256)" }
    }

    let resource: String                // the manifest's file name in the app's Resources, without ".json"
    let component: String?              // nil: the install folder is MediaTools itself; otherwise MediaTools/Components/<component>
    init(resource: String, component: String?) { self.resource = resource; self.component = component }

    // Test hooks. They exist ONLY in Debug builds: in a release build the setters do nothing and the getters never see an override, so no preference, environment variable or alternate path can
    // redirect where the tool is read from or which manifest pins it.
    #if DEBUG
    private var folderOverride: URL?
    private var manifestOverride: URL?
    private var managedRootOverride: URL?
    #else
    private var folderOverride: URL? { nil }
    private var manifestOverride: URL? { nil }
    #endif
    private var defaultRoot: URL {
        let base = ManagedToolFolder.defaultRoot()
        return component.map { base.appendingPathComponent("Components/\($0)", isDirectory: true) } ?? base
    }
    var managedRoot: URL {
        get {
            #if DEBUG
            return managedRootOverride ?? defaultRoot
            #else
            return defaultRoot
            #endif
        }
        set {
            #if DEBUG
            managedRootOverride = newValue
            #endif
        }
    }
    var inAppFolder: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tools", isDirectory: true) }
    var helpersFolder: URL? {
        get {
            if let o = folderOverride { return o }
            if let m = manifest(), FileManager.default.fileExists(atPath: inAppFolder.appendingPathComponent(m.name).path) { return inAppFolder }
            guard let v = ManagedToolFolder.activeVersion(root: managedRoot) else { return inAppFolder }
            return managedRoot.appendingPathComponent("versions/\(v)", isDirectory: true)
        }
        set {
            #if DEBUG
            folderOverride = newValue
            #endif
        }
    }
    var manifestURL: URL? {
        get { manifestOverride ?? Bundle.main.url(forResource: resource, withExtension: "json") }
        set {
            #if DEBUG
            manifestOverride = newValue
            #endif
        }
    }
    /// True when the tool ships inside the app (a build made with BUNDLE_MEDIA_TOOLS=1) rather than being installed on request.
    var isInAppBundle: Bool { guard folderOverride == nil, let m = manifest() else { return false }; return FileManager.default.fileExists(atPath: inAppFolder.appendingPathComponent(m.name).path) }
    private var cache: (key: String, ok: Bool)?
    private let cacheLock = NSLock()
    func forgetCache() { cacheLock.lock(); cache = nil; cacheLock.unlock() }

    func manifest() -> BundledToolManifest? {
        guard let url = manifestURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BundledToolManifest.self, from: data)
    }

    private func root(_ m: BundledToolManifest) -> URL? { helpersFolder?.appendingPathComponent(m.name, isDirectory: true) }
    private func executableURL(_ m: BundledToolManifest) -> URL? { root(m)?.appendingPathComponent(m.executable ?? m.name) }

    /// Whether a bundled tool is present at all (cheap: no hashing).
    var isPresent: Bool {
        guard let m = manifest(), let e = executableURL(m) else { return false }
        // An installed copy counts only if it is the pinned version: an older one needs Update, and the screens then offer it instead of failing later.
        if !isInAppBundle, folderOverride == nil, ManagedToolFolder.activeVersion(root: managedRoot) != m.version { return false }
        return FileManager.default.isExecutableFile(atPath: e.path)
    }

    /// The tool, if every file in its folder is exactly the pinned one (same names, bytes, executable bits, links). The check is remembered for the folder's file stamps, so it reads the
    /// files once, not at every lookup; any change to any file makes it read them again and refuse a difference.
    func verify() -> Verified? {
        guard let m = manifest(), let r = root(m), let exe = executableURL(m), FileManager.default.isExecutableFile(atPath: exe.path), let pinned = m.treeSHA256?.lowercased() else { return nil }
        if !isInAppBundle, folderOverride == nil, ManagedToolFolder.activeVersion(root: managedRoot) != m.version { return nil }   // an older install is not the pinned release: update first
        let key = Self.stamp(r) + "|" + pinned
        cacheLock.lock(); let c = cache; cacheLock.unlock()
        if let c, c.key == key { return c.ok ? Verified(url: exe, manifest: m) : nil }
        let ok = Self.treeDigest(of: r) == pinned
        cacheLock.lock(); cache = (key, ok); cacheLock.unlock()
        return ok ? Verified(url: exe, manifest: m) : nil
    }

    /// The same check without blocking the caller: hashing a large tree is done on a background queue and remembered.
    func verifyAsync() async -> Verified? { await Task.detached(priority: .userInitiated) { self.verify() }.value }

    /// A cached answer only: never hashes. nil means "not checked yet" (or failed); callers on the main thread use this and start verifyAsync when it is nil.
    func verifiedIfCached() -> Verified? {
        guard let m = manifest(), let r = root(m), executableURL(m) != nil, let pinned = m.treeSHA256?.lowercased() else { return nil }
        cacheLock.lock(); let c = cache; cacheLock.unlock()
        guard let c, c.ok, c.key == Self.stamp(r) + "|" + pinned else { return nil }
        return verify()
    }

    /// File names, sizes and times plus inode and mode: cheap to read, and any edit, swap or permission change shows.
    static func stamp(_ root: URL) -> String {
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return "" }
        var parts: [String] = []
        for case let rel as String in e {
            var st = stat()
            if lstat(root.appendingPathComponent(rel).path, &st) == 0 {
                // ctime cannot be set from outside (unlike mtime), and inode and mode change when a file is swapped or its permissions are edited.
                parts.append("\(rel):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec):\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec):\(st.st_ino):\(st.st_mode)")
            } else { parts.append("\(rel):gone") }
        }
        return String(Data(parts.sorted().joined(separator: "\n").utf8).sha256Hex.prefix(32))
    }

    /// The same digest as scripts/tree_digest.py: SHA-256 over sorted lines "F\tpath\tsha256\tx|-" (files) and "L\tpath\ttarget" (links); directories are ignored.
    static func treeDigest(of root: URL) -> String? {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root.path) else { return nil }          // yields paths relative to the folder, whatever form (/var or /private/var) the folder was named in
        var lines: [(String, String)] = []
        for case let rel as String in e {
            let u = root.appendingPathComponent(rel)
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true {
                guard let target = try? fm.destinationOfSymbolicLink(atPath: u.path) else { return nil }
                lines.append((rel, "L\t\(rel)\t\(target)"))
            } else if v?.isRegularFile == true {
                guard let h = sha256(of: u) else { return nil }
                lines.append((rel, "F\t\(rel)\t\(h)\t\(fm.isExecutableFile(atPath: u.path) ? "x" : "-")"))
            }
        }
        let sorted = lines.sorted { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }.map(\.1)
        return Data(sorted.joined(separator: "\n").utf8).sha256Hex
    }

    static func sha256(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The extractor (yt-dlp): the same functions as before, now backed by a ManagedTool so FFmpeg can share the code. Every existing caller and test keeps working unchanged.
enum BundledExtractor {
    typealias Verified = ManagedTool.Verified
    static let tool = ManagedTool(resource: "BundledTools", component: nil)

    static var managedRoot: URL { get { tool.managedRoot } set { tool.managedRoot = newValue } }
    static var inAppFolder: URL { tool.inAppFolder }
    static var helpersFolder: URL? { get { tool.helpersFolder } set { tool.helpersFolder = newValue } }
    static var manifestURL: URL? { get { tool.manifestURL } set { tool.manifestURL = newValue } }
    static var isInAppBundle: Bool { tool.isInAppBundle }
    static func forgetCache() { tool.forgetCache() }
    static func manifest() -> BundledToolManifest? { tool.manifest() }
    static var isPresent: Bool { tool.isPresent }
    static func verify() -> Verified? { tool.verify() }
    static func verifyAsync() async -> Verified? { await tool.verifyAsync() }
    static func verifiedIfCached() -> Verified? { tool.verifiedIfCached() }
    static func treeDigest(of root: URL) -> String? { ManagedTool.treeDigest(of: root) }
    static func sha256(of url: URL) -> String? { ManagedTool.sha256(of: url) }

    /// Options added for this tool only: it reads no configuration file, writes no cache, and never updates itself (updates are the app's, explicit and verified).
    /// `--no-js-runtimes` clears yt-dlp's DEFAULT runtime list (it enables "deno" and finds one in PATH, here /usr/bin:/bin): only a runtime Browser Setu verified is ever passed, by absolute path, after this.
    static let baseArguments = ["--ignore-config", "--no-cache-dir", "--no-update", "--no-plugin-dirs", "--no-js-runtimes"]
    /// The one place the options are put together: the base options (which clear every other plugin folder and every default runtime), then the verified provider, then a verified managed runtime.
    static func composeExtraArguments(plugin: [String], runtime: [String]) -> [String] { baseArguments + plugin + runtime }
    /// The base options, plus Browser Setu's own JavaScript challenge provider when the app carries it and it matches its pin (macOS Direct builds only; otherwise exactly the base options).
    static var extraArguments: [String] {
        #if os(macOS)
        // Order of the tiers (see ManagedJSRuntime.swift): the verified native provider, then, only if one is installed and verified, a managed Deno by ABSOLUTE path (never PATH). yt-dlp prefers the native one.
        return composeExtraArguments(plugin: JSChallengeProvider.pluginArguments(), runtime: ManagedDeno.runtimeArguments())
        #else
        return baseArguments
        #endif
    }
}


/// Which extractor is in use: the person's own (when they turned it on and chose a program) or the bundled one. Checking availability costs nothing; resolving the identity hashes the file once.
struct ExtractorChoice: Equatable {
    var path: String
    var identity: String
    var title: String
    var bundled: Bool

    /// Cheap: is any extractor available? (A custom program turned on in Settings, or a bundled one that is allowed.)
    static var isAvailable: Bool {
        if ExtractorSettings.isEnabled, ExtractorSettings.path?.isEmpty == false { return true }
        return ExtractorSettings.useBundled && BundledExtractor.isPresent
    }

    /// The same, with the hashing off the calling (main) thread.
    static func resolveAsync() async throws -> ExtractorChoice {
        if ExtractorSettings.isEnabled, let p = ExtractorSettings.path, !p.isEmpty { return try resolve() }
        guard ExtractorSettings.useBundled else { throw ExtractorFailure.notConfigured }
        _ = await BundledExtractor.verifyAsync()
        return try resolve()
    }

    /// The program that would run, checked now. The person's own choice wins over the bundled one.
    static func resolve() throws -> ExtractorChoice {
        if ExtractorSettings.isEnabled, let p = ExtractorSettings.path, !p.isEmpty {
            let url = try ExternalExtractor.validateLocation(p)
            guard let id = ExternalExtractor.identity(of: url) else { throw ExtractorFailure.notExecutable(url.lastPathComponent) }
            return ExtractorChoice(path: url.path, identity: id, title: url.path, bundled: false)
        }
        guard ExtractorSettings.useBundled else { throw ExtractorFailure.notConfigured }
        guard let v = BundledExtractor.verify() else { throw ExtractorFailure.unsafeLocation(BundledExtractor.isPresent ? "the installed extractor does not match its pinned digest (repair it in Settings › Media)" : "the media tools are not installed (Settings › Media can install them)") }
        return ExtractorChoice(path: v.url.path, identity: v.identity, title: "\(v.manifest.name) \(v.manifest.version)", bundled: true)
    }
}
