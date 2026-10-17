import Foundation
import SwiftUI

// MARK: - What a site holds

/// Everything the browser knows about one website, in one place.
struct SiteReport: Equatable {
    var host: String
    var firstPartyCookies: Int
    /// Other sites that set cookies while this one was open: name and how many.
    var thirdPartyCookies: [String: Int]
    var storage: [String]
    var permissions: [String]
    var savedSignIns: Int
    var historyEntries: Int
    var settings: [String]

    var isEmpty: Bool { firstPartyCookies == 0 && thirdPartyCookies.isEmpty && storage.isEmpty && permissions.isEmpty && savedSignIns == 0 && historyEntries == 0 && settings.isEmpty }
}

/// What "Forget this site completely" did, so the person can be told.
struct ForgetResult: Equatable {
    var cookiesAndStorage = false
    var history = 0
    var permissions = 0
    var signIns = 0
    var settings = 0
}

/// A rule that clears a site (or a list of sites that belong together) on its own.
struct SiteDeleteRule: Codable, Identifiable, Equatable {
    enum Trigger: String, Codable, CaseIterable, Identifiable {
        case lastTabCloses, atStart
        var id: String { rawValue }
        var title: String { self == .lastTabCloses ? "When its last tab closes" : "Every time Browser Setu starts" }
    }
    enum Scope: String, Codable, CaseIterable, Identifiable {
        case data, everything
        var id: String { rawValue }
        var title: String { self == .data ? "Cookies and stored data" : "Everything (also history, permissions and sign-ins)" }
    }
    var id = UUID()
    /// One site, or several that belong together: "shopping" sites, say.
    var hosts: [String]
    var trigger: Trigger
    var scope: Scope

    func matches(host: String) -> Bool {
        let site = TabOrganizing.siteName(forHost: host)
        return hosts.contains { TabOrganizing.siteName(forHost: $0) == site }
    }
}

/// What a download looks like before it is opened.
struct DownloadFinding: Equatable {
    enum Severity: Int, Comparable { case info = 0, caution = 1, danger = 2; static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue } }
    var severity: Severity
    var text: String
}

