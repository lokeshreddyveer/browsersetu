import Foundation

/// URL match patterns for download extensions, in the shape browsers use: `scheme://host/path`, `*` for any scheme (http and https only), `*.example.com` for a domain and its subdomains,
/// and `*` inside a path for anything. Matching is done by code, not by a regular expression, so no pattern can take unbounded time.
struct ExtensionMatchPattern: Equatable, Hashable, Sendable {
    var scheme: String          // "http", "https" or "*"
    var host: String            // lowercase; "*", "*.example.com" or "example.com"
    var path: String            // starts with "/"; "*" is a wildcard

    var text: String { "\(scheme)://\(host)\(path)" }

    static let maxLength = 300

    static func parse(_ text: String) -> ExtensionMatchPattern? {
        if text == "<all_urls>" { return ExtensionMatchPattern(scheme: "*", host: "*", path: "/*") }
        guard text.utf8.count <= maxLength, text.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F }), let range = text.range(of: "://") else { return nil }
        let scheme = String(text[..<range.lowerBound]).lowercased()
        guard ["http", "https", "*"].contains(scheme) else { return nil }
        let rest = text[range.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let host = String(rest[..<slash]).lowercased(), path = String(rest[slash...])
        guard validHost(host) else { return nil }
        return ExtensionMatchPattern(scheme: scheme, host: host, path: path)
    }

    private static func validHost(_ h: String) -> Bool {
        if h == "*" { return true }
        let body = h.hasPrefix("*.") ? String(h.dropFirst(2)) : h
        guard !body.isEmpty, body.count <= 253, !body.contains("*"), !body.hasPrefix("."), !body.hasSuffix("."), !body.contains("..") else { return false }
        return body.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    func matches(_ url: URL) -> Bool {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https", scheme == "*" || scheme == s, let h = url.host?.lowercased() else { return false }
        guard hostMatches(h) else { return false }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let target = (comps?.percentEncodedPath.isEmpty == false ? comps!.percentEncodedPath : "/") + (comps?.percentEncodedQuery.map { "?" + $0 } ?? "")
        return Self.glob(path, target)
    }

    func hostMatches(_ h: String) -> Bool {
        if host == "*" { return true }
        if host.hasPrefix("*.") { let base = String(host.dropFirst(2)); return h == base || h.hasSuffix("." + base) }
        return h == host
    }

    /// Whether everything `other` matches is also matched by this pattern (used to check that a rule stays inside the access that was granted).
    func covers(_ other: ExtensionMatchPattern) -> Bool {
        guard scheme == "*" || scheme == other.scheme else { return false }
        let hostOK: Bool
        if host == "*" { hostOK = true }
        else if host.hasPrefix("*.") {
            let base = String(host.dropFirst(2)), o = other.host.hasPrefix("*.") ? String(other.host.dropFirst(2)) : other.host
            hostOK = other.host != "*" && (o == base || o.hasSuffix("." + base))
        } else { hostOK = host == other.host }
        guard hostOK else { return false }
        if path == "/*" || path == other.path { return true }
        if path.hasSuffix("*"), !path.dropLast().contains("*") { return other.path.hasPrefix(String(path.dropLast())) }
        return false
    }

    /// `*` matches any run of characters; everything else must match exactly. Linear in practice, and no backtracking blow-up.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.utf8), t = Array(text.utf8)
        var pi = 0, ti = 0, star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == UInt8(ascii: "*") { star = pi; mark = ti; pi += 1 }
            else if pi < p.count, p[pi] == t[ti] { pi += 1; ti += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; ti = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == UInt8(ascii: "*") { pi += 1 }
        return pi == p.count
    }
}

/// The versioned description of a download extension. Parsing checks everything; nothing in a manifest is trusted until it has been through `parse`.
struct ExtensionManifest: Equatable, Sendable {
    static let supportedManifestVersions = [1]
    static let supportedAPIVersions = [1]
    static let maxBytes = 64 * 1024

    enum Capability: String, CaseIterable, Codable, Sendable {
        case resolve        // propose a different address (and related resources) for an address the person gave
        case filename       // suggest a name for a file
        case category       // suggest a kind of file (Documents, Video…)

        var summary: String {
            switch self {
            case .resolve: "Suggest download addresses for pages you give it"
            case .filename: "Suggest file names"
            case .category: "Suggest the kind of a file"
            }
        }
    }

    struct Setting: Equatable, Sendable {
        enum Kind: String, Sendable { case string, number, boolean }
        var name: String
        var title: String
        var kind: Kind
        var defaultValue: String
        var options: [String]
    }

    var manifestVersion: Int
    var id: String
    var name: String
    var version: String
    var description: String
    var authorName: String
    var apiVersion: Int
    var entry: String
    var capabilities: Set<Capability>
    var hostPermissions: [ExtensionMatchPattern]
    var optionalHostPermissions: [ExtensionMatchPattern]
    var proposeHosts: [ExtensionMatchPattern]
    var storageQuota: Int
    var settings: [Setting]
    var updateURL: URL?
    var entrySHA256: String?

