import Foundation
import CryptoKit

// DX-09: websites and what they actually allow. Nothing here downloads anything. This file decides which site a page or frame belongs to, what that site permits (separately: seeing
// the media, playing it, downloading it with a documented authorization, exporting one's own data), turns a documented API answer into a described source, and checks that a renewed
// source is the same media before the existing download engines are allowed to use it. The transfer itself is always the existing HTTP or HLS/DASH engine.

enum MediaProviderID: String, Codable, CaseIterable, Sendable {
    case youtube, instagram, facebook, tiktok, x, reddit, vimeo, peertube, generic
    var displayName: String {
        switch self { case .youtube: "YouTube"; case .instagram: "Instagram"; case .facebook: "Facebook"; case .tiktok: "TikTok"; case .x: "X"; case .reddit: "Reddit"; case .vimeo: "Vimeo"; case .peertube: "PeerTube"; case .generic: "This website" }
    }
}

/// Where a lookup is happening. The frame address comes from WebKit's own frame information (never from a message the page sent).
struct MediaPageContext: Sendable, Equatable {
    var pageURL: URL
    var frameURL: URL?
    var isMainFrame = true
    var profile: String
    var isPrivate = false
}

// MARK: - Recognising a provider

enum ProviderMediaKind: String, Sendable { case video, short, reel, post, story, playlist, live, image, unknown }

struct ProviderMatch: Equatable, Sendable {
    var provider: MediaProviderID
    var kind: ProviderMediaKind
    var mediaID: String?
    var isEmbed = false
    var isShortLink = false
    var host: String
}

enum ProviderRecognizer {
    /// The domains each provider is known by. A host belongs to a provider only if it IS one of these or a subdomain of one (a dot before it): "youtube.com.example.net",
    /// "notyoutube.com" and "youtube.com@example.net" (whose host is example.net) are not.
    static let domains: [(MediaProviderID, [String])] = [
        (.youtube, ["youtube.com", "youtube-nocookie.com", "youtu.be"]),
        (.vimeo, ["vimeo.com"]),
        (.tiktok, ["tiktok.com"]),
        (.instagram, ["instagram.com", "instagr.am"]),
        (.facebook, ["facebook.com", "fb.watch", "fb.com"]),
        (.x, ["x.com", "twitter.com", "t.co"]),
        (.reddit, ["reddit.com", "redd.it"]),
    ]

    static func canonicalHost(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        // Only plain ASCII names are recognised; a lookalike written with other letters is just an unknown site.
        guard host.unicodeScalars.allSatisfy({ $0.isASCII }), !host.hasPrefix("xn--"), !host.contains(".xn--") else { return nil }
        return host
    }

