import Foundation

/// Sites that have their own iPhone app. Tapping a link to one of them from another site would otherwise hand the page straight
/// to that app; the browser asks first.
enum ExternalApps {
    struct App: Equatable { let name: String; let scheme: String }

    /// What to do with a link to a site that has an app (Settings › Links and Apps).
    enum Mode: String, CaseIterable, Identifiable {
        case ask, app, browser
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ask: "Ask Each Time"
            case .app: "Open in the App"
            case .browser: "Stay in Browser Setu"
            }
        }
    }

    /// The setting and the per-site choices ("app" or "browser", by host), kept up to date by the model; read by the engine.
    static var mode: Mode = .ask
    static var sites: [String: String] = [:]
    /// Called with a host and the answer when the person ticks "always" in the question.
    static var remember: ((String, String) -> Void)?

    /// The app that serves `host`, or nil. Matches the host and its subdomains.
    static func app(forHost host: String?) -> App? {
        guard let host = host?.lowercased() else { return nil }
        for (domain, app) in table where host == domain || host.hasSuffix("." + domain) { return app }
        return nil
    }

    /// The URL schemes the app asks the system about (they are also listed in the app's Info.plist).
    static var schemes: [String] { Array(Set(table.map { $0.1.scheme })).sorted() }

    private static let table: [(String, App)] = [
        ("youtube.com", App(name: "YouTube", scheme: "youtube")),
        ("youtu.be", App(name: "YouTube", scheme: "youtube")),
        ("instagram.com", App(name: "Instagram", scheme: "instagram")),
        ("x.com", App(name: "X", scheme: "twitter")),
        ("twitter.com", App(name: "X", scheme: "twitter")),
        ("open.spotify.com", App(name: "Spotify", scheme: "spotify")),
        ("reddit.com", App(name: "Reddit", scheme: "reddit")),
        ("whatsapp.com", App(name: "WhatsApp", scheme: "whatsapp")),
    ]
}
