import Foundation
import JavaScriptCore

// The pieces around the user script runtime that do not depend on WebKit: what a script may be allowed to do, which pages it matches, how its header is read, what it
// reports about itself, and how it is fetched and updated. The WebKit side (injection and the restricted bridge) is in Engines/WebKit/WebKitUserScripts.swift.

/// What a script can be allowed to do beyond changing the page it runs on. Every one is off until the person turns it on for that one script; a script that
/// asks for something it was not given gets nothing, and the attempt shows in its diagnostics. There is deliberately no capability for the Keychain, for files
/// on this device, for the browser's own data or for other tabs.
enum UserScriptCapability: String, CaseIterable, Codable, Identifiable {
    case storage
    case network
    var id: String { rawValue }

    var title: String {
        switch self {
        case .storage: "Keep its own saved values"
        case .network: "Contact other websites"
        }
    }

    var detail: String {
        switch self {
        case .storage: "A small store (up to 100 KB) that only this script can read. It is kept on this device in this profile."
        case .network: "Send requests to the websites the script lists (@connect), without your cookies or sign-ins, and read the answers. Never to addresses inside your home or office network."
        }
    }

    /// The capability a `@grant` line asks for. Grants that only change the page (adding a style, writing to the console, reading the script's own details) need none.
    static func needed(by grant: String) -> UserScriptCapability? {
        switch grant {
        case "GM_getValue", "GM_setValue", "GM_deleteValue", "GM_listValues", "GM.getValue", "GM.setValue", "GM.deleteValue", "GM.listValues": .storage
        case "GM_xmlhttpRequest", "GM.xmlHttpRequest", "GM.xmlhttpRequest": .network
        default: nil
        }
    }

    /// Grants that are understood and need no permission.
    static let free: Set<String> = ["none", "GM_addStyle", "GM.addStyle", "GM_log", "GM_info", "GM.info", "unsafeWindow"]
}

/// Which pages a script matches. Both Chrome's match patterns (`https://*.example.com/path/*`, `<all_urls>`) and Greasemonkey's `@include` globs and `/regex/` forms
/// are turned into one regular expression each, which the page checks against its own address (so a redirect, or a frame with its own address, is judged by where it
/// really is). A bare website name (`example.com`) is the older form this browser saved: that site and its subdomains, any path.
enum UserScriptMatcher {
    private static func escaped(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }

    /// The regular expression for one pattern, or nil when it is not a pattern this browser can honour (other schemes such as file:, or something unreadable).
    static func regexSource(for raw: String) -> String? {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.count <= 500 else { return nil }
        if p == "<all_urls>" || p == "*" { return "^https?://.*$" }
        // A regular expression written as /pattern/ or /pattern/flags (the flags g, i, m, s, u and y are accepted; matching here is always case-insensitive, as for globs).
        if p.count > 2, p.hasPrefix("/"), let close = p.lastIndex(of: "/"), close > p.startIndex {
            let flags = p[p.index(after: close)...]
            if flags.allSatisfy({ "gimsuy".contains($0) }) {
                let body = String(p[p.index(after: p.startIndex)..<close])
                return !body.isEmpty && (try? NSRegularExpression(pattern: body)) != nil ? body : nil
            }
        }
        if let range = p.range(of: "://") {
            let scheme = String(p[..<range.lowerBound]).lowercased()
            let rest = String(p[range.upperBound...])
            let schemeSource: String
            switch scheme {
            case "*", "http*": schemeSource = "https?"
            case "http", "https": schemeSource = scheme
            default: return nil
            }
            let slash = rest.firstIndex(of: "/")
            // An address with nothing after the host means the front page only; it never means every page. (The older glob form that ends in * after the host, such as
            // http://example.com*, still means "anything that starts like this".)
            if slash == nil, rest.hasSuffix("*"), !rest.hasPrefix("*") {
                guard rest.range(of: "[^A-Za-z0-9.*:\\[\\]-]", options: .regularExpression) == nil else { return nil }
                return "^" + (scheme == "*" || scheme == "http*" ? "https?" : scheme) + "://" + escaped(rest).replacingOccurrences(of: "\\*", with: ".*") + "$"
            }
            let host = String(rest[..<(slash ?? rest.endIndex)])
            let path = slash.map { String(rest[$0...]) } ?? "/"
            guard !host.isEmpty, host.range(of: "[^A-Za-z0-9.*:\\[\\]-]", options: .regularExpression) == nil else { return nil }
            var hostSource: String
            if host == "*" { hostSource = "[^/:]+" }
            else if host.hasPrefix("*.") { hostSource = "([^/:]+\\.)?" + escaped(String(host.dropFirst(2))).replacingOccurrences(of: "\\*", with: "[^/:]*") }
            else { hostSource = escaped(host).replacingOccurrences(of: "\\*", with: "[^/:]*") }
            if !host.contains(":") || host.hasSuffix("]") { hostSource += "(:\\d+)?" }
            return "^" + schemeSource + "://" + hostSource + escaped(path).replacingOccurrences(of: "\\*", with: ".*") + "$"
        }
        // The older form: a website name, that site and its subdomains, any path.
        if p.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil, p.contains(".") {
            return "^https?://([^/:]+\\.)?" + escaped(p.lowercased()) + "(:\\d+)?(/.*)?$"
        }
        // A glob over the whole address.
        return "^" + escaped(p).replacingOccurrences(of: "\\*", with: ".*") + "$"
    }