    static func hostMatches(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    static func provider(forHost host: String) -> MediaProviderID? {
        #if DEBUG
        // A debug build started with -ProviderFixture <address> treats that local server (and localhost) as Vimeo, so the provider panel can be exercised against a controlled site.
        if let h = ProviderFixtureMode.host, host == h || host == "localhost" { return .vimeo }
        #endif
        for (id, list) in domains where list.contains(where: { hostMatches(host, $0) }) { return id }
        return nil
    }

    private static func isDigits(_ s: String, _ range: ClosedRange<Int>) -> Bool { range.contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber } }
    private static func isCode(_ s: String, _ range: ClosedRange<Int>) -> Bool { range.contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") } }

    // MARK: URL structure of video pages (shared by Vimeo and Facebook)

    /// Vimeo's own site (not its API or developer hosts).
    private static func vimeoContentHost(_ host: String) -> Bool { host == "vimeo.com" || host == "www.vimeo.com" }

    /// The video id in a Vimeo page address, or nil when the path is not one of its video-page shapes:
    /// /<id>, /<id>/<private-hash>, /channels/<name>/<id>, /groups/<name>/videos/<id>, /album|showcase/<id>/video/<id>, /ondemand/<name>/<id>.
    static func vimeoVideoID(_ parts: [String]) -> String? {
        guard let first = parts.first else { return nil }
        if isDigits(first, 1...12) { return parts.count == 1 || (parts.count == 2 && isPrivateLinkHash(parts[1])) ? first : nil }          // /<id> or /<id>/<private-link hash>, not /<id>/settings
        switch first {
        case "manage": return parts.count == 3 && parts[1] == "videos" && isDigits(parts[2], 1...12) ? parts[2] : nil       // the owner's own management page for a video
        case "channels": return parts.count >= 3 && isDigits(parts[2], 1...12) ? parts[2] : nil
        case "groups": return parts.count >= 4 && parts[2] == "videos" && isDigits(parts[3], 1...12) ? parts[3] : nil
        case "album", "showcase": return parts.count >= 4 && parts[2] == "video" && isDigits(parts[3], 1...12) ? parts[3] : nil
        case "ondemand": return parts.count >= 3 && isDigits(parts[2], 1...12) ? parts[2] : nil
        default:
            if parts.count >= 4, parts[1] == "review", isDigits(parts[2], 1...12), isPrivateLinkHash(parts[3]) { return parts[2] }          // /<owner>/review/<id>/<hash>
            return nil
        }
    }

    /// Vimeo's private-link hash: lower-case hexadecimal, 8 to 12 characters (so a word such as "settings" or "comments" is never taken for one).
    private static func isPrivateLinkHash(_ s: String) -> Bool { (8...12).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) } }

    /// Facebook's own content hosts (bare, www, m, web, mbasic, touch), not its developer, business, link-shim or other service hosts.
    private static func facebookContentHost(_ host: String) -> Bool {
        if host == "facebook.com" || ["www.", "m.", "web.", "mbasic.", "touch.", "free."].contains(where: { host == $0 + "facebook.com" }) { return true }
        // language hosts such as en-gb.facebook.com or de.facebook.com
        guard host.hasSuffix(".facebook.com") else { return false }
        let label = String(host.dropLast(".facebook.com".count))
        return label.count == 2 && label.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter } || (label.count == 5 && label.dropFirst(2).first == "-" && label.enumerated().allSatisfy { $0.offset == 2 || ($0.element.isASCII && $0.element.isLowercase && $0.element.isLetter) })
    }

    /// The video id of a Facebook /videos/ address: /<page>/videos/<id>, /<page>/videos/<slug>/<id>, /groups/<group>/videos/<id>. A first segment that is a Facebook section
    /// (help, policies, marketplace, ...) is not a page name.
    static func facebookVideosID(_ parts: [String]) -> String? {
        let sections: Set<String> = ["help", "policies", "privacy", "business", "ads", "about", "legal", "terms", "marketplace", "developers", "settings", "pages", "events", "gaming", "login", "videos", "watch", "reel", "share", "stories", "photo", "photos", "hashtag"]
        guard let at = parts.firstIndex(of: "videos"), at >= 1 else { return nil }
        if parts[0] == "pages" { return at == 3 && parts.count == 5 && isDigits(parts[2], 5...25) && isDigits(parts[4], 5...25) ? parts[4] : nil }          // legacy /pages/<name>/<page-id>/videos/<id>
        if parts[0] == "groups" { return at == 2 && parts.count == 4 && isDigits(parts[3], 5...25) ? parts[3] : nil }
        guard at == 1, !sections.contains(parts[0].lowercased()) else { return nil }
        if parts.count == 3, isDigits(parts[2], 5...25) { return parts[2] }
        if parts.count == 4, isDigits(parts[3], 5...25) { return parts[3] }          // /<page>/videos/<title-slug>/<id>
        return nil
    }

    /// nil: not a known provider (the generic path applies). A known provider with an address this does not understand still matches, with no media id.
    static func recognize(_ url: URL) -> ProviderMatch? {
        guard let host = canonicalHost(url), let provider = provider(forHost: host) else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
        var m = ProviderMatch(provider: provider, kind: .unknown, mediaID: nil, host: host)
        #if DEBUG
        if ProviderFixtureMode.host != nil, host == ProviderFixtureMode.host || host == "localhost" {
            if let v = q("v"), isDigits(v, 1...12) { m.mediaID = v; m.kind = .video }
            m.isEmbed = parts.contains("embed.html")
            return m
        }
        #endif
        switch provider {
        case .youtube:
            if hostMatches(host, "youtu.be") { m.isShortLink = true; if let id = parts.first, isCode(id, 11...11) { m.mediaID = id; m.kind = .video } }
            else if parts.first == "watch" { if let id = q("v"), isCode(id, 11...11) { m.mediaID = id; m.kind = .video } }
            else if let first = parts.first, ["shorts", "embed", "live", "v"].contains(first), parts.count > 1, isCode(parts[1], 11...11) {
                m.mediaID = parts[1]; m.kind = first == "shorts" ? .short : (first == "live" ? .live : .video); m.isEmbed = first == "embed" || hostMatches(host, "youtube-nocookie.com")
            } else if parts.first == "playlist", let list = q("list"), isCode(list, 10...64) { m.mediaID = list; m.kind = .playlist }
        case .vimeo:
            m.isEmbed = host == "player.vimeo.com"
            // Only real video-page shapes carry an id: a number elsewhere in a path (a blog year, a help article, a settings page) is not a video.
            if m.isEmbed { if parts.first == "video", parts.count > 1, isDigits(parts[1], 1...12) { m.mediaID = parts[1]; m.kind = .video } }
            else if vimeoContentHost(host), let id = vimeoVideoID(parts) { m.mediaID = id; m.kind = .video }
        case .tiktok:
            if host.hasPrefix("vm.") || host.hasPrefix("vt.") || parts.first == "t" { m.isShortLink = true; m.kind = .video }
            else if parts.count >= 3, parts[0].hasPrefix("@"), parts[1] == "video" || parts[1] == "photo", isDigits(parts[2], 5...25) { m.mediaID = parts[2]; m.kind = parts[1] == "video" ? .video : .image }
            else if parts.count >= 2, parts[0] == "embed", isDigits(parts[1], 5...25) || (parts[1] == "v2" && parts.count > 2 && isDigits(parts[2], 5...25)) { m.isEmbed = true; m.kind = .video; m.mediaID = isDigits(parts[1], 5...25) ? parts[1] : parts[2] }
        case .instagram:
            if hostMatches(host, "instagr.am") { m.isShortLink = true }
            if let first = parts.first, ["reel", "reels", "p", "tv"].contains(first), parts.count > 1, isCode(parts[1], 5...30) { m.mediaID = parts[1]; m.kind = first.hasPrefix("reel") ? .reel : .post }
            else if parts.first == "stories", parts.count > 2, isDigits(parts[2], 5...25) { m.mediaID = parts[2]; m.kind = .story }
        case .facebook:
            if hostMatches(host, "fb.watch") { m.isShortLink = true; m.kind = .video; if let c = parts.first, isCode(c, 4...30) { m.mediaID = c } }
            else if facebookContentHost(host) {
                if parts.first == "watch", let v = q("v"), isDigits(v, 5...25) { m.mediaID = v; m.kind = .video }
                else if parts.first == "video.php", let v = q("v"), isDigits(v, 5...25) { m.mediaID = v; m.kind = .video }
                else if parts.first == "reel", parts.count > 1, isDigits(parts[1], 5...25) { m.mediaID = parts[1]; m.kind = .reel }
                else if let id = facebookVideosID(parts) { m.mediaID = id; m.kind = .video }
                else if parts.count >= 3, parts[0] == "share", parts[1] == "v" { m.isShortLink = true; m.kind = .video; m.mediaID = parts[2] }
            }
        case .x:
            if hostMatches(host, "t.co") { m.isShortLink = true }
            else if let at = parts.firstIndex(of: "status"), parts.count > at + 1, isDigits(parts[at + 1], 5...25) { m.mediaID = parts[at + 1]; m.kind = .post }
        case .reddit:
            if host == "v.redd.it" { m.kind = .video; if let id = parts.first, isCode(id, 4...20) { m.mediaID = id } }
            else if host == "i.redd.it" { m.kind = .image; m.mediaID = parts.first }
            else if hostMatches(host, "redd.it") { m.isShortLink = true; if let id = parts.first, isCode(id, 4...12) { m.mediaID = id; m.kind = .post } }
            else if let at = parts.firstIndex(of: "comments"), parts.count > at + 1, isCode(parts[at + 1], 4...12) { m.mediaID = parts[at + 1]; m.kind = .post }
        case .peertube, .generic: break
        }
        return m
    }

    /// PeerTube is a network of independent servers, so it has no list of domains. An address shaped like one of its video pages (/w/<id>, /videos/watch/<id>, /videos/embed/<id>) is only a
    /// candidate: the server is asked (its public API, same host) whether it really is one before anything is offered.
    static func peerTubeShape(_ url: URL) -> ProviderMatch? {
        guard let host = canonicalHost(url), provider(forHost: host) == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        func ok(_ id: String) -> Bool { (8...36).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") } }
        var id: String?, embed = false
        if parts.count >= 2, parts[0] == "w", ok(parts[1]) { id = parts[1] }
        else if parts.count >= 3, parts[0] == "videos", parts[1] == "watch", ok(parts[2]) { id = parts[2] }
        else if parts.count >= 3, parts[0] == "videos", parts[1] == "embed", ok(parts[2]) { id = parts[2]; embed = true }
        guard let id else { return nil }
        return ProviderMatch(provider: .peertube, kind: .video, mediaID: id, isEmbed: embed, isShortLink: false, host: host)
    }

    /// The provider of a page, looking at the frame WebKit reported (an embedded player) as well as the page. The frame wins for what is played in it; the page is kept separate.
    static func provider(for context: MediaPageContext) -> (page: ProviderMatch?, frame: ProviderMatch?) {
        (recognize(context.pageURL) ?? peerTubeShape(context.pageURL), context.frameURL.flatMap { recognize($0) ?? peerTubeShape($0) })
    }
}

// MARK: - What a provider permits

enum ProviderRestriction: String, Equatable, Sendable {
    case noRoute        // no download route this app can use has been found or implemented for a page of this provider (its pages are not blocked: media its player exposes in the clear is handled like any other)
    case privateContent, removed, regionBlocked, live
    case missingScope, expiredAuthorization, downloadDisabledByOwner, noEntitlement, rateLimited
}

struct OfficialAlternative: Equatable, Sendable {
    var title: String
    /// nil when the route is inside the provider's own app and has no stable web address.
    var url: URL?
    /// Whether the address was opened and found to be the right page. Several are sign-in gated and could not be read without an account.
    var verified = false
    var caveat: String { url == nil ? "" : (verified ? "" : " (the link needs you to sign in; it could not be checked)") }
}

struct MediaProviderCapabilities: Equatable, Sendable {
    var metadata = false
    var embeddedPlayback = false
    var directDownload = false            // a plain file the adapter can name with the current authorization
    var providerApprovedDownload = false  // the provider's own download permission for this item
    var userOwnedExport = false           // the person's own media, through the provider's export
    var apiDownload = false               // downloadable through a documented API with the person's token
    var archiveExport = false             // an account archive (many items), never one ordinary file
    var authorizedStream = false          // an HLS/DASH presentation the provider authorizes
    var requiresAuthentication = false
    var requiresProviderApproval = false
    var restriction: ProviderRestriction?
    var alternative: OfficialAlternative?
    var note: String?