enum DownloadScanner {
    static let executableExtensions: Set<String> = ["app", "command", "sh", "bash", "zsh", "csh", "scpt", "scptd", "workflow", "action", "jar", "exe", "msi", "bat", "cmd",
                                                    "ps1", "vbs", "scr", "pkg", "mpkg", "dmg", "terminal", "dylib", "kext", "mobileconfig", "pif", "lnk", "reg", "wflow", "js", "jse", "wsf", "hta"]
    static let documentExtensions: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "jpg", "jpeg", "png", "gif", "mp3", "mp4", "mov", "csv", "heic", "key", "pages", "numbers"]

    /// What the first bytes of a file say it is, when they say anything.
    static func kind(ofHeader bytes: [UInt8]) -> String? {
        func starts(_ s: [UInt8]) -> Bool { bytes.count >= s.count && Array(bytes.prefix(s.count)) == s }
        if starts(Array("%PDF".utf8)) { return "pdf" }
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts(Array("GIF8".utf8)) { return "gif" }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        if starts([0x4D, 0x5A]) { return "exe" }                                // Windows program
        if starts([0xCF, 0xFA, 0xED, 0xFE]) || starts([0xCA, 0xFE, 0xBA, 0xBE]) { return "macho" }
        if starts(Array("#!".utf8)) { return "script" }
        return nil
    }

    /// Everything worth saying about a file, worst first. Reads only the file name, its first bytes and, for a zip, the names inside it.
    static func assess(name: String, header: [UInt8], zipEntries: [String] = []) -> [DownloadFinding] {
        var out: [DownloadFinding] = []
        let parts = name.lowercased().split(separator: ".").map(String.init)
        let ext = parts.count > 1 ? parts.last! : ""
        if parts.count > 2, documentExtensions.contains(parts[parts.count - 2]), executableExtensions.contains(ext) {
            out.append(DownloadFinding(severity: .danger, text: "“\(name)” looks like a document but ends in .\(ext), which is a program. This is a common trick."))
        } else if executableExtensions.contains(ext) {
            out.append(DownloadFinding(severity: .caution, text: "“\(name)” is a kind of file that can run code or change settings. Only open it if you trust where it came from."))
        }
        if let real = kind(ofHeader: header) {
            if documentExtensions.contains(ext), ["exe", "macho", "script"].contains(real) {
                out.append(DownloadFinding(severity: .danger, text: "“\(name)” says it is a .\(ext) file but its contents are a program."))
            } else if documentExtensions.contains(ext), ext != real, ["pdf", "png", "jpg", "gif"].contains(real), ["pdf", "png", "jpg", "jpeg", "gif"].contains(ext), !(ext == "jpeg" && real == "jpg") {
                out.append(DownloadFinding(severity: .caution, text: "“\(name)” ends in .\(ext) but its contents are a \(real.uppercased()) file."))
            }
        }
        let inside = zipEntries.filter { entry in
            let e = (entry as NSString).pathExtension.lowercased()
            return executableExtensions.contains(e) && !entry.hasSuffix("/")
        }
        if !inside.isEmpty {
            out.append(DownloadFinding(severity: .caution, text: "This archive holds \(inside.count) file\(inside.count == 1 ? "" : "s") that can run code, such as “\(inside[0])”."))
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

/// User-agent choices for sites that want a different browser, device or page.
struct UserAgentPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String

    static let all: [UserAgentPreset] = [
        UserAgentPreset(id: "iphone", title: "iPhone Safari", value: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        UserAgentPreset(id: "ipad", title: "iPad Safari", value: "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"),
        UserAgentPreset(id: "mac", title: "Mac Safari", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"),
        UserAgentPreset(id: "chrome", title: "Chrome on Mac", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"),
        UserAgentPreset(id: "firefox", title: "Firefox on Mac", value: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:132.0) Gecko/20100101 Firefox/132.0"),
        UserAgentPreset(id: "android", title: "Chrome on Android", value: "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36"),
    ]
    static func preset(id: String) -> UserAgentPreset? { all.first { $0.id == id } }
}

/// What a page's security looks like from the inside.
struct SecurityReport: Equatable {
    struct Certificate: Equatable { var subject: String; var issuer: String; var expires: Date? }
    var url: String
    var isHTTPS: Bool
    var certificates: [Certificate]
    var mixedContent: [String]
    var insecureForms: [String]
    var redirects: Int
    var transport: String

    /// The things worth noticing, worst first.
    var findings: [DownloadFinding] {
        var out: [DownloadFinding] = []
        if !isHTTPS { out.append(DownloadFinding(severity: .danger, text: "This page is not encrypted. What you type or read can be seen and changed on the way.")) }
        if !mixedContent.isEmpty { out.append(DownloadFinding(severity: .caution, text: "\(mixedContent.count) part\(mixedContent.count == 1 ? "" : "s") of this page load without encryption, such as \(mixedContent[0]).")) }
        if !insecureForms.isEmpty { out.append(DownloadFinding(severity: .danger, text: "A form on this page sends what you type without encryption (\(insecureForms[0])).")) }
        if let soon = certificates.first?.expires, soon.timeIntervalSinceNow < 7 * 86_400 {
            out.append(DownloadFinding(severity: .caution, text: soon < Date() ? "This site's certificate has expired." : "This site's certificate expires within a week."))
        }
        if redirects >= 3 { out.append(DownloadFinding(severity: .caution, text: "You were sent through \(redirects) redirects to get here.")) }
        if out.isEmpty { out.append(DownloadFinding(severity: .info, text: "Nothing wrong was found on this page.")) }
        return out.sorted { $0.severity > $1.severity }
    }
}

// MARK: - The browser's side

extension BrowserModel {
    // MARK: Report and forgetting

    func siteReport(host: String) async -> SiteReport {
        let site = TabOrganizing.siteName(forHost: host)
        let cookies = await engine.cookies(profile: profileName, isPrivate: false)
        var third: [String: Int] = [:]
        var first = 0
        for cookie in cookies {
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            if TabOrganizing.siteName(forHost: domain) == site { first += 1 }
        }
        // Cookies of other sites are listed only for sites that have a tab open, since the store does not say which page set them.
        let openSites = Set(tabs.compactMap { $0.url?.host }.map(TabOrganizing.siteName(forHost:)))
        if openSites.contains(site) {
            for cookie in cookies {
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                let other = TabOrganizing.siteName(forHost: domain)
                if other != site { third[other, default: 0] += 1 }
            }
        }
        let storage = await engine.siteData(profile: profileName).first { TabOrganizing.siteName(forHost: $0.host) == site }?.kinds ?? []
        let permissions = ((try? core.listPermissions()) ?? []).filter { grant in
            guard let h = URL(string: grant.origin)?.host else { return false }
            return TabOrganizing.siteName(forHost: h) == site
        }.map { "\($0.kind) — \($0.decision)".lowercased() }
        let signIns = SignInVault.list(profile: profileName).filter { TabOrganizing.siteName(forHost: $0.host) == site }.count
        let history = ((try? core.searchHistory(query: site, limit: 500)) ?? []).filter { URL(string: $0.url)?.host.map(TabOrganizing.siteName(forHost:)) == site }.count
        var settings: [String] = []
        let key = FaviconStore.key(forHost: host) ?? host
        if siteZoom[key] != nil { settings.append("zoom") }
        if siteStyles[key] != nil { settings.append("page style") }
        if siteNotes[key] != nil { settings.append("notes") }
        if siteAppearance[key] != nil { settings.append("appearance") }
        if siteUserAgents[key] != nil { settings.append("browser identity") }
        if darkSites.contains(key) { settings.append("dark pages") }
        if jsOffSites.contains(key) { settings.append("JavaScript off") }
        if neverSleepSites.contains(key) { settings.append("never sleeps") }
        if fingerprintExceptions.contains(key) { settings.append("not randomized") }
        return SiteReport(host: site, firstPartyCookies: first, thirdPartyCookies: third, storage: storage, permissions: permissions, savedSignIns: signIns, historyEntries: history, settings: settings)
    }

    /// Cookies, storage, cache, history, saved decisions, saved sign-ins, notes and styles for a site: all of it, in every container too.
    @discardableResult
    func forgetSiteCompletely(host: String) async -> ForgetResult {
        let site = TabOrganizing.siteName(forHost: host)
        var result = ForgetResult()
        await removeSiteData(host: site)
        for container in containers { await engine.removeSiteData(host: site, profile: profileName + "#" + container) }
        result.cookiesAndStorage = true
        for item in (try? core.searchHistory(query: site, limit: 5000)) ?? [] where URL(string: item.url)?.host.map(TabOrganizing.siteName(forHost:)) == site {
            if (try? core.deleteHistoryEntry(url: item.url)) != nil { result.history += 1 }
        }
        for grant in (try? core.listPermissions()) ?? [] where URL(string: grant.origin)?.host.map(TabOrganizing.siteName(forHost:)) == site {
            if (try? core.rememberPermission(origin: grant.origin, kind: grant.kind, decision: .prompt)) != nil { result.permissions += 1 }
        }
        for entry in SignInVault.list(profile: profileName) where TabOrganizing.siteName(forHost: entry.host) == site {
            SignInVault.forget(account: entry.account, profile: profileName); result.signIns += 1
        }
        pageIndex?.removeHost(host)
        if site != host { pageIndex?.removeHost(site) }
        let key = FaviconStore.key(forHost: host) ?? host
        var changed = 0
        if siteZoom[key] != nil { var m = siteZoom; m[key] = nil; setSiteZoomMap(m); changed += 1 }
        if siteStyles[key] != nil { var m = siteStyles; m[key] = nil; setSiteStyles(m); changed += 1 }
        if siteNotes[key] != nil { var m = siteNotes; m[key] = nil; setSiteNotes(m); changed += 1 }
        if siteAppearance[key] != nil { setSiteAppearance(host, nil); changed += 1 }
        if siteUserAgents[key] != nil { setSiteUserAgent(host, nil); changed += 1 }
        if darkSites.contains(key) { setDarkSite(host, false); changed += 1 }
        if jsOffSites.contains(key) { setScripts(host: host, allowed: true); changed += 1 }
        if neverSleepSites.contains(key) { setNeverSleeps(host: host, false); changed += 1 }
        if fingerprintExceptions.contains(key) { setFingerprintException(host: host, allowed: false); changed += 1 }
        result.settings = changed
        for tab in tabs where tab.url?.host.map(TabOrganizing.siteName(forHost:)) == site { tab.applySavedZoom(); tab.applySiteStyle() }
        return result
    }

    func forgetActiveSiteCompletely() async {
        guard let host = active?.url?.host else { notice = "Open a page first."; return }
        let result = await forgetSiteCompletely(host: host)
        notice = "Forgot \(TabOrganizing.siteName(forHost: host)): its data, \(result.history) history entr\(result.history == 1 ? "y" : "ies"), \(result.permissions) permission\(result.permissions == 1 ? "" : "s"), \(result.signIns) sign-in\(result.signIns == 1 ? "" : "s")."
        active?.reload()
    }

    // MARK: Automatic deletion

    func setSiteDeleteRules(_ rules: [SiteDeleteRule]) {
        siteDeleteRules = rules
        saveSetting("site_delete_rules", encodedMap(["list": rules]))
    }

    func addSiteDeleteRule(hosts: [String], trigger: SiteDeleteRule.Trigger, scope: SiteDeleteRule.Scope) {
        let clean = hosts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && !$0.contains("/") && !$0.contains(" ") }
        guard !clean.isEmpty, siteDeleteRules.count < 50 else { return }
        setSiteDeleteRules(siteDeleteRules + [SiteDeleteRule(hosts: clean, trigger: trigger, scope: scope)])
    }

    private func apply(_ rule: SiteDeleteRule, to host: String) async {
        if rule.scope == .everything { await forgetSiteCompletely(host: host) }
        else {
            let site = TabOrganizing.siteName(forHost: host)
            await removeSiteData(host: site)
            for container in containers { await engine.removeSiteData(host: site, profile: profileName + "#" + container) }
        }
    }

    /// Called when a tab has just closed: a site whose last tab it was is cleared by the rules that say so.
    func siteTabClosed(host: String?) {
        guard let host, !siteDeleteRules.isEmpty else { return }
        let site = TabOrganizing.siteName(forHost: host)
        guard !tabs.contains(where: { $0.url?.host.map(TabOrganizing.siteName(forHost:)) == site }) else { return }
        let rules = siteDeleteRules.filter { $0.trigger == .lastTabCloses && $0.matches(host: host) }
        guard !rules.isEmpty else { return }
        Task { for rule in rules { await apply(rule, to: host) } }
    }

    /// At start: the rules that say "every time" run for each of their sites.
    func runStartupDeleteRules() async {
        for rule in siteDeleteRules where rule.trigger == .atStart {
            for host in rule.hosts { await apply(rule, to: host) }
        }
    }

    // MARK: Temporary permissions

    private func tempKey(_ origin: String, _ kind: PermissionType) -> String { "\(origin)|\(kind)" }

    /// Allowed until a moment (an hour from now) or until the app next starts (-1).
    func noteTemporaryPermission(origin: String, kinds: [PermissionType], until: Double) {
        var map = tempPermissions
        for kind in kinds { map[tempKey(origin, kind)] = until }
        tempPermissions = map
        saveSetting("temp_permissions", encodedMap(map))
    }

    /// Turns every temporary "Allow" that has run out back into "Ask". `atStart` also ends the ones meant for one run of the app.
    @discardableResult
    func expireTemporaryPermissions(now: Date = Date(), atStart: Bool = false) -> Int {
        guard !tempPermissions.isEmpty, let grants = try? core.listPermissions() else { return 0 }
        var map = tempPermissions
        var ended = 0
        for grant in grants where grant.decision == .allow {
            let key = tempKey(grant.origin, grant.kind)
            guard let until = map[key] else { continue }
            let over = until < 0 ? atStart : until <= now.timeIntervalSince1970
            if over {
                try? core.rememberPermission(origin: grant.origin, kind: grant.kind, decision: .prompt)
                map[key] = nil; ended += 1
            }
        }
        // A saved decision that was already changed some other way is no longer temporary.
        let live = Set(grants.filter { $0.decision == .allow }.map { tempKey($0.origin, $0.kind) })
        for key in map.keys where !live.contains(key) { map[key] = nil }
        if map != tempPermissions { tempPermissions = map; saveSetting("temp_permissions", encodedMap(map)) }
        return ended
    }

    // MARK: Browser identity and WebRTC

    func siteUserAgent(forHost host: String?) -> String? {
        FaviconStore.key(forHost: host).flatMap { siteUserAgents[$0] }.flatMap { UserAgentPreset.preset(id: $0)?.value }
    }

    func setSiteUserAgent(_ host: String?, _ presetID: String?) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if let presetID, UserAgentPreset.preset(id: presetID) != nil { siteUserAgents[key] = presetID } else { siteUserAgents[key] = nil }
        saveSetting("site_user_agents", encodedMap(siteUserAgents))
        for tab in tabs where FaviconStore.key(forHost: tab.url?.host) == key { tab.engine.setUserAgent(siteUserAgent(forHost: tab.url?.host)); if !tab.isBlank { tab.reload() } }
    }

    func pushWebPolicy() {
        engine.setWebPolicy(WebPolicy(blockWebRTC: blockWebRTC, exceptions: webRTCExceptions, randomizeFingerprint: randomizeFingerprint,
                                      fingerprintExceptions: fingerprintExceptions, deAMP: deAMP, blockVideoAds: blockVideoAds))
    }

    func setWebRTCException(host: String?, allowed: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if allowed { webRTCExceptions.insert(key) } else { webRTCExceptions.remove(key) }
        saveSetting("webrtc_exceptions", encodedMap(["list": Array(webRTCExceptions).sorted()]))
        pushWebPolicy()
    }
}
