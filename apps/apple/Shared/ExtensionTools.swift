import CryptoKit
import Foundation

// MARK: - What an installed extension says about itself

/// The parts of an extension's manifest that matter when several extensions share one browser.
struct ExtensionManifestSummary: Equatable, Identifiable {
    var id: String
    var name: String
    var version: String
    var manifestVersion: Int
    /// Websites its scripts or rules can reach: its host permissions and where its content scripts run.
    var hosts: [String]
    var permissions: [String]
    var injectsCSS: Bool
    var changesRequests: Bool
    /// Keyboard shortcuts it asks for, by command name.
    var shortcuts: [String: String]
    var replacesNewTab: Bool
    var hasBackground: Bool
    var contentScriptCount: Int

    init(id: String, name: String, version: String, manifest: [String: Any]) {
        self.id = id
        self.name = name
        self.version = version
        manifestVersion = manifest["manifest_version"] as? Int ?? 0
        let scripts = manifest["content_scripts"] as? [[String: Any]] ?? []
        var hosts = (manifest["host_permissions"] as? [String]) ?? []
        hosts += scripts.flatMap { ($0["matches"] as? [String]) ?? [] }
        let permissions = (manifest["permissions"] as? [String]) ?? []
        // Manifest V2 listed websites among the permissions.
        hosts += permissions.filter { $0.contains("://") || $0 == "<all_urls>" }
        self.hosts = Array(Set(hosts)).sorted()
        self.permissions = permissions.filter { !$0.contains("://") && $0 != "<all_urls>" }.sorted()
        injectsCSS = scripts.contains { !(($0["css"] as? [String]) ?? []).isEmpty }
        changesRequests = permissions.contains { $0.hasPrefix("declarativeNetRequest") || $0 == "webRequestBlocking" } || manifest["declarative_net_request"] != nil
        var keys: [String: String] = [:]
        for (command, value) in (manifest["commands"] as? [String: Any]) ?? [:] {
            if let suggested = (value as? [String: Any])?["suggested_key"] as? [String: String], let key = suggested["mac"] ?? suggested["default"] { keys[command] = key.lowercased() }
        }
        shortcuts = keys
        replacesNewTab = (manifest["chrome_url_overrides"] as? [String: Any])?["newtab"] != nil
        let background = manifest["background"] as? [String: Any]
        hasBackground = background != nil
        contentScriptCount = scripts.count
    }
}

struct ExtensionConflict: Equatable, Identifiable {
    enum Kind: String { case shortcut, blocking, styling, newTab }
    var kind: Kind
    var message: String
    var extensionIDs: [String]
    var id: String { kind.rawValue + extensionIDs.sorted().joined(separator: ",") + message }
}

enum HostPatterns {
    /// The host part of a match pattern: "*://*.example.com/path" is "*.example.com"; "<all_urls>" is "*".
    static func host(of pattern: String) -> String {
        if pattern == "<all_urls>" { return "*" }
        var rest = Substring(pattern)
        if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
        return String(rest.prefix { $0 != "/" }).lowercased()
    }

    static func overlap(_ a: String, _ b: String) -> Bool {
        let x = host(of: a), y = host(of: b)
        if x == "*" || y == "*" || x == y { return true }
        func covers(_ wild: String, _ other: String) -> Bool {
            guard wild.hasPrefix("*.") else { return false }
            let suffix = String(wild.dropFirst(2))
            return other == suffix || other.hasSuffix("." + suffix) || (other.hasPrefix("*.") && (String(other.dropFirst(2)) == suffix || String(other.dropFirst(2)).hasSuffix("." + suffix)))
        }
        return covers(x, y) || covers(y, x)
    }

    static func overlap(_ a: [String], _ b: [String]) -> Bool { a.contains { x in b.contains { overlap(x, $0) } } }
}