    /// The only thing a Download button may be enabled by.
    var canDownloadNow: Bool {
        restriction == nil && !requiresAuthentication && !requiresProviderApproval && (directDownload || providerApprovedDownload || apiDownload || authorizedStream)
    }
}

/// What one provider is, in one place: not a switch spread across the code.
struct ProviderEntry: Sendable {
    var id: MediaProviderID
    var version: Int
    var apiHost: String?
    var requiredScopes: [String]
    /// Hosts that serve this provider's own media. A page of the provider that offers media from these is held to the provider's rules.
    var ownMediaHosts: [String]
    /// Hosts a renewed source may live on, besides the host of the source it replaces.
    var sourceHosts: [String]
    var base: MediaProviderCapabilities
}

enum ProviderCatalog {
    static let entries: [MediaProviderID: ProviderEntry] = [
        .youtube: ProviderEntry(id: .youtube, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: ["googlevideo.com", "youtube.com", "youtube-nocookie.com", "youtu.be", "ytimg.com"], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, userOwnedExport: true, requiresProviderApproval: true, restriction: .noRoute,
                alternative: OfficialAlternative(title: "Download your own videos in YouTube Studio, or export them with Google Takeout", url: URL(string: "https://takeout.google.com")),
                note: "YouTube's API Services developer policies prohibit downloading audiovisual content without YouTube's prior written approval, and this app has none. Creators can download their own videos in YouTube Studio, and Google Takeout exports account data; both need you to sign in.")),
        .instagram: ProviderEntry(id: .instagram, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: ["cdninstagram.com", "instagram.com", "instagr.am", "fbcdn.net"], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, userOwnedExport: true, requiresProviderApproval: true, restriction: .noRoute,
                alternative: OfficialAlternative(title: "Download your information from Instagram (Accounts Center)", url: URL(string: "https://accountscenter.instagram.com/info_and_permissions/dyi/")),
                note: "This app has no authorized route to download Instagram posts: none was found in Instagram's published documentation that an app like this may use. That is not a claim that none exists for your own account; its export is the route to check.")),
        .facebook: ProviderEntry(id: .facebook, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: ["fbcdn.net", "facebook.com", "fb.com", "fb.watch", "fbsbx.com"], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, userOwnedExport: true, requiresProviderApproval: true, restriction: .noRoute,
                alternative: OfficialAlternative(title: "Download your information from Facebook", url: URL(string: "https://www.facebook.com/dyi")),
                note: "This app has no authorized route to download Facebook videos: none was found in Facebook's published documentation that an app like this may use. For your own videos, the account export is the route to check.")),
        .tiktok: ProviderEntry(id: .tiktok, version: 1, apiHost: "open.tiktokapis.com", requiredScopes: ["portability.all.single"], ownMediaHosts: ["tiktokcdn.com", "tiktokcdn-us.com", "tiktokcdn-eu.com", "tiktok.com", "tiktokv.com", "tiktokv.us", "byteoversea.com", "ibytedtos.com", "muscdn.com"], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, userOwnedExport: true, archiveExport: true, requiresAuthentication: true, requiresProviderApproval: true, restriction: .noRoute,
                alternative: OfficialAlternative(title: "Request your data in the TikTok app (Settings → Account → Download your data)", url: nil),
                note: "TikTok's Data Portability API exports the signed-in person's own account data as an archive, for apps TikTok has approved. It does not download single public videos.")),
        .x: ProviderEntry(id: .x, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: ["twimg.com", "x.com", "twitter.com", "t.co"], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, userOwnedExport: true, restriction: .noRoute,
                alternative: OfficialAlternative(title: "Download an archive of your data from X", url: URL(string: "https://x.com/settings/download_your_data")),
                note: "X's API describes a post's media variants but this app found no documented download authorization to use. Your own posts can be exported as an archive.")),
        .reddit: ProviderEntry(id: .reddit, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: ["redd.it", "reddit.com", "redditmedia.com", "redditstatic.com"], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, userOwnedExport: true, restriction: .noRoute,
                alternative: OfficialAlternative(title: "Request your Reddit data", url: URL(string: "https://www.reddit.com/settings/data-request")),
                note: "This app found no documented download authorization for Reddit-hosted video, and Reddit's developer terms limit what apps may do with its content. A link to a file on another website is an ordinary link and is handled as one.")),
        .vimeo: ProviderEntry(id: .vimeo, version: 1, apiHost: "api.vimeo.com", requiredScopes: ["public", "private", "video_files"], ownMediaHosts: ["vimeocdn.com", "vimeo.com"], sourceHosts: ["vimeocdn.com", "vimeo.com"], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, apiDownload: true, requiresAuthentication: true,
                note: "Vimeo gives download links through its API to the video's owner (or someone the owner allowed), for plans that include them. Links last 24 hours.")),
        .peertube: ProviderEntry(id: .peertube, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: [], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, apiDownload: true,
                note: "PeerTube publishes a video's files through the server's public API. A public video whose owner left downloads on can be downloaded without an account.")),
        .generic: ProviderEntry(id: .generic, version: 1, apiHost: nil, requiredScopes: [], ownMediaHosts: [], sourceHosts: [], 
            base: MediaProviderCapabilities(metadata: true, embeddedPlayback: true, directDownload: true)),
    ]
    static func entry(_ id: MediaProviderID) -> ProviderEntry { entries[id]! }
}

/// Applies a provider's rules to what the page-scanning discovery found, so generic discovery cannot be used to get around them.
/// What a provider says about a candidate, for display only. It never blocks anything: whether a candidate can be downloaded is decided by what it is (a plain stream or file that is not
/// protected, not a blob, not expired, reachable without anything the browser holds back) and by the transfer itself (authentication and access checks are enforced by the server's answer).
enum ProviderPolicy {
    private static func clean(_ host: String) -> String { var h = host.lowercased(); while h.hasSuffix(".") { h.removeLast() }; return h }

    /// The provider whose own media host serves the candidate, or whose page it was found on. Used to say which official route exists, not to refuse.
    static func governing(_ candidate: MediaCandidate) -> MediaProviderID? {
        if let host = candidate.host.map(clean) {
            for (id, entry) in ProviderCatalog.entries where id != .generic && entry.ownMediaHosts.contains(where: { ProviderRecognizer.hostMatches(host, $0) }) { return id }
        }
        if let pageHost = candidate.pageHost.map(clean), let p = ProviderRecognizer.provider(forHost: pageHost), p != .generic {
            guard let host = candidate.host.map(clean) else { return p }
            return host == pageHost || ProviderRecognizer.hostMatches(host, pageHost) ? p : nil
        }
        return nil
    }

