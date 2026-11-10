import Foundation

// A provider-neutral connector for a downloader SERVICE that documents an integration: it accepts a video's page address and returns the formats it offers. No service is built in or enabled:
// a public downloader website is not an API, and none has a documented, permitted integration that has been verified. The contract and the checks on whatever comes back exist so that a
// verified service can be added without bypassing the engine, the consent model or the destination checks. Files a service offers are fetched by the existing download engine, never by the service.

struct ConnectorFormat: Equatable, Sendable {
    var label: String
    var kind: OutputOption.Kind
    var height: Int?
    var url: URL
    var mime: String?
    var expires: Date?
    var estimatedBytes: Int64?
}

struct ConnectorResponse: Equatable, Sendable {
    /// The video the service says it looked at (its page address); must be the one asked about.
    var videoPage: URL
    var formats: [ConnectorFormat]
    var contentType: String?
}

protocol DownloaderServiceConnector: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Where the service documents this integration. A connector without one is never enabled.
    var documentation: URL? { get }
    /// The hosts the service answers from and its files may come from; anything else in a response is refused.
    var allowedHosts: Set<String> { get }
    func accepts(_ page: URL) -> Bool
    /// Sends only the page address. The implementation must not add cookies, tokens or other page data.
    func inspect(page: URL) async throws -> ConnectorResponse
}

enum ConnectorRegistry {
    /// Verified, documented services. Empty on purpose.
    @MainActor static var connectors: [any DownloaderServiceConnector] = []
    static func eligible(_ c: any DownloaderServiceConnector) -> Bool { c.documentation != nil && !c.allowedHosts.isEmpty }
}

enum ConnectorFailure: Error, Equatable, Sendable {
    case wrongVideo, noFormats, htmlInsteadOfData, hostNotAllowed(String), notSecure, expired, mimeMismatch(String)
    var text: String {
        switch self {
        case .wrongVideo: "The service answered about a different video, so its answer was discarded."
        case .noFormats: "The service offered no downloadable formats."
        case .htmlInsteadOfData: "The service returned a web page instead of formats."
        case .hostNotAllowed(let h): "The service pointed to \(h), which it is not approved to use."
        case .notSecure: "A returned address was not secure (https)."
        case .expired: "A returned link had already expired."
        case .mimeMismatch(let m): "A returned file has an unexpected type (\(m))."
        }
    }
}

enum ConnectorValidator {
    /// Everything a service sends back is checked before any option is shown: it is about the video asked, its addresses are https on approved hosts, nothing has expired, and a file's type
    /// matches what the option says it is.
    static func validate(_ r: ConnectorResponse, asked page: URL, connector c: any DownloaderServiceConnector, now: Date = Date()) throws -> [ConnectorFormat] {
        if let t = r.contentType?.lowercased(), t.contains("text/html") { throw ConnectorFailure.htmlInsteadOfData }
        guard canonical(r.videoPage) == canonical(page) else { throw ConnectorFailure.wrongVideo }
        guard !r.formats.isEmpty else { throw ConnectorFailure.noFormats }
        for f in r.formats {
            guard f.url.scheme?.lowercased() == "https" else { throw ConnectorFailure.notSecure }
            let host = (f.url.host ?? "").lowercased()
            guard c.allowedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { throw ConnectorFailure.hostNotAllowed(host) }
            if let e = f.expires, e <= now { throw ConnectorFailure.expired }
            if let m = f.mime?.lowercased() {
                let audio = f.kind == .audioOriginal || f.kind == .audioM4A || f.kind == .audioMP3
                if m.contains("text/html") || (audio && m.hasPrefix("video/") && f.kind != .audioOriginal) || (!audio && m.hasPrefix("audio/")) { throw ConnectorFailure.mimeMismatch(m) }
            }
        }
        return r.formats
    }
    static func canonical(_ u: URL) -> String { LinkClassifier.normalizedKey(u) }
}
