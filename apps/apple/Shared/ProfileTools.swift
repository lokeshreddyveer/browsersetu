import Foundation
import SwiftUI

/// How a profile looks in menus and settings: an icon and a colour. Kept for the whole app, outside any profile, so every profile can show every other one.
struct ProfileStyle: Codable, Equatable {
    var symbol = "person.crop.circle"
    var color: String?

    static let symbols = ["person.crop.circle", "briefcase", "house", "graduationcap", "hammer", "flask", "gamecontroller", "cart", "heart", "star", "airplane", "leaf"]
    var tint: Color? { color.flatMap(GroupColor.init(rawValue:))?.color }
}

/// The app-wide profile facts: looks, preferred profile for a site, and throw-away profiles. UserDefaults, because a profile's own database
/// cannot hold facts about other profiles.
enum ProfileRegistry {
    private static let stylesKey = "profile_styles"
    private static let sitesKey = "site_profiles"
    private static let temporaryKey = "temporary_profiles"
    private static let downloadsKey = "downloads_by_profile"

    static func styles() -> [String: ProfileStyle] {
        (UserDefaults.standard.data(forKey: stylesKey)).flatMap { try? JSONDecoder().decode([String: ProfileStyle].self, from: $0) } ?? [:]
    }
    static func saveStyles(_ value: [String: ProfileStyle]) { UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: stylesKey) }

    static func sites() -> [String: String] { UserDefaults.standard.dictionary(forKey: sitesKey) as? [String: String] ?? [:] }
    static func saveSites(_ value: [String: String]) { UserDefaults.standard.set(value, forKey: sitesKey) }

    static func temporary() -> [String] { UserDefaults.standard.stringArray(forKey: temporaryKey) ?? [] }
    static func saveTemporary(_ value: [String]) { UserDefaults.standard.set(value, forKey: temporaryKey) }

    static func downloadsByProfile() -> Bool { UserDefaults.standard.bool(forKey: downloadsKey) }
    static func saveDownloadsByProfile(_ on: Bool) { UserDefaults.standard.set(on, forKey: downloadsKey) }

    /// The key a site is remembered under: the host without "www.".
    static func siteKey(_ host: String?) -> String? {
        guard var h = host?.lowercased(), !h.isEmpty else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    /// The profile a site is assigned to, matching the site and any of its subdomains.
    static func preferred(forHost host: String?, in sites: [String: String]) -> String? {
        guard let key = siteKey(host) else { return nil }
        var parts = key.split(separator: ".").map(String.init)
        while parts.count >= 2 {
            if let hit = sites[parts.joined(separator: ".")] { return hit }
            parts.removeFirst()
        }
        return nil
    }

    /// A name for a throw-away profile. Letters, numbers and dashes only, so the core accepts it.
    static func temporaryName(token: String = String(UUID().uuidString.prefix(6))) -> String { "Temporary-" + token }
}

@MainActor
extension BrowserModel {
    func profileStyle(_ name: String) -> ProfileStyle { profileStyles[name] ?? ProfileStyle() }

    func setProfileStyle(_ name: String, symbol: String? = nil, color: String?? = nil) {
        var style = profileStyle(name)
        if let symbol { style.symbol = symbol }
        if let color { style.color = color }
        profileStyles[name] = style
        ProfileRegistry.saveStyles(profileStyles)
    }

    // MARK: Opening in another profile

    /// Switches to the profile (this window's tabs are saved and come back when you return) and opens the page there.
    func openInProfile(_ url: URL, profile: String) {
        if profile == profileName { openTab(url: url, isPrivate: false); return }
        guard profiles.contains(profile) else { notice = "There is no profile called “\(profile)”."; return }
        switchProfile(profile, thenOpen: url)
    }

    // MARK: Sites that belong to a profile

    func assignSite(host: String?, to profile: String?) {
        guard let key = ProfileRegistry.siteKey(host) else { return }
        if let profile { siteProfiles[key] = profile } else { siteProfiles[key] = nil }
        ProfileRegistry.saveSites(siteProfiles)
        notice = profile.map { "\(key) will offer to open in “\($0)”." } ?? "\(key) is no longer assigned to a profile."
    }

    /// For an address typed in the bar: if the site is assigned to another profile, asks whether to go there. True when the load was handled here.
    func offerPreferredProfile(for url: URL) -> Bool {
        guard let target = ProfileRegistry.preferred(forHost: url.host, in: siteProfiles), target != profileName, profiles.contains(target),
              !sitePromptDeclined.contains(ProfileRegistry.siteKey(url.host) ?? "") else { return false }
        Task { @MainActor in
            let choice = await Dialogs.choose(title: "Open in “\(target)”?", message: "\(url.host ?? "This site") is set to open in the profile “\(target)”, which keeps its own cookies and sign-ins.",
                                              buttons: ["Switch to \(target)", "Stay Here", "Don't Ask Again This Time"])
            switch choice {
            case 0: openInProfile(url, profile: target)
            case 2:
                sitePromptDeclined.insert(ProfileRegistry.siteKey(url.host) ?? "")
                active?.load(url)
            default: active?.load(url)
            }
        }
        return true
    }

    // MARK: Moving bookmarks between profiles

    /// Adds another profile's bookmarks to this one. Existing bookmarks are kept; the other profile is not changed.
    @discardableResult
    func copyBookmarks(from other: String) -> Int {
        guard other != profileName, let source = try? BrowserCore.open(root: root, profile: other) else { return 0 }
        var added = 0
        for b in (try? source.listBookmarks(query: "")) ?? [] {
            if (try? core.addBookmark(url: b.url, title: b.title, folder: b.folder)) != nil { added += 1 }
        }
        refreshBookmarkState()
        notice = "Copied \(added) bookmark\(added == 1 ? "" : "s") from “\(other)”."
        return added
    }

    // MARK: Temporary profile

    /// A profile that is deleted, with its cookies and everything else, when you leave it or quit.
    func startTemporaryProfile() {
        let name = ProfileRegistry.temporaryName()
        guard createProfile(name) else { notice = "Could not start a temporary profile."; return }
        ProfileRegistry.saveTemporary(ProfileRegistry.temporary() + [name])
        setProfileStyle(name, symbol: "timer", color: "grey")
        switchProfile(name)
    }

    func isTemporaryProfile(_ name: String) -> Bool { ProfileRegistry.temporary().contains(name) }

    /// Removes throw-away profiles that are not the one in use. Called at launch and when leaving one.
    func removeLeftoverTemporaryProfiles() async {
        for name in ProfileRegistry.temporary() where name != profileName {
            await removeProfile(name)
            ProfileRegistry.saveTemporary(ProfileRegistry.temporary().filter { $0 != name })
            profileStyles[name] = nil
            ProfileRegistry.saveStyles(profileStyles)
        }
    }

    /// Where downloads go: inside a folder named for the profile when that is on, so profiles do not share a Downloads folder.
    func updateDownloadFolder() {
        engine.downloads.profileFolder = downloadsByProfile && profileName != "default" ? profileName : nil
    }
}