    /// One line for the picker: what is known about this provider's routes. Shown beside a candidate that cannot be downloaded, and as background for one that can.
    static func note(for candidate: MediaCandidate) -> String? {
        guard let p = governing(candidate) else { return nil }
        let base = ProviderCatalog.entry(p).base
        return [base.note, base.alternative.map { "Official route: \($0.title)\($0.caveat)." }].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - A described, authorized source

enum ProviderSourceType: String, Codable, Sendable { case directFile, hls, dash, accountArchive }

struct AuthorizedMediaSource: Equatable, Sendable {
    var provider: MediaProviderID
    var mediaID: String
    var url: URL
    var type: ProviderSourceType
    var profile: String
    /// What allowed it: "vimeo:video_files".
    var scope: String
    var expiresAt: Date?
    var contentType: String?
    var quality: String?
    var width: Int?
    var height: Int?
    var bytes: Int64?
    var md5: String?
    var title: String?
    var canRefresh: Bool

    /// What the media is, independent of where it is fetched from today: the same video at the same quality with the same size gives the same identity whatever the link and token.
    var identity: String {
        func f<T>(_ v: T?) -> String { v.map { "=\($0)" } ?? "-" }          // an absent value is not the same as an empty or zero one
        let text = [provider.rawValue, mediaID, type.rawValue, f(quality), f(width), f(height), f(bytes), f(md5)].joined(separator: "|")
        return Data(text.utf8).sha256Hex
    }
}

enum ProviderSourceCheck {
    enum Problem: Error, Equatable, LocalizedError {
        case notHTTPS, internalAddress, wrongProvider, differentMedia(String), differentProfile, hostNotAllowed(String), expired, noRefresh
        var errorDescription: String? {
            switch self {
            case .notHTTPS: "The source is not on a secure address."
            case .internalAddress: "The source points inside your network."
            case .wrongProvider: "The source belongs to a different website."
            case .differentMedia(let why): "The renewed source is not the same media (\(why))."
            case .differentProfile: "The source belongs to a different profile."
            case .hostNotAllowed(let h): "The renewed source is on a server this download was not using (\(h))."
            case .expired: "The source has expired."
            case .noRefresh: "This source cannot be renewed."
            }
        }
    }

    /// The last two labels of a host: "a.b.vimeocdn.com" and "c.vimeocdn.com" share "vimeocdn.com". (A fixed approximation of a registrable domain; it errs towards refusing.)
    static func registrable(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".") }

    /// Tests aim a provider at a local server; nothing else sets this.
    nonisolated(unsafe) static var testFlag = false
    /// Only a debug build can be told to accept a local address; a release build ignores the flag.
    #if DEBUG
    static var allowLocalForTests: Bool { get { testFlag } set { testFlag = newValue } }
    #else
    static var allowLocalForTests: Bool { get { false } set { _ = newValue } }
    #endif

    /// A source may be used at all: a real address, on the public internet, secure, not out of date.
    static func validate(_ s: AuthorizedMediaSource, now: Date = Date()) throws {
        if !allowLocalForTests {
            guard s.url.scheme?.lowercased() == "https" else { throw Problem.notHTTPS }
            guard let host = s.url.host, !host.isEmpty else { throw Problem.notHTTPS }
            if HTTPRequestPolicy.classify(host: host).isInternal { throw Problem.internalAddress }
        }
        if let e = s.expiresAt, e <= now { throw Problem.expired }
    }

    /// A renewed source may replace an old one only if it is the same media, for the same profile, from the same provider, on a server the old one or the provider's declared hosts allow.
    /// Being on the same website is not enough.
    static func verifyRenewal(old: AuthorizedMediaSource, new: AuthorizedMediaSource, now: Date = Date(), allowLoopbackForTests: Bool = false) throws {
        guard old.canRefresh else { throw Problem.noRefresh }
        guard new.provider == old.provider else { throw Problem.wrongProvider }
        guard new.profile == old.profile else { throw Problem.differentProfile }
        guard new.mediaID == old.mediaID else { throw Problem.differentMedia("another video") }
        guard new.type == old.type else { throw Problem.differentMedia("another kind of source") }
        // Without a size or a checksum there is nothing to show it is the same file.
        guard old.bytes != nil || old.md5 != nil else { throw Problem.differentMedia("nothing to compare it by") }
        if new.identity != old.identity {
            if new.quality != old.quality || new.width != old.width || new.height != old.height { throw Problem.differentMedia("another quality") }
            throw Problem.differentMedia("a different file")
        }
        try validate(new, now: now)
        if allowLoopbackForTests || allowLocalForTests { return }
        let newHost = (new.url.host ?? "").lowercased(), oldHost = (old.url.host ?? "").lowercased()
        let declared = ProviderCatalog.entry(old.provider).sourceHosts
        // The same server, or one the provider declares for its sources. (Sharing a domain such as a storage service's is not enough: many tenants do.)
        let ok = newHost == oldHost || declared.contains { ProviderRecognizer.hostMatches(newHost, $0) }
        guard ok else { throw Problem.hostNotAllowed(registrable(newHost)) }
    }
}

// MARK: - Provider operation state machine

enum ProviderOperationState: Equatable, Sendable {
    case identifying, discovering, authorizationRequired, resolving, ready, refreshRequired, recovering, restricted(ProviderRestriction), unsupported, failed(String), cancelled

    var isFinal: Bool { switch self { case .ready, .restricted, .unsupported, .failed, .cancelled, .authorizationRequired: true; default: false } }

    /// The moves that are allowed. Anything else is a bug and is refused, not carried out.
    func canMove(to next: ProviderOperationState) -> Bool {
        if case .cancelled = self { return false }
        switch (self, next) {
        case (_, .cancelled): return !isFinal || self == .ready || self == .refreshRequired
        case (.identifying, .discovering), (.identifying, .unsupported), (.identifying, .resolving), (.identifying, .restricted), (.identifying, .authorizationRequired), (.identifying, .ready), (.identifying, .failed): return true
        case (.discovering, .authorizationRequired), (.discovering, .resolving), (.discovering, .restricted), (.discovering, .unsupported), (.discovering, .failed): return true
        case (.resolving, .ready), (.resolving, .authorizationRequired), (.resolving, .restricted), (.resolving, .recovering), (.resolving, .failed), (.resolving, .unsupported): return true
        case (.recovering, .resolving), (.recovering, .failed), (.recovering, .authorizationRequired): return true
        case (.ready, .refreshRequired): return true
        case (.refreshRequired, .resolving), (.refreshRequired, .authorizationRequired), (.refreshRequired, .failed), (.refreshRequired, .restricted): return true
        case (.authorizationRequired, .resolving), (.authorizationRequired, .identifying): return true
        default: return false
        }
    }
}

/// How a failed provider call is told apart: bounded retries only for what can get better.
enum ProviderFailure: Error, Equatable, LocalizedError {
    case authorizationRequired, missingScope, removed, rateLimited(TimeInterval?), serverTrouble, malformed(String), tooLarge, offline, restricted(ProviderRestriction), cancelled
    var errorDescription: String? {
        switch self {
        case .authorizationRequired: "Sign in to the website with its official authorization to continue."
        case .missingScope: "The authorization does not include the permission this needs."
        case .removed: "The media is no longer there."
        case .rateLimited(let s): "The website asked for a pause" + (s.map { " of \(Int($0)) seconds" } ?? "") + "."
        case .serverTrouble: "The website had a problem. Try again later."
        case .malformed(let why): "The website's answer could not be read (\(why))."
        case .tooLarge: "The website's answer was larger than allowed."
        case .offline: "There is no connection."
        case .restricted(let r): "The website does not allow this (\(r.rawValue))."
        case .cancelled: "Cancelled."
        }
    }
    /// Worth trying again after a wait.
    var isTransient: Bool { switch self { case .rateLimited, .serverTrouble, .offline: true; default: false } }