    enum Failure: Error, Equatable, LocalizedError {
        case tooLarge, notJSON, missing(String), invalid(String), unsupportedManifest(Int), unsupportedAPI(Int), unsupportedRuntime(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge: "The extension's manifest is larger than is allowed."
            case .notJSON: "The extension's manifest.json is not valid JSON."
            case .missing(let k): "The manifest does not say its “\(k)”."
            case .invalid(let why): "The manifest is not valid: \(why)."
            case .unsupportedManifest(let v): "This extension uses manifest version \(v), which this version of Browser Setu cannot read."
            case .unsupportedAPI(let v): "This extension needs extension API version \(v), which this version of Browser Setu does not have."
            case .unsupportedRuntime(let r): "Extensions that run \(r) code are not supported. Download extensions here are rule files, which cannot run code."
            }
        }
    }

    static func parse(_ data: Data) throws -> ExtensionManifest {
        guard data.count <= maxBytes else { throw Failure.tooLarge }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.notJSON }
        func string(_ k: String, max: Int, required: Bool = true) throws -> String {
            guard let v = root[k] else { if required { throw Failure.missing(k) }; return "" }
            guard let s = v as? String, s.count <= max, !ExtensionText.hasHiddenControls(s) else { throw Failure.invalid("“\(k)” is not usable text") }
            return s
        }
        guard let mv = root["manifestVersion"] as? Int else { throw Failure.missing("manifestVersion") }
        guard supportedManifestVersions.contains(mv) else { throw Failure.unsupportedManifest(mv) }
        guard let api = root["apiVersion"] as? Int else { throw Failure.missing("apiVersion") }
        guard supportedAPIVersions.contains(api) else { throw Failure.unsupportedAPI(api) }
        let runtime = (root["runtime"] as? String) ?? "declarative"
        guard runtime == "declarative" else { throw Failure.unsupportedRuntime(runtime) }

        let id = try string("id", max: 64)
        guard id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+){1,7}\z"#, options: .regularExpression) != nil, id.count >= 3 else { throw Failure.invalid("the id must be lowercase words joined by dots or dashes, like com.example.files") }
        let name = try string("name", max: 60)
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw Failure.invalid("the name is empty") }
        let version = try string("version", max: 20)
        guard version.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,4}\z"#, options: .regularExpression) != nil else { throw Failure.invalid("the version must look like 1.2.3") }
        let entry = try string("entry", max: 100)
        guard isSafeRelativePath(entry), entry.lowercased().hasSuffix(".json") else { throw Failure.invalid("the entry must be a .json file inside the package") }

        var author = ""
        if let a = root["author"] as? [String: Any] { author = (a["name"] as? String).map { String($0.prefix(60)) } ?? "" } else if let a = root["author"] as? String { author = String(a.prefix(60)) }

        guard let caps = root["capabilities"] as? [String], !caps.isEmpty, caps.count <= Capability.allCases.count else { throw Failure.missing("capabilities") }
        let capabilities = try Set(caps.map { c -> Capability in guard let k = Capability(rawValue: c) else { throw Failure.invalid("“\(c)” is not a capability this version knows") }; return k })

        func patterns(_ k: String, max: Int) throws -> [ExtensionMatchPattern] {
            guard let list = root[k] else { return [] }
            guard let texts = list as? [String], texts.count <= max else { throw Failure.invalid("“\(k)” is not a short list of patterns") }
            return try texts.map { guard let p = ExtensionMatchPattern.parse($0) else { throw Failure.invalid("“\($0.prefix(60))” is not a valid URL pattern") }; return p }
        }
        let hosts = try patterns("hostPermissions", max: 20), optional = try patterns("optionalHostPermissions", max: 20), propose = try patterns("proposeHosts", max: 10)
        if capabilities.contains(.resolve) {
            guard !propose.isEmpty else { throw Failure.invalid("an extension that suggests addresses must list the hosts it may suggest (proposeHosts)") }
            for p in propose {
                // The addresses an extension can suggest are fixed by its manifest: named public hosts, never "any host", never a local or numeric address.
                guard p.host != "*", !HostLiteral.isNumeric(p.host), !HostLiteral.isRebindingHelper(p.host), !HTTPRequestPolicy.classify(host: p.host.hasPrefix("*.") ? String(p.host.dropFirst(2)) : p.host).isInternal,
                      (p.host.hasPrefix("*.") ? String(p.host.dropFirst(2)) : p.host).contains(".") else { throw Failure.invalid("“\(p.text.prefix(60))” cannot be a host an extension suggests") }
            }
        }
        var quota = 8192
        if let s = root["storage"] as? [String: Any], let q = s["quotaBytes"] as? Int { guard (0...65536).contains(q) else { throw Failure.invalid("the storage quota must be between 0 and 65536 bytes") }; quota = q }

        var settings: [Setting] = []
        if let list = root["settings"] {
            guard let items = list as? [[String: Any]], items.count <= 20 else { throw Failure.invalid("“settings” is not a short list") }
            var seen = Set<String>()
            for item in items {
                guard let n = item["name"] as? String, n.range(of: #"^[A-Za-z][A-Za-z0-9_]{0,31}\z"#, options: .regularExpression) != nil, seen.insert(n).inserted else { throw Failure.invalid("a setting has a missing, repeated or unusable name") }
                let title = String(((item["title"] as? String) ?? n).prefix(60))
                guard let kind = Setting.Kind(rawValue: (item["type"] as? String) ?? "string") else { throw Failure.invalid("setting “\(n)” has an unknown type") }
                var def = ""
                switch kind {
                case .string: def = String(((item["default"] as? String) ?? "").prefix(256))
                case .number:
                    if let d = item["default"] { guard let num = d as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() else { throw Failure.invalid("setting “\(n)” has a default that is not a number") }; def = String(describing: num) } else { def = "0" }
                case .boolean: def = ((item["default"] as? Bool) ?? false) ? "true" : "false"
                }
                let options = ((item["options"] as? [String]) ?? []).prefix(20).map { String($0.prefix(60)) }
                settings.append(Setting(name: n, title: title, kind: kind, defaultValue: def, options: Array(options)))
            }
        }
        var update: URL?
        if let u = (root["update"] as? [String: Any])?["url"] as? String {
            guard u.utf8.count <= 300, let url = URL(string: u), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { throw Failure.invalid("the update address must be an https address") }
            update = url
        }
        var sha: String?
        if let i = root["integrity"] as? [String: Any], let h = i["entrySHA256"] as? String {
            guard let d = DownloadIntegrityCheck.normalizedDigest(h) else { throw Failure.invalid("integrity.entrySHA256 is not a SHA-256") }
            sha = d
        }
        return ExtensionManifest(manifestVersion: mv, id: id, name: name, version: version, description: try string("description", max: 300, required: false), authorName: author, apiVersion: api,
                                 entry: entry, capabilities: capabilities, hostPermissions: hosts, optionalHostPermissions: optional, proposeHosts: propose, storageQuota: quota, settings: settings,
                                 updateURL: update, entrySHA256: sha)
    }

    /// A path inside the package: relative, no "..", no hidden parts, no separators that mean something else.
    static func isSafeRelativePath(_ p: String) -> Bool {
        guard !p.isEmpty, p.utf8.count <= 100, !p.hasPrefix("/"), !p.contains("\\"), !p.contains(":"), !p.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return false }
        return p.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    /// What the person is told they are agreeing to, one plain line each.
    var permissionLines: [String] {
        var lines = capabilities.sorted { $0.rawValue < $1.rawValue }.map(\.summary)
        lines += hostPermissions.map { "Read addresses matching \($0.text)" }
        lines += optionalHostPermissions.map { "Optionally, read addresses matching \($0.text)" }
        lines += proposeHosts.map { "May suggest downloads from \($0.host)" }
        return lines
    }

    var isBroad: Bool { hostPermissions.contains { $0.host == "*" } }
}

