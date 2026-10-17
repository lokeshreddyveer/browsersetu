import Foundation

/// What to do with a link, on top of the core's rules. The core lets web addresses through, hands mail, phone, SMS and FaceTime to the system,
/// and blocks everything else. That blocked every link that opens another app, and so every authenticator app (Microsoft, Google, Duo, Okta,
/// Authy, a company's own sign-in app): they use their own address kinds. A link like that in the page you are looking at is now offered to the
/// system, after asking you; the kinds that can run code, read files or reach into the browser stay blocked.
enum NavigationPolicy {
    /// Kinds of address that are never handed to another app and never loaded: they run script, read local files, or belong to the browser.
    static let neverOpened: Set<String> = [
        "javascript", "data", "file", "vbscript", "about", "blob", "view-source", "filesystem", "ftp", "ws", "wss",
        "chrome", "chrome-extension", "moz-extension", "safari-web-extension", "x-apple-data-detectors",
    ]

    @MainActor
    static func decide(url: URL, mainFrame: Bool) -> NavDecision {
        let core = evaluateNavigation(url: url.absoluteString, mainFrame: mainFrame)
        guard core == .deny, mainFrame, let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
              scheme != "http", scheme != "https", !neverOpened.contains(scheme) else { return core }
        return .external
    }
}