    static func from(_ error: Error) -> ProviderFailure {
        if error is CancellationError { return .cancelled }
        if let f = error as? ProviderFailure { return f }
        if let e = error as? HTTPDownloadError {
            switch e.info.code {
            case "http:401": return .authorizationRequired
            case "http:403": return .missingScope
            case "http:404", "http:410": return .removed
            case "http:429": return .rateLimited(e.retryAfter)
            case "http:500", "http:502", "http:503", "http:504", "http:408": return .serverTrouble
            default: return e.info.retryable ? .serverTrouble : .malformed(e.info.code)
            }
        }
        if let e = error as? MediaError, case .tooLarge = e { return .tooLarge }
        if let u = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(u.code) { return .offline }
        return .malformed("\(type(of: error))")
    }
}

/// Runs one provider call with a small, fixed number of tries. A permanent failure (sign-in, removed, malformed) is never repeated.
enum ProviderRetry {
    static let attempts = 3
    nonisolated(unsafe) static var scale = 1.0
    static func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        var last: ProviderFailure = .serverTrouble
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            do { return try await body() }
            catch {
                let f = ProviderFailure.from(error)
                last = f
                guard f.isTransient, attempt + 1 < attempts else { throw f }
                var wait = MediaBackoff.delay(attempt: attempt, retryAfter: { if case .rateLimited(let s) = f { return s }; return nil }())
                wait *= scale
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        throw last
    }
}

// MARK: - Talking to a provider's API

/// The only way an adapter reaches a provider's API: an https GET or POST to the provider's declared API host, with the person's token for that provider and profile, no redirect followed,
/// the answer bounded. The token is never sent anywhere else.
protocol ProviderAPI: Sendable {
    /// The answer's bytes (a value that can safely cross tasks); callers read the JSON themselves.
    func data(_ url: URL, method: String, body: Data?, bearer: String?, extraHeaders: [String: String]) async throws -> Data
    /// A POST whose answer is a file, streamed to disk.
    func download(_ url: URL, body: Data, bearer: String?, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String)
}

extension ProviderAPI {
    func json(_ url: URL, method: String = "GET", body: Data? = nil, bearer: String?, extraHeaders: [String: String] = [:]) async throws -> Any {
        let d = try await data(url, method: method, body: body, bearer: bearer, extraHeaders: extraHeaders)
        do { return try JSONSerialization.jsonObject(with: d) } catch { throw ProviderFailure.malformed("not JSON") }
    }
}

struct FetcherProviderAPI: ProviderAPI {
    let provider: MediaProviderID
    let network: DownloadNetworkSetup
    /// Tests aim a provider at a local server; a release build ignores this.
    var hostOverride: String?
    /// For a server that is not known in advance (a PeerTube instance): the one host this may talk to, over https. Never given a credential.
    var allowedHost: String?
    var origin: DownloadRequestOrigin = .user
    static let limit = 2_000_000

    private func checked(_ url: URL, bearer: String?, extraHeaders: [String: String], json: Bool) throws -> [String: String] {
        #if DEBUG
        let override = hostOverride
        #else
        let override: String? = nil
        #endif
        let allowed = override ?? allowedHost ?? ProviderCatalog.entry(provider).apiHost
        if allowedHost != nil, bearer != nil { throw ProviderFailure.malformed("a credential for an unknown server") }
        guard let allowed, let host = url.host?.lowercased(), host == allowed.lowercased() else { throw ProviderFailure.malformed("an address outside the website's API") }
        guard url.scheme?.lowercased() == "https" || override != nil else { throw ProviderFailure.malformed("not https") }
        var headers = extraHeaders
        if json { headers["Accept"] = headers["Accept"] ?? "application/json" }
        if let bearer, !bearer.isEmpty, bearer.utf8.count < 4096, !bearer.contains("\n"), !bearer.contains("\r") { headers["Authorization"] = "Bearer " + bearer }
        return headers
    }

    func data(_ url: URL, method: String = "GET", body: Data? = nil, bearer: String?, extraHeaders: [String: String] = [:]) async throws -> Data {
        var headers = try checked(url, bearer: bearer, extraHeaders: extraHeaders, json: true)
        if body != nil { headers["Content-Type"] = headers["Content-Type"] ?? "application/json" }
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network)
        defer { fetcher.invalidate() }
        do { return try await fetcher.document(url, limit: Self.limit, redirectOK: { _ in false }, headers: headers, method: method, body: body).data }
        catch let e as MediaFetcher.OutOfScope { _ = e; throw ProviderFailure.malformed("the API redirected elsewhere") }
    }

    func download(_ url: URL, body: Data, bearer: String?, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String) {
        var headers = try checked(url, bearer: bearer, extraHeaders: [:], json: false)
        headers["Content-Type"] = "application/json"
        let fetcher = try MediaFetcher(policy: HTTPRequestPolicy(origin: origin), network: network)
        defer { fetcher.invalidate() }
        do { return try await fetcher.postDownload(url, headers: headers, body: body, to: file, maxBytes: maxBytes) }
        catch let e as MediaFetcher.OutOfScope { _ = e; throw ProviderFailure.malformed("the API redirected elsewhere") }
    }
}

/// A person's token for one provider in one profile, in the same Keychain wrapper the sign-in vault uses. Per profile, per provider; never written to a log or a download record.
enum ProviderCredentials {
    static func service(profile: String) -> String {
        #if DEBUG
        // A debug run against a fixture never touches the real Keychain items of a profile.
        if ProviderFixtureMode.base != nil { return "com.browsersetu.provider.uitest." + profile }
        #endif
        return "com.browsersetu.provider." + profile
    }
    static func token(_ provider: MediaProviderID, profile: String) -> String? { SecretStore.get(service: service(profile: profile), account: provider.rawValue).flatMap { String(data: $0, encoding: .utf8) } }
    @discardableResult static func store(_ token: String, _ provider: MediaProviderID, profile: String) -> Bool { SecretStore.set(Data(token.utf8), service: service(profile: profile), account: provider.rawValue) }
    static func revoke(_ provider: MediaProviderID, profile: String) { SecretStore.delete(service: service(profile: profile), account: provider.rawValue) }
}

// MARK: - Documented answers, read

struct ProviderMetadata: Equatable, Sendable {
    var title: String?
    var duration: Double?
    var width: Int?
    var height: Int?
    var thumbnail: URL?
    /// What the provider describes (X media variants, Reddit video links): for display, never an authorization.
    var described: [String] = []
}

enum VimeoAPI {
    static func videoURL(base: URL, id: String) -> URL {
        var c = URLComponents(url: base.appendingPathComponent("videos/\(id)"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "fields", value: "uri,name,duration,width,height,download,privacy.download,pictures.base_link")]
        return c.url!
    }

    /// The video's `download` array (the owner-enabled, expiring links); never `files`, which are playback links.
    static func sources(from json: Any, id: String, profile: String, fetchedAt: Date = Date()) throws -> (sources: [AuthorizedMediaSource], metadata: ProviderMetadata, downloadAllowed: Bool?) {
        guard let o = json as? [String: Any] else { throw ProviderFailure.malformed("not an object") }
        var meta = ProviderMetadata(title: (o["name"] as? String).map { String($0.prefix(300)) }, duration: (o["duration"] as? NSNumber)?.doubleValue, width: (o["width"] as? NSNumber)?.intValue, height: (o["height"] as? NSNumber)?.intValue)
        if let p = o["pictures"] as? [String: Any], let l = p["base_link"] as? String, let u = URL(string: l), u.scheme == "https" { meta.thumbnail = u }
        let allowed = (o["privacy"] as? [String: Any])?["download"] as? Bool
        guard let list = o["download"] as? [Any] else { return ([], meta, allowed) }
        var out: [AuthorizedMediaSource] = []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        for case let item as [String: Any] in list.prefix(50) {
            guard let link = item["link"] as? String, link.count < 8192, let url = URL(string: link), url.scheme?.lowercased() == "https" || (ProviderSourceCheck.allowLocalForTests && url.scheme?.lowercased() == "http") else { continue }
            let expiry = ["expires", "expires_at", "link_expiration_time"].compactMap { item[$0] as? String }.compactMap { iso.date(from: $0) ?? plain.date(from: $0) }.first ?? fetchedAt.addingTimeInterval(24 * 3600)
            let rendition = (item["public_name"] as? String) ?? (item["quality"] as? String)
            out.append(AuthorizedMediaSource(provider: .vimeo, mediaID: id, url: url, type: .directFile, profile: profile, scope: "vimeo:video_files", expiresAt: expiry, contentType: item["type"] as? String ?? "video/mp4",
                                             quality: rendition, width: (item["width"] as? NSNumber)?.intValue, height: (item["height"] as? NSNumber)?.intValue, bytes: (item["size"] as? NSNumber)?.int64Value,
                                             md5: (item["md5"] as? String).flatMap { $0.isEmpty ? nil : $0 }, title: meta.title, canRefresh: true))
        }
        return (out.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }, meta, allowed)
    }
}