    static func sources(for patterns: [String]) -> [String] { patterns.compactMap(regexSource(for:)) }

    static func matches(_ address: String, patterns: [String]) -> Bool {
        sources(for: patterns).contains { source in
            guard let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) else { return false }
            return regex.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
        }
    }

    /// Whether a script runs on this page: it matches, and nothing excludes it.
    static func runs(_ script: UserScript, on address: String) -> Bool {
        // If an exclude cannot be read, the person's wish to keep the script off some pages cannot be honoured, so it does not run anywhere.
        allReadable(script.excludes) && matches(address, patterns: script.patterns) && !matches(address, patterns: script.excludes)
    }

    /// True when every pattern is one this browser can honour. A pattern that cannot be read is never silently dropped: for an exclude that would widen where a script runs.
    static func allReadable(_ patterns: [String]) -> Bool { patterns.allSatisfy { regexSource(for: $0) != nil } }

    /// True when the patterns cover every website.
    static func coversEverything(_ patterns: [String]) -> Bool {
        patterns.contains { ["<all_urls>", "*", "*://*/*", "http*://*/*", "https://*/*", "http://*/*"].contains($0.trimmingCharacters(in: .whitespaces)) }
    }
}

/// What the header at the top of a script says. Read as data only: nothing here is run.
struct UserScriptMetadata: Equatable {
    var name: String?
    var version = ""
    var description = ""
    var matches: [String] = []
    var excludes: [String] = []
    var runAtStart = false
    var grants: [String] = []
    var connects: [String] = []
    var noFrames = false
    var updateURL = ""
    var downloadURL = ""
    var hasHeader = false

