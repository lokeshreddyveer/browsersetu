import Foundation

/// Removes well-known tracking parameters from web links. Pure and local: nothing is downloaded, and only the
/// query string of http(s) links is touched. The remaining query is returned byte for byte, so a link that
/// carries a real parameter next to a tracking one keeps working.
enum TrackingParameters {
    /// Parameters that exist only to identify a click or a campaign.
    static let exact: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "twclid", "ttclid",
        "li_fat_id", "igshid", "mc_eid", "mc_cid", "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking",
        "mkt_tok", "vero_id", "oly_enc_id", "oly_anon_id", "_openstat", "wickedid", "rb_clickid", "irclickid",
        "ck_subscriber_id", "ref_src", "ref_url", "s_cid", "sc_cid",
    ]

    /// Families of campaign parameters (`utm_source`, `utm_campaign`, …).
    static let prefixes: [String] = ["utm_", "mtm_", "pk_", "matomo_", "piwik_", "hsa_"]

    static func isTracking(_ name: String) -> Bool {
        let lower = name.lowercased()
        return exact.contains(lower) || prefixes.contains { lower.hasPrefix($0) }
    }

    /// The link without its tracking parameters, or nil when there was nothing to remove.
    static func clean(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let query = parts.percentEncodedQuery, !query.isEmpty else { return nil }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        let kept = pairs.filter { pair in
            let rawName = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let name = rawName.removingPercentEncoding ?? rawName
            return !isTracking(name)
        }
        guard kept.count != pairs.count else { return nil }
        parts.percentEncodedQuery = kept.isEmpty ? nil : kept.joined(separator: "&")
        return parts.url
    }
}