/// The TikTok Data Portability status answer. Fields documented: request_id, status, data_format, category_selection_list; a request cannot be fetched after it expires (about four days
/// after it is ready). The words used for the statuses are matched loosely because their exact spelling has not been checked against the live API.
enum TikTokPortability {
    enum State: Equatable, Sendable { case pending, ready, expired, cancelled, failed, unknown(String) }
    struct Status: Equatable, Sendable { var requestID: String; var state: State; var format: String?; var categories: [String] }

    static func parse(_ json: Any) throws -> Status {
        var o = json as? [String: Any]
        if let d = o?["data"] as? [String: Any] { o = d }
        // The documented request_id is an int64; a string is accepted too.
        let id: String
        if let n = o?["request_id"] as? NSNumber, !(n === kCFBooleanTrue), !(n === kCFBooleanFalse) { id = n.stringValue }
        else if let t = o?["request_id"] as? String, !t.isEmpty, t.count < 200 { id = t }
        else { throw ProviderFailure.malformed("no request_id") }
        guard let o else { throw ProviderFailure.malformed("no data") }
        // The documented values: pending, downloading (ready to download), expired, cancelled.
        let raw = (o["status"] as? String ?? "").lowercased()
        let state: State
        if raw == "cancelled" || raw == "canceled" { state = .cancelled }
        else if raw.contains("expire") { state = .expired }
        else if raw.hasPrefix("not") || raw.contains("incomplete") || raw.contains("unsucc") { state = .unknown(String(raw.prefix(40))) }
        else if raw.contains("pend") { state = .pending }
        else if raw.contains("fail") || raw.contains("cancel") || raw.contains("reject") { state = .failed }
        else if raw.contains("download") || raw.contains("ready") || raw.contains("succ") || raw.contains("complete") { state = .ready }
        else if raw.contains("pend") || raw.contains("process") || raw.contains("queue") || raw.contains("collect") { state = .pending }
        else { state = .unknown(String(raw.prefix(40))) }
        return Status(requestID: id, state: state, format: o["data_format"] as? String, categories: (o["category_selection_list"] as? [String] ?? []).prefix(50).map { String($0.prefix(60)) })
    }
}

enum XMediaEntities {
    /// API v2 `includes.media[]`: described, never authorized.
    static func parse(_ json: Any) -> ProviderMetadata {
        var meta = ProviderMetadata()
        let media = ((json as? [String: Any])?["includes"] as? [String: Any])?["media"] as? [[String: Any]] ?? []
        for m in media.prefix(20) {
            let type = m["type"] as? String ?? "media"
            meta.width = meta.width ?? (m["width"] as? NSNumber)?.intValue; meta.height = meta.height ?? (m["height"] as? NSNumber)?.intValue
            if let ms = (m["duration_ms"] as? NSNumber)?.doubleValue { meta.duration = ms / 1000 }
            if let v = m["variants"] as? [[String: Any]] {
                for variant in v.prefix(20) { meta.described.append("\(type) \((variant["content_type"] as? String) ?? "?")" + ((variant["bit_rate"] as? NSNumber).map { " \($0.intValue / 1000) kbit/s" } ?? "")) }
            } else { meta.described.append(type) }
            if let p = m["preview_image_url"] as? String, let u = URL(string: p), u.scheme == "https" { meta.thumbnail = meta.thumbnail ?? u }
        }
        return meta
    }
}

enum RedditPost {
    struct Info: Equatable, Sendable { var metadata: ProviderMetadata; var galleryItems: Int; var externalLink: URL?; var removed: Bool; var hostedVideo: Bool }
    static func parse(_ json: Any) throws -> Info {
        var node: Any? = json
        if let arr = json as? [Any] { node = arr.first }
        guard let listing = (node as? [String: Any])?["data"] as? [String: Any], let child = (listing["children"] as? [[String: Any]])?.first, let d = child["data"] as? [String: Any] else { throw ProviderFailure.malformed("no post") }
        var meta = ProviderMetadata(title: (d["title"] as? String).map { String($0.prefix(300)) })
        var hosted = false
        if let media = d["media"] as? [String: Any], let v = media["reddit_video"] as? [String: Any] {
            hosted = true
            meta.duration = (v["duration"] as? NSNumber)?.doubleValue; meta.width = (v["width"] as? NSNumber)?.intValue; meta.height = (v["height"] as? NSNumber)?.intValue
            meta.described.append("Reddit-hosted video" + ((v["has_audio"] as? Bool) == false ? " (no sound)" : ""))
        }
        let gallery = ((d["gallery_data"] as? [String: Any])?["items"] as? [Any])?.count ?? 0
        if gallery > 0 { meta.described.append("gallery of \(gallery)") }
        var external: URL?
        if let l = d["url_overridden_by_dest"] as? String, let u = URL(string: l), u.scheme == "https",
           let host = ProviderRecognizer.canonicalHost(u), ProviderRecognizer.provider(forHost: host) != .reddit { external = u }
        let removed = (d["removed_by_category"] as? String) != nil
        return Info(metadata: meta, galleryItems: gallery, externalLink: external, removed: removed, hostedVideo: hosted)
    }
}

// MARK: - Adapters and the registry