enum HostLiteral {
    /// A host that is a number in any spelling the system resolver accepts (dotted, short, hexadecimal, octal, a single integer), or an IPv6 literal: extensions may not name hosts by number.
    static func isNumeric(_ host: String) -> Bool {
        let h = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
        guard !h.isEmpty else { return false }
        if h.contains(":") || h.contains("[") { return true }
        var a = in_addr()
        if inet_aton(h, &a) == 1 { return true }
        let last = h.split(separator: ".").last.map(String.init) ?? h
        return last.allSatisfy(\.isNumber) || h.split(separator: ".").contains { $0.lowercased().hasPrefix("0x") }
    }

    /// Public names that exist to resolve to whatever address is written in them (so "a name" can still mean 127.0.0.1).
    private static let rebinding = ["nip.io", "sslip.io", "xip.io", "localtest.me", "lvh.me", "localhost.run", "traefik.me", "local.gd"]
    static func isRebindingHelper(_ host: String) -> Bool {
        let h = (host.hasPrefix("*.") ? String(host.dropFirst(2)) : host).lowercased()
        return rebinding.contains { h == $0 || h.hasSuffix("." + $0) }
    }
}

enum ExtensionText {
    /// Control characters, the C1 range, and the characters that reorder text on screen (so a name cannot be made to read as something else).
    static func hasHiddenControls(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) || $0.value == 0x200E || $0.value == 0x200F || $0.value == 0x061C }
    }
    static func clean(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !hasHiddenControls(String($0)) })) }
}
