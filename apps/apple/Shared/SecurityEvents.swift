import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One thing the browser did or noticed for the sake of safety: a blocked pop-up, a long redirect chain, a risky download, a pause.
struct SecurityEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var kind: String
    var site: String
    var detail: String

    var symbol: String {
        switch kind {
        case "popup": return "rectangle.on.rectangle.slash"
        case "redirect": return "arrow.triangle.branch"
        case "download": return "exclamationmark.arrow.down"
        case "pause": return "pause.circle"
        case "extension": return "puzzlepiece.extension"
        default: return "shield"
        }
    }
}

/// Notices a page that bounces through many different websites before it settles, the shape of most ad and phishing chains.
struct RedirectWatch {
    static let threshold = 4
    private var sites: [String] = []
    private var alerted = false

    /// The site name two labels from the end ("a.b.example.com" gives "example.com").
    static func site(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        return labels.count <= 2 ? labels.joined(separator: ".") : labels.suffix(2).joined(separator: ".")
    }

    mutating func reset() { sites = []; alerted = false }

    /// Records one hop. Returns the sites passed through, once, when the chain reaches `threshold` different sites.
    mutating func hop(to host: String?) -> [String]? {
        guard let host, !host.isEmpty else { return nil }
        let site = Self.site(of: host)
        if sites.last != site { sites.append(site) }
        guard !alerted, Set(sites).count >= Self.threshold else { return nil }
        alerted = true
        return sites
    }
}

/// Launching with every extension off, for when one is suspected of breaking pages.
enum ExtensionSafeMode {
    static let argument = "-BrowserSetuNoExtensions"

    /// Decided once, at launch: the argument was passed, or Option was held while starting. Opening a second window later must not flip it.
    static let launchRequested: Bool = {
        if UserDefaults.standard.bool(forKey: "BrowserSetuNoExtensions") { return true }
        #if os(macOS)
        return NSEvent.modifierFlags.contains(.option)
        #else
        return false
        #endif
    }()

    #if os(macOS)
    /// Starts a second copy with extensions off and quits this one.
    @MainActor static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = [argument, "YES"]
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if error == nil { DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
    }
    #endif
}

/// Plain-language cautions for the permissions an extension asks for.
enum ExtensionRisk {
    /// Cautions for a list of plain-word permission strings, most serious first. Empty when nothing stands out.
    static func warnings(for permissions: [String]) -> [String] {
        let text = permissions.joined(separator: " ").lowercased()
        var out: [String] = []
        if text.contains("all websites") || text.contains("every website") || text.contains("<all_urls>") || text.contains("*://*/*") {
            out.append("Can read and change every website you visit, including banking and email.")
        }
        if text.contains("cookies") { out.append("Can read the cookies that keep you signed in.") }
        if text.contains("history") { out.append("Can read your browsing history.") }
        if text.contains("downloads") { out.append("Can start and manage downloads.") }
        if text.contains("web request") || text.contains("webrequest") || text.contains("declarative") && text.contains("blocking") {
            out.append("Can watch or block network requests.")
        }
        if text.contains("helper apps") || text.contains("native messaging") || text.contains("nativemessaging") { out.append("Can talk to other programs on this computer.") }
        return out
    }
}