protocol MediaSiteAdapter: Sendable {
    var providerID: MediaProviderID { get }
    var version: Int { get }
    func matches(_ context: MediaPageContext) -> Bool
    /// What the website permits for this item, given whether the person has authorized it.
    func capabilities(for match: ProviderMatch, authorized: Bool) -> MediaProviderCapabilities
    func metadata(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> ProviderMetadata?
    func resolveAuthorizedSources(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> [AuthorizedMediaSource]
    func refresh(_ previous: AuthorizedMediaSource, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> AuthorizedMediaSource?
}

extension MediaSiteAdapter {
    var version: Int { ProviderCatalog.entry(providerID).version }
    func matches(_ context: MediaPageContext) -> Bool {
        let m = ProviderRecognizer.provider(for: context)
        return m.page?.provider == providerID || m.frame?.provider == providerID
    }
    func capabilities(for match: ProviderMatch, authorized: Bool) -> MediaProviderCapabilities { ProviderCatalog.entry(providerID).base }
    func metadata(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> ProviderMetadata? { nil }
    func resolveAuthorizedSources(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> [AuthorizedMediaSource] { [] }
    func refresh(_ previous: AuthorizedMediaSource, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> AuthorizedMediaSource? { nil }
}

/// A provider that documents no download authorization this app may use: it is recognised, described, and pointed to its official route.
struct RestrictedProviderAdapter: MediaSiteAdapter {
    let providerID: MediaProviderID
}

struct GenericAdapter: MediaSiteAdapter {
    let providerID: MediaProviderID = .generic
    func matches(_ context: MediaPageContext) -> Bool { true }
}

struct VimeoAdapter: MediaSiteAdapter {
    let providerID: MediaProviderID = .vimeo
    /// Tests aim this at a local server.
    var base = URL(string: "https://api.vimeo.com")!

    func capabilities(for match: ProviderMatch, authorized: Bool) -> MediaProviderCapabilities {
        var c = ProviderCatalog.entry(.vimeo).base
        c.requiresAuthentication = !authorized
        if match.mediaID == nil { c.apiDownload = false; c.restriction = .removed; c.note = "This address does not name a Vimeo video." }
        if !authorized { c.alternative = OfficialAlternative(title: "Authorize Vimeo for this profile", url: nil) }
        return c
    }

    func metadata(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> ProviderMetadata? {
        guard let id = match.mediaID else { return nil }
        let json = try await ProviderRetry.run { try await api.json(VimeoAPI.videoURL(base: base, id: id), method: "GET", body: nil, bearer: token, extraHeaders: ["Accept": "application/vnd.vimeo.*+json;version=3.4"]) }
        return try VimeoAPI.sources(from: json, id: id, profile: context.profile).metadata
    }

    func resolveAuthorizedSources(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> [AuthorizedMediaSource] {
        guard let id = match.mediaID else { throw ProviderFailure.removed }
        guard let token, !token.isEmpty else { throw ProviderFailure.authorizationRequired }
        let json = try await ProviderRetry.run { try await api.json(VimeoAPI.videoURL(base: base, id: id), method: "GET", body: nil, bearer: token, extraHeaders: ["Accept": "application/vnd.vimeo.*+json;version=3.4"]) }
        let r = try VimeoAPI.sources(from: json, id: id, profile: context.profile)
        if r.sources.isEmpty { throw ProviderFailure.restricted(r.downloadAllowed == false ? .downloadDisabledByOwner : .noEntitlement) }
        return r.sources
    }

    func refresh(_ previous: AuthorizedMediaSource, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> AuthorizedMediaSource? {
        let match = ProviderMatch(provider: .vimeo, kind: .video, mediaID: previous.mediaID, host: "vimeo.com")
        let fresh = try await resolveAuthorizedSources(for: match, context: context, api: api, token: token)
        // The same file again, found by what it is and not by where it was; nothing else stands in for it.
        return fresh.first { $0.identity == previous.identity }
    }
}

struct TikTokAdapter: MediaSiteAdapter {
    let providerID: MediaProviderID = .tiktok
    func capabilities(for match: ProviderMatch, authorized: Bool) -> MediaProviderCapabilities {
        var c = ProviderCatalog.entry(.tiktok).base
        c.requiresAuthentication = !authorized
        return c
    }
}

enum ProviderRegistry {
    static func adapter(for id: MediaProviderID) -> MediaSiteAdapter {
        switch id {
        case .vimeo: VimeoAdapter()
        case .tiktok: TikTokAdapter()
        case .peertube: PeerTubeAdapter()
        case .generic: GenericAdapter()
        default: RestrictedProviderAdapter(providerID: id)
        }
    }
}

// MARK: - One lookup

struct ProviderResolution: Equatable, Sendable {
    var match: ProviderMatch?
    var provider: MediaProviderID
    var capabilities: MediaProviderCapabilities
    var state: ProviderOperationState
    var sources: [AuthorizedMediaSource] = []
    var metadata: ProviderMetadata?
    var message: String?
}

/// Identifies the site, asks its adapter what is permitted, and — only if downloading is permitted and authorized — resolves sources. A failing adapter ends in a described state; it never
/// affects another provider or the page.
struct ProviderResolver: Sendable {
    var api: @Sendable (MediaProviderID) -> ProviderAPI
    /// For servers that are not known in advance (PeerTube): an API limited to that one host.
    var instanceAPI: (@Sendable (String) -> ProviderAPI)?
    var adapter: @Sendable (MediaProviderID) -> MediaSiteAdapter = { ProviderRegistry.adapter(for: $0) }
    var token: @Sendable (MediaProviderID, String) -> String? = { ProviderCredentials.token($0, profile: $1) }

    func resolve(_ context: MediaPageContext, progress: (@Sendable (ProviderOperationState) async -> Void)? = nil) async -> ProviderResolution {
        await progress?(.identifying)
        let found = ProviderRecognizer.provider(for: context)
        // The embedded player's own provider decides what is played in it; the page's is the fallback.
        guard var match = found.frame ?? found.page else {
            return ProviderResolution(match: nil, provider: .generic, capabilities: ProviderCatalog.entry(.generic).base, state: .ready, message: nil)
        }
        // A frame is known only by where it is from; when it belongs to the same site as the page, the page says which video.
        if match.mediaID == nil, let page = found.page, page.provider == match.provider { match.mediaID = page.mediaID }
        let a = adapter(match.provider)
        // A private tab never uses the account's authorization: that would tie the private session to the account.
        let tok = context.isPrivate ? nil : token(match.provider, context.profile)
        let caps = a.capabilities(for: match, authorized: tok != nil)
        var r = ProviderResolution(match: match, provider: match.provider, capabilities: caps, state: .identifying)
        if let why = caps.restriction { r.state = .restricted(why); r.message = caps.note; return r }
        if caps.requiresAuthentication {
            r.state = .authorizationRequired
            r.message = context.isPrivate ? "\(match.provider.displayName) is not used in a private tab." : "Authorize \(match.provider.displayName) for this profile in Settings ▸ Downloads ▸ Providers to look this up."
            return r
        }
        guard caps.canDownloadNow else { r.state = .unsupported; r.message = caps.note; return r }
        await progress?(.resolving)
        do {
            let useAPI: ProviderAPI = match.provider == .peertube ? (instanceAPI?(match.host) ?? api(.peertube)) : api(match.provider)
            r.sources = try await a.resolveAuthorizedSources(for: match, context: context, api: useAPI, token: tok)
            r.metadata = r.sources.first.map { ProviderMetadata(title: $0.title) }
            r.state = r.sources.isEmpty ? .unsupported : .ready
            // One bad link does not spoil the rest.
            var firstProblem: Error?
            r.sources = r.sources.filter { do { try ProviderSourceCheck.validate($0); return true } catch { firstProblem = firstProblem ?? error; return false } }
            if r.sources.isEmpty, let firstProblem { throw firstProblem }
        } catch {
            let f = ProviderFailure.from(error)
            r.sources = []
            switch f {
            case .authorizationRequired, .missingScope: r.state = .authorizationRequired
            case .restricted(let why): r.state = .restricted(why); r.capabilities.restriction = why
            case .cancelled: r.state = .cancelled
            default: r.state = .failed(f.errorDescription ?? "The lookup failed.")
            }
            r.message = f.errorDescription
        }
        return r
    }

    /// Renews a source: the adapter finds the same media again; the result is verified before anything may use it.
    func renew(_ old: AuthorizedMediaSource, context: MediaPageContext, allowLoopbackForTests: Bool = false) async throws -> AuthorizedMediaSource {
        let a = adapter(old.provider)
        guard old.canRefresh else { throw ProviderSourceCheck.Problem.noRefresh }
        guard context.profile == old.profile, !context.isPrivate else { throw ProviderSourceCheck.Problem.differentProfile }
        guard let fresh = try await a.refresh(old, context: context, api: api(old.provider), token: token(old.provider, context.profile)) else { throw ProviderSourceCheck.Problem.differentMedia("it is no longer offered") }
        try ProviderSourceCheck.verifyRenewal(old: old, new: fresh, allowLoopbackForTests: allowLoopbackForTests)
        return fresh
    }
}

// MARK: - Into the existing engines

@MainActor
enum ProviderDownloadRouter {
    /// A described source starts a download in the engine that already exists for it: a plain file in the HTTP engine; a stream in the HLS/DASH engine, selected, planned and added exactly as
    /// the picker does. Nothing is fetched by the adapter.
    @discardableResult
    static func start(_ source: AuthorizedMediaSource, name: String, coordinator: DownloadCoordinator, request: MediaSelectionRequest = .init(), origin: DownloadRequestOrigin = .page) async throws -> UUID {
        switch source.type {
        case .directFile:
            var options = HTTPDownloadRunner.Options()
            options.origin = origin
            options.filename = name
            return try await coordinator.http.start(url: source.url, options: options)
        case .hls, .dash:
            let manifest = try await coordinator.media.inspect(source.url, origin: origin)
            let selection = manifest.select(request)
            let plan = try await coordinator.media.plan(for: manifest, selection: selection.choice, title: name, origin: origin, allowFallback: request.allowQualityFallback, fallbacks: selection.fallbacks, sourceURL: source.url)
            return try await coordinator.media.add(plan, name: name, source: source.url, origin: origin)
        case .accountArchive:
            throw ProviderFailure.restricted(.noRoute)
        }
    }

    /// Renews the link of a download that stopped because it expired, only if the provider hands back the same media. The existing task keeps its place and its name.
    static func renew(taskID: UUID, old: AuthorizedMediaSource, context: MediaPageContext, resolver: ProviderResolver, coordinator: DownloadCoordinator) async throws {
        let fresh = try await resolver.renew(old, context: context)
        coordinator.http.restart(taskID, url: fresh.url)
    }
}

#if DEBUG
/// Debug builds only: `-ProviderFixture http://127.0.0.1:18766` points the provider system at a controlled local site (Vimeo-shaped API under /media/vimeo, links served by the same site), and
/// `-ProviderFixtureDelay <seconds>` slows its answers so a lookup can be cancelled while it runs. Nothing here exists in a release build.
enum ProviderFixtureMode {
    static var base: URL? { UserDefaults.standard.string(forKey: "ProviderFixture").flatMap(URL.init(string:)) }
    static var host: String? { base?.host }
    static var delay: Double { UserDefaults.standard.double(forKey: "ProviderFixtureDelay") }
}

/// Wraps an API so every answer takes a fixed time (debug fixture only).
struct DelayedProviderAPI: ProviderAPI {
    let inner: ProviderAPI
    let seconds: Double
    func data(_ url: URL, method: String, body: Data?, bearer: String?, extraHeaders: [String: String]) async throws -> Data {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return try await inner.data(url, method: method, body: body, bearer: bearer, extraHeaders: extraHeaders)
    }
    func download(_ url: URL, body: Data, bearer: String?, to file: URL, maxBytes: Int64) async throws -> (size: Int64, contentType: String) {
        try await inner.download(url, body: body, bearer: bearer, to: file, maxBytes: maxBytes)
    }
}
#endif

// MARK: - PeerTube

/// What a PeerTube server says about one of its videos (GET /api/v1/videos/<id>, public). Field names checked against a live public instance: `privacy.id`, `isLive`, `downloadEnabled`,
/// `files[]` (`fileDownloadUrl`, `fileUrl`, `resolution.label`, `height`, `size`, `hasVideo`, `hasAudio`) and `streamingPlaylists[]` (`playlistUrl`, `files[]`).
enum PeerTubeAPI {
    static func sources(from json: Any, host: String, profile: String) throws -> (sources: [AuthorizedMediaSource], metadata: ProviderMetadata) {
        guard let o = json as? [String: Any], let uuid = o["uuid"] as? String, !uuid.isEmpty else { throw ProviderFailure.malformed("not a PeerTube video") }
        if (o["isLive"] as? Bool) == true { throw ProviderFailure.restricted(.live) }
        let privacy = (o["privacy"] as? [String: Any])?["id"] as? Int ?? 1
        guard privacy == 1 || privacy == 2 else { throw ProviderFailure.restricted(.privateContent) }        // 1 public, 2 unlisted
        var meta = ProviderMetadata(title: (o["name"] as? String).map { String($0.prefix(300)) }, duration: (o["duration"] as? NSNumber)?.doubleValue)
        if let t = o["thumbnailPath"] as? String, let u = URL(string: "https://\(host)\(t)") { meta.thumbnail = u }
        if (o["downloadEnabled"] as? Bool) == false { throw ProviderFailure.restricted(.downloadDisabledByOwner) }
        var out: [AuthorizedMediaSource] = []
        var seen = Set<String>()
        func add(_ f: [String: Any]) {
            guard (f["hasVideo"] as? Bool) != false || (f["hasAudio"] as? Bool) == true else { return }
            guard let link = (f["fileDownloadUrl"] as? String) ?? (f["fileUrl"] as? String), link.count < 8192, let url = URL(string: link), url.scheme?.lowercased() == "https" || (ProviderSourceCheck.allowLocalForTests && url.scheme?.lowercased() == "http") else { return }
            let label = ((f["resolution"] as? [String: Any])?["label"] as? String) ?? "Original"
            let bytes = (f["size"] as? NSNumber)?.int64Value
            guard seen.insert("\(label)|\(bytes ?? -1)|\(link)").inserted else { return }
            let height = (f["height"] as? NSNumber)?.intValue
            out.append(AuthorizedMediaSource(provider: .peertube, mediaID: uuid, url: url, type: .directFile, profile: profile, scope: "peertube:public", expiresAt: nil, contentType: nil, quality: label, width: nil, height: height,
                                             bytes: bytes, md5: nil, title: meta.title, canRefresh: false))
        }
        for f in (o["files"] as? [[String: Any]] ?? []).prefix(40) { add(f) }
        for p in (o["streamingPlaylists"] as? [[String: Any]] ?? []).prefix(4) {
            for f in (p["files"] as? [[String: Any]] ?? []).prefix(40) { add(f) }
            if let link = p["playlistUrl"] as? String, let url = URL(string: link), url.scheme?.lowercased() == "https" || (ProviderSourceCheck.allowLocalForTests && url.scheme?.lowercased() == "http") {
                out.append(AuthorizedMediaSource(provider: .peertube, mediaID: uuid, url: url, type: .hls, profile: profile, scope: "peertube:public", expiresAt: nil, contentType: "application/x-mpegurl", quality: "Adaptive stream (HLS)", width: nil, height: nil,
                                                 bytes: nil, md5: nil, title: meta.title, canRefresh: false))
            }
        }
        if out.isEmpty { throw ProviderFailure.restricted(.noEntitlement) }
        // Largest picture first; the adaptive stream last.
        return (out.sorted { a, b in (a.type == .hls ? 1 : 0, -(a.height ?? 0)) < (b.type == .hls ? 1 : 0, -(b.height ?? 0)) }, meta)
    }
}

struct PeerTubeAdapter: MediaSiteAdapter {
    let providerID: MediaProviderID = .peertube
    func resolveAuthorizedSources(for match: ProviderMatch, context: MediaPageContext, api: ProviderAPI, token: String?) async throws -> [AuthorizedMediaSource] {
        guard let id = match.mediaID else { throw ProviderFailure.removed }
        // The server's own public API, on the very host the person is looking at, over the page's own scheme and port. No credential is ever sent.
        let page = context.frameURL ?? context.pageURL
        var c = URLComponents()
        c.scheme = page.scheme; c.host = match.host; c.port = page.port; c.path = "/api/v1/videos/\(id)"
        guard let url = c.url else { throw ProviderFailure.malformed("address") }
        let json = try await ProviderRetry.run { try await api.json(url, method: "GET", body: nil, bearer: nil, extraHeaders: [:]) }
        return try PeerTubeAPI.sources(from: json, host: match.host, profile: context.profile).sources
    }
}
