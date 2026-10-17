import SwiftUI

/// Searching Settings: every setting that matters, by name and by the words a person would try, and where it lives. A result opens the page that
/// holds it (the iPhone's topic, the Mac's pane).
struct SettingEntry: Identifiable, Equatable {
    let title: String
    let words: String
    /// The iPhone topic that holds it (SettingsView), and the Mac pane (SettingsPanel's raw value).
    let phone: String
    let mac: String
    var id: String { title }
}

enum SettingsIndex {
    static let entries: [SettingEntry] = [
        SettingEntry(title: "Default Browser", words: "make default open links", phone: "general", mac: "general"),
        SettingEntry(title: "Startup and Home Page", words: "on launch homepage restore tabs", phone: "general", mac: "general"),
        SettingEntry(title: "Start Page", words: "favorites greeting new tab background continue", phone: "general", mac: "general"),
        SettingEntry(title: "Downloads", words: "download location folder organize", phone: "general", mac: "general"),
        SettingEntry(title: "Search Engine", words: "brave duckduckgo google bing default search", phone: "general", mac: "search"),
        SettingEntry(title: "Search Suggestions", words: "autocomplete suggestions from search engine typing", phone: "privacy", mac: "search"),
        SettingEntry(title: "Search Shortcuts", words: "keywords yt g custom search", phone: "general", mac: "search"),
        SettingEntry(title: "Profiles", words: "profile switch new work personal", phone: "general", mac: "profiles"),
        SettingEntry(title: "Theme", words: "light dark system appearance mode", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Themes", words: "slime blood moon neon synthwave paper arctic custom photo background colours wallpaper", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Accent Color", words: "tint colour highlight", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Websites Look", words: "website appearance light dark sites", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Dark Pages", words: "darken force dark invert", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Density", words: "compact comfortable spacing size", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Layout", words: "sidebar floating one row classic toolbar position", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Toolbar and Menu", words: "customize buttons dock more menu", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Address Bar Position", words: "top bottom", phone: "interface", mac: "appearance"),
        SettingEntry(title: "Tab Position", words: "vertical horizontal tabs strip side", phone: "interface", mac: "tabs"),
        SettingEntry(title: "Tabs, Groups and Workspaces", words: "tab groups workspace pinned previews overview", phone: "interface", mac: "tabs"),
        SettingEntry(title: "Gestures", words: "swipe pull refresh pinch back forward tab switching", phone: "interface", mac: "advanced"),
        SettingEntry(title: "Page Zoom", words: "text size zoom per site", phone: "interface", mac: "websites"),
        SettingEntry(title: "Protection Level", words: "vayusetu blocker trackers ads shield filter", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "AMP, YouTube Ads and Fingerprint Randomizing", words: "amp pages youtube ads skip mute fingerprint canvas audio randomize javascript off site", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Clear on Quit", words: "history cookies erase when closing", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Lock Sensitive Settings", words: "face id touch id passcode", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Searchable Copy of Pages", words: "search my pages index history text", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Page Memory", words: "reading position forms drafts remember", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Use a Proxy", words: "proxy socks http server address port vpn", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Threat List", words: "phishing malware warning", phone: "privacy", mac: "privacy"),
        SettingEntry(title: "Camera, Microphone and Location", words: "permissions allow expire lapses", phone: "privacy", mac: "websites"),
        SettingEntry(title: "Saved Sign-ins and Passwords", words: "credentials login passwords autofill", phone: "privacy", mac: "websites"),
        SettingEntry(title: "Website Data", words: "cookies storage cache site data", phone: "privacy", mac: "websites"),
        SettingEntry(title: "Link Cleaning", words: "tracking parameters utm", phone: "privacy", mac: "advanced"),
        SettingEntry(title: "Site Icons", words: "favicons download icons", phone: "privacy", mac: "advanced"),
        SettingEntry(title: "iCloud Sync", words: "sync devices passphrase bookmarks tabs", phone: "sync", mac: "general"),
        SettingEntry(title: "Wi-Fi Sync", words: "device link send tab nearby", phone: "sync", mac: "general"),
        SettingEntry(title: "Backup and Restore", words: "export import encrypted file", phone: "sync", mac: "advanced"),
        SettingEntry(title: "Bookmarks Import and Export", words: "html safari chrome", phone: "sync", mac: "advanced"),
        SettingEntry(title: "Recovery", words: "reset profile start over", phone: "sync", mac: "advanced"),
        SettingEntry(title: "Memory Saver", words: "sleep tabs low power memory", phone: "performance", mac: "performance"),
        SettingEntry(title: "Resource Dashboard", words: "memory cpu tabs sleeping", phone: "performance", mac: "performance"),
        SettingEntry(title: "Network Speed", words: "speed pill dynamic island", phone: "performance", mac: "performance"),
        SettingEntry(title: "Health Check", words: "diagnostics problems", phone: "performance", mac: "advanced"),
        SettingEntry(title: "Media Compatibility", words: "drm hls pip airplay video codecs", phone: "performance", mac: "advanced"),
        SettingEntry(title: "Extensions and Scripts", words: "user scripts extensions add-ons", phone: "extensions", mac: "extensions"),
        SettingEntry(title: "Keyboard Shortcuts", words: "keys hotkeys commands", phone: "interface", mac: "shortcuts"),
        SettingEntry(title: "About and Version", words: "build engine licences acknowledgements update", phone: "about", mac: "advanced"),
    ]

    /// Every word typed has to appear in the name or the keywords; names count more, so they come first.
    static func search(_ text: String) -> [SettingEntry] {
        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        return entries.compactMap { entry -> (SettingEntry, Int)? in
            let title = entry.title.lowercased(), all = title + " " + entry.words
            guard tokens.allSatisfy({ all.contains($0) }) else { return nil }
            return (entry, tokens.filter { title.contains($0) }.count)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }
}
