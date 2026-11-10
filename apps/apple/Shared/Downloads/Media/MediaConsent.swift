import Foundation

// Scoped, revocable permission for the optional things the video tools can do. Consent covers what Browser Setu itself does (read more of a page, convert locally, tell an approved service which
// video to look at); it never stands in for a content owner's permission or a site's own access rules. Kept per profile; a private tab never shares anything with an outside service.

enum MediaConsentPurpose: Hashable, Codable, Sendable {
    case pageDiscovery            // watching a page's players and links
    case frameInspection          // looking into embedded frames
    case extendedAnalysis         // extra requests to read a stream's playlist or a page's metadata
    case providerAccount          // using a saved sign-in with a provider
    case localConversion          // converting audio or video on this Mac
    case externalService(String)  // sending a video's page address to one named, approved service
    case externalExtractor(String)  // handing a video's page address to one specific program (its path and fingerprint) the person installed and chose; a changed program asks again

    /// Purposes that hand a page address to anything outside the browser: never in a private tab.
    var neverInPrivate: Bool { switch self { case .externalService, .externalExtractor: true; default: false } }

    var title: String {
        switch self {
        case .pageDiscovery: "Watch pages for videos"
        case .frameInspection: "Look into embedded players"
        case .extendedAnalysis: "Read more of a page to analyze a video"
        case .providerAccount: "Use a saved account with a provider"
        case .localConversion: "Convert audio or video on this Mac"
        case .externalService(let s): "Send a video's web address to \(s)"
        case .externalExtractor: "Look up a video with your external extractor"
        }
    }
    /// What happens, in plain words, shown before consent is asked.
    var explanation: String {
        switch self {
        case .pageDiscovery: "Reads the addresses of a page's video and audio. Nothing is fetched."
        case .frameInspection: "Reads the players inside embedded frames the browser is allowed to look into."
        case .extendedAnalysis: "Makes extra requests to the site (for example its stream playlist) to list the real qualities. No video is downloaded."
        case .providerAccount: "Lets the provider's own account permissions decide what you may download. Your sign-in stays on this Mac and is sent only to that provider."
        case .localConversion: "Works on a file already on this Mac. Nothing leaves it."
        case .externalExtractor(let id): "The program you chose in Settings (\(id.split(separator: "|").first.map(String.init) ?? "?")) is started on this Mac and given the video's web address (nothing else: no cookies, sign-ins or other pages). It is third-party software with your Mac permissions, and it may contact websites itself."
        case .externalService(let s): "\(s) receives the video's page address (never your cookies, sign-ins or other pages) and returns what it offers. The video itself may still come from that service."
        }
    }
}

enum MediaConsentScope: Hashable, Codable, Sendable { case once, site(String), profile }

struct MediaConsentGrant: Hashable, Codable, Sendable { var purpose: MediaConsentPurpose; var scope: MediaConsentScope }

@MainActor
final class MediaConsentStore {
    static let shared = MediaConsentStore(defaults: MediaConsentStore.runDefaults())
    /// Where permissions are kept: the app's own preferences, except in a Debug UI-test run (a throwaway `-UITestRoot`), which uses a preferences suite of its own so a test can never read or write the person's real permissions.
    nonisolated static func runDefaults() -> UserDefaults {
        #if DEBUG
        if let root = UserDefaults.standard.string(forKey: "UITestRoot"), !root.isEmpty, let suite = UserDefaults(suiteName: "bs-ui-consent-" + (root as NSString).lastPathComponent) { return suite }
        #endif
        return .standard
    }
    private let defaults: UserDefaults
    private var onceGrants: Set<MediaConsentGrant> = []
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func key(_ profile: String) -> String { "bs.media.consent.\(profile)" }

    func grants(profile: String) -> [MediaConsentGrant] {
        guard let data = defaults.data(forKey: key(profile)), let list = try? JSONDecoder().decode([MediaConsentGrant].self, from: data) else { return [] }
        return list
    }
    private func save(_ list: [MediaConsentGrant], profile: String) { defaults.set(try? JSONEncoder().encode(list), forKey: key(profile)) }

    /// Whether the purpose is covered for this site. A private tab is never covered for an outside service, whatever was granted.
    func isAllowed(_ purpose: MediaConsentPurpose, host: String?, profile: String, isPrivate: Bool) -> Bool {
        if isPrivate, purpose.neverInPrivate { return false }
        if onceGrants.contains(MediaConsentGrant(purpose: purpose, scope: .once)) { return true }
        return grants(profile: profile).contains { g in
            guard g.purpose == purpose else { return false }
            switch g.scope { case .profile: return true; case .site(let h): return h == host?.lowercased(); case .once: return false }
        }
    }

    func grant(_ purpose: MediaConsentPurpose, scope: MediaConsentScope, profile: String, isPrivate: Bool) {
        // A private tab stores nothing: no grant of any kind is written for it, and an outside service is never covered.
        if isPrivate { return }
        let g = MediaConsentGrant(purpose: purpose, scope: scope)
        if scope == .once { onceGrants.insert(g); return }
        var list = grants(profile: profile); if !list.contains(g) { list.append(g) }
        save(list, profile: profile)
    }

    /// A one-time permission is spent by the action it was for.
    /// Drops a one-time permission whether or not it was used (the sheet it was given in has closed).
    func clearOnce() { onceGrants.removeAll() }
    func consumeOnce(_ purpose: MediaConsentPurpose) { onceGrants.remove(MediaConsentGrant(purpose: purpose, scope: .once)) }

    func revoke(_ purpose: MediaConsentPurpose, profile: String) {
        save(grants(profile: profile).filter { $0.purpose != purpose }, profile: profile)
        onceGrants = onceGrants.filter { $0.purpose != purpose }
    }
    func revokeAll(profile: String) { defaults.removeObject(forKey: key(profile)); onceGrants.removeAll() }
}