    static func parse(_ text: String) -> UserScriptMetadata {
        var meta = UserScriptMetadata()
        guard let start = text.range(of: "==UserScript=="), let end = text.range(of: "==/UserScript==", range: start.upperBound..<text.endIndex) else { return meta }
        meta.hasHeader = true
        var seen = Set<String>()
        for line in text[start.upperBound..<end.lowerBound].split(whereSeparator: \.isNewline) {
            // A header line is "// @key value". Only the comment marker in front and the spaces around the line are removed: a slash at the END belongs to the value
            // (the end of an address or of a /regular expression/), so it is never trimmed.
            var body = Substring(line)
            while let first = body.first, first == " " || first == "\t" { body = body.dropFirst() }
            var slashes = 0
            while body.first == "/", slashes < 3 { body = body.dropFirst(); slashes += 1 }
            let parts = body.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
            guard let key = parts.first, key.hasPrefix("@") else { continue }
            let value = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            // Directives that can only have one value use the first one, so a second line cannot quietly replace what was shown to the person.
            let single: Set<String> = ["@name", "@version", "@description", "@run-at", "@updateURL", "@downloadURL"]
            if single.contains(key) { guard seen.insert(key).inserted else { continue } }
            switch key {
            case "@name": meta.name = value
            case "@version": meta.version = String(value.prefix(40))
            case "@description": meta.description = String(value.prefix(300))
            case "@match", "@include": if !value.isEmpty, meta.matches.count < 50 { meta.matches.append(value) }
            case "@exclude", "@exclude-match": if !value.isEmpty, meta.excludes.count < 50 { meta.excludes.append(value) }
            case "@run-at": meta.runAtStart = value == "document-start"
            case "@grant": if !value.isEmpty, meta.grants.count < 40, !meta.grants.contains(value) { meta.grants.append(value) }
            case "@connect": if !value.isEmpty, meta.connects.count < 30 { meta.connects.append(value.lowercased()) }
            case "@noframes": meta.noFrames = true
            case "@updateURL": meta.updateURL = value
            case "@downloadURL": meta.downloadURL = value
            default: break
            }
        }
        return meta
    }
}

extension UserScriptMetadata {
    /// Whether a header (such as a .meta.js file) names a newer version than the installed script.
    static func isNewer(_ headerText: String, than script: UserScript) -> Bool { UserScriptUpdate.isNewer(parse(headerText).version, than: script.version) }

    /// Whether the text holds any code after the header. A file such as `name.meta.js` holds the header only: it tells which version is current, and is not a script.
    static func hasBody(_ text: String) -> Bool {
        guard let end = text.range(of: "==/UserScript==") else { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rest = text[end.upperBound...].split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).dropFirst()      // the rest of the closing line is part of the header
        return rest.contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("//")
        }
    }
}

/// What a script says about itself while it runs, kept in memory for this session only. Nothing is written to disk or sent anywhere.
@MainActor final class UserScriptDiagnostics: ObservableObject {
    static let shared = UserScriptDiagnostics()

    struct Entry {
        var runs = 0
        var lastRun: Date?
        var errors = 0
        var lastError: String?
        var denied: [String] = []
        var log: [String] = []
    }

    @Published private(set) var entries: [UUID: Entry] = [:]
    /// Told when a script has failed three times in ten minutes (the browser switches off the ones that came from enhancement packages).
    var onRepeatedFailure: ((UUID) -> Void)?
    private var failureTimes: [UUID: [Date]] = [:]
    static let failureLimit = 3
    static let failureWindow: TimeInterval = 600
    private var windows: [UUID: (start: Date, count: Int)] = [:]

    /// A page that never stops reporting must not make this grow or keep the interface redrawing: sixty reports a minute per script are kept.
    private func allowed(_ id: UUID) -> Bool {
        let now = Date()
        var w = windows[id] ?? (now, 0)
        if now.timeIntervalSince(w.start) > 60 { w = (now, 0) }
        w.count += 1
        windows[id] = w
        return w.count <= 60
    }