enum ExtensionConflicts {
    /// Pairs of extensions that are likely to get in each other's way, from what their manifests say. It cannot see how they behave; it names what they share.
    static func detect(_ list: [ExtensionManifestSummary]) -> [ExtensionConflict] {
        var out: [ExtensionConflict] = []
        for (index, a) in list.enumerated() {
            for b in list.dropFirst(index + 1) {
                for (command, key) in a.shortcuts where b.shortcuts.values.contains(key) {
                    out.append(ExtensionConflict(kind: .shortcut, message: "“\(a.name)” (\(command)) and “\(b.name)” both want the shortcut \(key).", extensionIDs: [a.id, b.id]))
                }
                if a.changesRequests, b.changesRequests, HostPatterns.overlap(a.hosts, b.hosts) {
                    out.append(ExtensionConflict(kind: .blocking, message: "“\(a.name)” and “\(b.name)” both change or block web requests on some of the same sites. One may undo or duplicate the other.", extensionIDs: [a.id, b.id]))
                }
                if a.injectsCSS, b.injectsCSS, HostPatterns.overlap(a.hosts, b.hosts) {
                    out.append(ExtensionConflict(kind: .styling, message: "“\(a.name)” and “\(b.name)” both restyle some of the same pages, so the page may look wrong.", extensionIDs: [a.id, b.id]))
                }
                if a.replacesNewTab, b.replacesNewTab {
                    out.append(ExtensionConflict(kind: .newTab, message: "“\(a.name)” and “\(b.name)” both replace the new tab page.", extensionIDs: [a.id, b.id]))
                }
            }
        }
        return out
    }
}

// MARK: - Presets, diff, checks

enum ExtensionPermissionPreset: String, CaseIterable, Identifiable {
    case cautious, balanced, open
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var summary: String {
        switch self {
        case .cautious: "Nothing until you press its button, and no access to cookies, your clipboard, other apps or web requests"
        case .balanced: "Only the websites it names, not every website"
        case .open: "Everything it asked for, as when you added it"
        }
    }
    /// The browser features that can reach most: switched off by Cautious.
    static let highRisk: Set<String> = ["cookies", "webRequest", "webRequestBlocking", "clipboardRead", "clipboardWrite", "nativeMessaging", "history", "bookmarks", "downloads", "management", "proxy", "privacy"]

    var siteAccess: ExtensionSiteAccess {
        switch self { case .cautious: .onClick; case .balanced: .specific; case .open: .all }
    }
}

enum ExtensionFileDiff {
    struct Result: Equatable {
        var added: [String]
        var removed: [String]
        var changed: [String]
        var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }

        /// "3 files added, 1 removed, 5 changed" and the first names of each.
        var lines: [String] {
            var out: [String] = []
            func line(_ label: String, _ names: [String]) { if !names.isEmpty { out.append("\(names.count) \(label): " + names.prefix(4).joined(separator: ", ") + (names.count > 4 ? ", …" : "")) } }
            line("added", added); line("removed", removed); line("changed", changed)
            return out
        }
    }

    static func compare(old: [String: String], new: [String: String]) -> Result {
        Result(added: Set(new.keys).subtracting(old.keys).sorted(), removed: Set(old.keys).subtracting(new.keys).sorted(),
               changed: new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.sorted())
    }

    /// Every file's path and SHA-256, for comparing two versions.
    static func digests(of folder: URL) -> [String: String] {
        let base = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var out: [String: String] = [:]
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            out[String(url.standardizedFileURL.path.dropFirst(base.count + 1))] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }
}

/// One thing tried on an extension in a throwaway profile.
struct ExtensionCheck: Equatable, Identifiable {
    enum Status: String { case passed, failed, skipped }
    var name: String
    var status: Status
    var detail: String
    var id: String { name }
}

enum ExtensionScore {
    /// The share of the checks that applied which passed (skipped ones do not count either way); nil when nothing applied.
    static func percent(_ checks: [ExtensionCheck]) -> Int? {
        let applicable = checks.filter { $0.status != .skipped }
        guard !applicable.isEmpty else { return nil }
        return Int((Double(applicable.filter { $0.status == .passed }.count) / Double(applicable.count) * 100).rounded())
    }

    static func label(_ checks: [ExtensionCheck]) -> String {
        guard let value = percent(checks) else { return "Not tested" }
        return value >= 90 ? "Works (\(value)%)" : (value >= 60 ? "Partly works (\(value)%)" : "Mostly fails (\(value)%)")
    }
}

