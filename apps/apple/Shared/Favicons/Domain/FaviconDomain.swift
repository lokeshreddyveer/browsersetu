import Foundation
import CryptoKit

// The vocabulary of the favicon subsystem. Everything here is a plain value: no network, no disk, no UI.
//
//   IconKey          which site an icon belongs to (a host, without a leading "www.")
//   IconCandidate    an icon a page declared (or the site's default), before anything is fetched
//   IconResourceID   the identity of icon BYTES: a SHA-256 of the normalised PNG, so two sites with the same icon share one file
//   IconRecord       the association "this site shows that resource", with the cache metadata that goes with it
//   IconFailure      a site whose icon could not be had, and when to ask again (bounded negative caching)
//   FaviconIndex     the versioned file that holds all of the above for one profile
//
// The association (IconRecord) and the bytes (IconResourceMeta + blob file) are kept apart on purpose.

/// The site an icon belongs to: its host, lower-cased, without a leading "www.", and with its port when that is not the default (`localhost:3000`).
struct IconKey: Hashable, Codable, Sendable, CustomStringConvertible {
    let host: String

    init?(host raw: String?) {
        guard var h = raw?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !h.isEmpty else { return nil }
        if h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        guard !h.isEmpty else { return nil }
        host = h
    }

    /// A site at a non-default port is a different site: `localhost:3000` and `localhost:8080` do not share an icon. 80 and 443 are the defaults and are left out.
    init?(url: URL?) {
        guard let url, let base = IconKey(host: url.host) else { return nil }
        if let port = url.port, port != 80, port != 443 { host = base.host + ":\(port)" } else { host = base.host }
    }

    var description: String { host }
}

enum IconColorScheme: String, Codable, Sendable, CaseIterable { case light, dark }

/// What the page's `rel` says the icon is.
enum IconKind: String, Codable, Sendable {
    case icon, shortcutIcon, appleTouch, hostDefault
}

struct IconPixelSize: Hashable, Codable, Sendable {
    let width: Int
    let height: Int
    var longSide: Int { max(width, height) }
}

/// An icon a page declared, or the site's own /favicon.ico, before anything is fetched or checked.
struct IconCandidate: Hashable, Sendable {
    enum Source: String, Codable, Sendable { case pageDeclared, hostDefault }

    var url: URL
    var kind: IconKind
    /// From `sizes="16x16 32x32"`; empty when none was declared.
    var declaredSizes: [IconPixelSize] = []
    /// `sizes="any"`: a scalable icon, in practice an SVG.
    var declaresAnySize = false
    /// From `type="image/svg+xml"` (lower-cased), when given. Only a hint: the bytes decide.
    var mimeType: String?
    /// From a `media="(prefers-color-scheme: dark)"` attribute; nil when the icon is for every appearance.
    var scheme: IconColorScheme?
    var source: Source = .pageDeclared
    /// Position in the page, so equal candidates keep the page's own order.
    var order = 0

    var isLikelySVG: Bool {
        mimeType == "image/svg+xml" || url.path.lowercased().hasSuffix(".svg")
    }
}

/// The identity of icon bytes: the SHA-256 of the stored PNG.
struct IconResourceID: Hashable, Codable, Sendable, CustomStringConvertible {
    let hex: String
    init(hex: String) { self.hex = hex }
    init(data: Data) { hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    var description: String { hex }
}

/// The bytes of one icon, as stored: always a small PNG.
struct IconResourceMeta: Codable, Sendable, Equatable {
    var bytes: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var mimeType: String
    var createdAt: Date
}

/// "This site shows that resource", and what is known about getting it again.
struct IconRecord: Codable, Sendable, Equatable {
    var key: String
    /// The resource for every appearance (or for light).
    var resource: String
    /// An icon made for dark appearance, when the page declared one.
    var darkResource: String?
    /// Host the bytes came from. Never a full URL: an icon address can carry a token.
    var sourceHost: String
    /// A digest of the address the bytes came from, so a conditional request is only made to the same address.
    var sourceDigest: String
    var kind: IconKind
    var fetchedAt: Date
    var validatedAt: Date
    var expiresAt: Date
    var etag: String?
    var lastModified: String?
    var lastUsed: Date

    func isFresh(at now: Date) -> Bool { expiresAt > now }
}

/// A site whose icon could not be had. Asking again waits `retryAfter`, which grows with each failure up to a day.
struct IconFailure: Codable, Sendable, Equatable {
    var key: String
    var failedAt: Date
    var retryAfter: Date
    var count: Int
    var reason: String
}

/// The whole persisted state of one profile's icons. Versioned: a newer file than this build understands is set aside, never overwritten.
struct FaviconIndex: Codable, Sendable, Equatable {
    static let currentVersion = 1
    var schemaVersion = FaviconIndex.currentVersion
    var records: [String: IconRecord] = [:]
    var resources: [String: IconResourceMeta] = [:]
    var failures: [String: IconFailure] = [:]
    /// Set once the old per-host files in the shared Caches folder have been read in.
    var legacyImported = false
}

/// How much one profile may keep. Eviction is by last use, then by key, so it is the same every time.
struct FaviconBudget: Sendable, Equatable {
    var maxRecords = 2_000
    var maxBytes = 32 * 1024 * 1024
    static let standard = FaviconBudget()
}

/// What a resolution did, for the caller and for diagnostics.
enum IconResolution: Sendable, Equatable {
    case cached
    case refreshed
    case revalidated
    case staleKept
    case backedOff
    case offline
    case noIcon
    case rejectedPrivate
}
