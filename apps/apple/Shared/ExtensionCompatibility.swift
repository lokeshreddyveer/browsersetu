import Foundation

/// Tells the user, before an extension is installed, which of the things it asks for Apple's extension support does not offer. It reads only the
/// extension's manifest. It cannot promise an extension works (that depends on how it uses what WebKit gives it); it names what is known to be missing.
enum ExtensionCompatibility {
    /// The permissions Apple's web extension support documents. Anything else an extension asks for is not available to it here.
    static let supported: Set<String> = [
        "activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest", "declarativeNetRequestFeedback",
        "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "notifications", "scripting", "storage", "tabs",
        "unlimitedStorage", "webNavigation", "webRequest",
    ]

    /// Permissions with no use on their own (they only enable a page the extension already has).
    private static let harmless: Set<String> = ["background", "geolocation", "clipboardRead", "declarativeNetRequestFeedback"]

    private static let words: [String: String] = [
        "downloads": "managing downloads", "history": "reading or changing your history", "bookmarks": "reading or changing your bookmarks",
        "identity": "signing in with a Google account", "sidePanel": "the side panel", "offscreen": "hidden background pages",
        "proxy": "changing proxy settings", "management": "managing other extensions", "debugger": "debugging pages",
        "declarativeContent": "page-based actions", "topSites": "most visited sites", "tabGroups": "tab groups",
        "browsingData": "clearing browsing data", "privacy": "browser privacy settings", "webRequestBlocking": "blocking requests as they happen",
        "contentSettings": "per-site content settings", "pageCapture": "saving pages", "tabCapture": "capturing tab audio or video",
        "desktopCapture": "capturing the screen", "readingList": "the reading list", "search": "the search engine setting",
        "sessions": "recently closed tabs", "system.cpu": "reading CPU details", "system.memory": "reading memory details",
        "system.storage": "reading storage details", "tts": "speaking text", "fontSettings": "font settings", "gcm": "push messages",
    ]

    /// Whether this build can start Apple's helper programs for extensions (the direct-download build only; the sandboxed one cannot).
    static var nativeMessagingAvailable: Bool {
        #if DIRECT_DISTRIBUTION
        true
        #else
        false
        #endif
    }

    /// Plain-words notes for a folder holding an extension. Empty when nothing it asks for is missing.
    static func notes(inExtensionAt folder: URL) -> [String] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return notes(forManifest: manifest)
    }

    static func manifestVersion(inExtensionAt folder: URL) -> Int {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return manifest["manifest_version"] as? Int ?? 0
    }

    static func notes(forManifest manifest: [String: Any]) -> [String] {
        let asked = ((manifest["permissions"] as? [String]) ?? []) + ((manifest["optional_permissions"] as? [String]) ?? [])
        var missing: [String] = []
        for permission in asked where !supported.contains(permission) && !harmless.contains(permission) && !permission.contains("://") && permission != "<all_urls>" {
            let note = words[permission].map { "Needs \($0) (“\(permission)”), which Safari-style extension support does not offer." }
                ?? "Asks for “\(permission)”, which Safari-style extension support does not list."
            if !missing.contains(note) { missing.append(note) }
        }
        if !nativeMessagingAvailable, asked.contains("nativeMessaging") {
            missing.append("Needs to talk to another app on this Mac (a password manager's helper, for example). This version of Browser Setu cannot; the direct-download build can for Apple's own helpers.")
        }
        if (manifest["manifest_version"] as? Int) == 2 {
            missing.append("Uses the older Manifest V2 format, which Chrome is retiring. Features that rely on V2-only behaviour, such as blocking web requests as they happen, have no equivalent here.")
        }
        if (manifest["manifest_version"] as? Int) == 2, (manifest["background"] as? [String: Any])?["persistent"] as? Bool == true {
            missing.append("Uses a background page that stays running. WebKit may stop it when idle, so features that depend on it can pause.")
        }
        return missing
    }
}