/// Writes a zip. Entries are stored, not compressed: extensions are small and this keeps the writer simple enough to check.
enum ZipWriter {
    static func zip(_ entries: [(path: String, data: Data)]) -> Data {
        // Built one piece at a time: older Swift compilers cannot type-check a long chain of array additions.
        var local = [UInt8](), central = [UInt8]()
        func le16(_ v: Int, to out: inout [UInt8]) { out.append(UInt8(v & 255)); out.append(UInt8((v >> 8) & 255)) }
        func le32(_ v: Int, to out: inout [UInt8]) { le16(v & 0xFFFF, to: &out); le16((v >> 16) & 0xFFFF, to: &out) }
        for entry in entries {
            let name = Array(entry.path.utf8)
            let body = [UInt8](entry.data)
            let crc = Int(ExtensionPackage.crc32(entry.data))
            let offset = local.count
            // Local file header, then the name and the stored bytes.
            local.append(contentsOf: [0x50, 0x4B, 3, 4])
            le16(20, to: &local); le16(0x800, to: &local); le16(0, to: &local); le16(0, to: &local); le16(0x21, to: &local)
            le32(crc, to: &local); le32(body.count, to: &local); le32(body.count, to: &local)
            le16(name.count, to: &local); le16(0, to: &local)
            local.append(contentsOf: name); local.append(contentsOf: body)
            // Central directory entry.
            central.append(contentsOf: [0x50, 0x4B, 1, 2])
            le16(20, to: &central); le16(20, to: &central); le16(0x800, to: &central); le16(0, to: &central); le16(0, to: &central); le16(0x21, to: &central)
            le32(crc, to: &central); le32(body.count, to: &central); le32(body.count, to: &central)
            le16(name.count, to: &central); le16(0, to: &central); le16(0, to: &central); le16(0, to: &central); le16(0, to: &central)
            le32(0, to: &central); le32(offset, to: &central)
            central.append(contentsOf: name)
        }
        var out = local
        out.append(contentsOf: central)
        out.append(contentsOf: [0x50, 0x4B, 5, 6])
        le16(0, to: &out); le16(0, to: &out); le16(entries.count, to: &out); le16(entries.count, to: &out)
        le32(central.count, to: &out); le32(local.count, to: &out); le16(0, to: &out)
        return Data(out)
    }

    /// A folder's files as entries under `prefix`.
    static func entries(of folder: URL, prefix: String) -> [(path: String, data: Data)] {
        let base = folder.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [(String, Data)] = []
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            if let data = try? Data(contentsOf: url) { out.append((prefix + String(url.standardizedFileURL.path.dropFirst(base.count + 1)), data)) }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

/// What the browser can say about an installed extension's cost. WebKit does not report CPU or memory for one extension, so this lists what it does know.
struct ExtensionDiagnostic: Identifiable, Equatable {
    var id: String
    var name: String
    var isLoaded: Bool
    var hasBackground: Bool
    var contentScripts: Int
    var tabsItCanReach: Int
    var bytesOnDisk: Int
    var permissionCount: Int

    var summary: String {
        var parts = [isLoaded ? "running" : "not running", hasBackground ? "has a background part" : "no background part", "\(contentScripts) page script\(contentScripts == 1 ? "" : "s")",
                     "can reach \(tabsItCanReach) open tab\(tabsItCanReach == 1 ? "" : "s")", ByteCountFormatter.string(fromByteCount: Int64(bytesOnDisk), countStyle: .file) + " on disk"]
        if permissionCount > 12 { parts.append("\(permissionCount) permissions") }
        return parts.joined(separator: " · ")
    }
}


/// A website rule the person adds for one extension ("allow it on this site", "block it on that one"), turned into the match pattern WebKit understands.
enum ExtensionSitePattern {
    /// "example.com" becomes "*://example.com/*"; "*.example.com" covers its subdomains too. Addresses with paths, ports, schemes or odd characters are cut down to the host or refused.
    static func pattern(forHost input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.contains("://") { text = URL(string: text)?.host ?? "" }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let colon = text.firstIndex(of: ":") { text = String(text[..<colon]) }
        var wildcard = false
        if text.hasPrefix("*.") { wildcard = true; text.removeFirst(2) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard !text.isEmpty, text.count <= 253, text.contains("."), !text.hasPrefix("."), !text.hasSuffix("."), !text.contains(".."), text.allSatisfy({ allowed.contains($0) }) else { return nil }
        return wildcard ? "*://*.\(text)/*" : "*://\(text)/*"
    }

    /// The host a pattern was made from, for showing it.
    static func host(of pattern: String) -> String { HostPatterns.host(of: pattern) }
}