    func ran(_ id: UUID) { guard allowed(id) else { return }; var e = entries[id] ?? Entry(); e.runs += 1; e.lastRun = Date(); entries[id] = e }
    func failed(_ id: UUID, _ message: String) {
        guard allowed(id) else { return }
        var e = entries[id] ?? Entry(); e.errors += 1; e.lastError = String(message.prefix(300)); entries[id] = e
        let now = Date()
        var times = (failureTimes[id] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
        times.append(now)
        failureTimes[id] = times
        if times.count >= Self.failureLimit { failureTimes[id] = []; onRepeatedFailure?(id) }
    }

    func resetFailures(_ id: UUID) { failureTimes[id] = [] }
    func denied(_ id: UUID, _ what: String) {
        guard allowed(id) else { return }
        var e = entries[id] ?? Entry()
        let text = String(what.prefix(120))
        if !e.denied.contains(text), e.denied.count < 20 { e.denied.append(text) }
        entries[id] = e
    }
    func log(_ id: UUID, _ message: String) {
        guard allowed(id) else { return }
        var e = entries[id] ?? Entry()
        e.log.append(String(message.prefix(300)))
        if e.log.count > 50 { e.log.removeFirst(e.log.count - 50) }
        entries[id] = e
    }
    func clear(_ id: UUID) { entries[id] = nil; windows[id] = nil; failureTimes[id] = nil }
}

/// Where a script's own saved values live. The engine only sees these two closures, so it never touches the profile's settings directly.
@MainActor final class UserScriptStorage {
    static let maxBytes = 100_000
    var values: (UUID) -> [String: String] = { _ in [:] }
    /// Stores or, with nil, removes a value. False when it would not fit.
    var setValue: (UUID, String, String?) -> Bool = { _, _, _ in false }
}

enum UserScriptSyntax {
    /// The first syntax error in a script, as a line number and a message, found without running it.
    static func firstError(in source: String) -> (line: Int, message: String)? {
        guard let context = JSContext() else { return nil }
        var exception: JSValueRef?
        let wrapped = "(function () {\n" + source + "\n})"
        let ok = wrapped.withCString { body in
            "user-script".withCString { name in
                let script = JSStringCreateWithUTF8CString(body), url = JSStringCreateWithUTF8CString(name)
                defer { JSStringRelease(script); JSStringRelease(url) }
                return JSCheckScriptSyntax(context.jsGlobalContextRef, script, url, 0, &exception)
            }
        }
        if ok { return nil }
        var line = 1, message = "Syntax error"
        if let exception {
            let value = JSValue(jsValueRef: exception, in: context)
            if let l = value?.objectForKeyedSubscript("line")?.toNumber()?.intValue { line = max(1, l - 1) }
            if let m = value?.toString(), !m.isEmpty { message = m }
        }
        return (line, message)
    }
}

/// An update to a script that is installed: what changes, shown before anything is replaced.
struct UserScriptUpdate {
    let newSource: String
    let meta: UserScriptMetadata
    let addedPatterns: [String]
    let addedCapabilities: [UserScriptCapability]
    let addedConnects: [String]
    /// The new version runs in frames the old one did not, or at an earlier moment (before the page's own scripts).
    let widensFrames: Bool
    let runsEarlier: Bool
    let isNewer: Bool

    /// Dotted numbers compared part by part ("1.10" is newer than "1.9"); anything else compares as text.
    static func isNewer(_ new: String, than old: String) -> Bool {
        let a = new.split(separator: ".").map { Int($0) }, b = old.split(separator: ".").map { Int($0) }
        if a.allSatisfy({ $0 != nil }), b.allSatisfy({ $0 != nil }), !a.isEmpty {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i]! : 0, y = i < b.count ? b[i]! : 0
                if x != y { return x > y }
            }
            return false
        }
        return new != old && !new.isEmpty
    }

    static func make(from newSource: String, for script: UserScript) -> UserScriptUpdate {
        let meta = UserScriptMetadata.parse(newSource)
        let patterns = meta.matches
        let oldPatterns = Set(script.patterns)
        let wanted = Set(meta.grants.compactMap { UserScriptCapability.needed(by: $0) })
        let had = Set(script.grants.compactMap { UserScriptCapability.needed(by: $0) })
        return UserScriptUpdate(newSource: newSource, meta: meta,
                                addedPatterns: patterns.filter { !oldPatterns.contains($0) },
                                addedCapabilities: UserScriptCapability.allCases.filter { wanted.contains($0) && !had.contains($0) },
                                addedConnects: meta.connects.filter { !script.connects.contains($0) },
                                widensFrames: !script.allFrames && (meta.hasHeader && !meta.noFrames && !meta.matches.isEmpty),
                                runsEarlier: meta.runAtStart && !script.runAtStart,
                                isNewer: isNewer(meta.version, than: script.version) || (meta.version.isEmpty && newSource != script.source))
    }

    var needsReapproval: Bool { !addedPatterns.isEmpty || !addedCapabilities.isEmpty || !addedConnects.isEmpty || widensFrames || runsEarlier }
}
