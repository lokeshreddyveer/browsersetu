import Foundation

/// Turns what a page declared into an ordered list of icons to try, best first. Pure and deterministic: the same page always gives the same order.
///
/// The rules, in order of importance:
///  1. An icon the page named always comes before the site's default /favicon.ico. The default is only the last resort.
///  2. An icon made for the other appearance is not a first choice (it is kept as that appearance's own variant).
///  3. A scalable icon (SVG, or `sizes="any"`) fits every size, so it is best.
///  4. Otherwise the smallest icon at least as large as what is drawn (64 pixels covers a 32-point icon on a Retina display),
///     because shrinking is clean and enlarging is not. Then icons with no declared size. Then the largest of the ones that are too small.
///  5. Among equals: a plain `icon` over a shortcut icon over an Apple touch icon (which is opaque and was made for a home screen), then the page's own order.
///  6. At most `maxPageCandidates` page icons are tried, and /favicon.ico is always added after them, so a long list never crowds it out.
enum IconCandidateRanker {
    static let targetPixels = 64
    static let maxPageCandidates = 4

    // MARK: Reading what the page said

    /// `rows` is what the page script returns: `href`, `rel`, `sizes`, `type`, `media` for each icon link. Anything unusable is dropped.
    static func candidates(fromLinks rows: [[String: Any]], pageURL: URL) -> [IconCandidate] {
        var out: [IconCandidate] = []
        for (index, row) in rows.enumerated() {
            guard let href = row["href"] as? String, let url = URL(string: href, relativeTo: pageURL)?.absoluteURL, isFetchableScheme(url, page: pageURL) else { continue }
            let rel = (row["rel"] as? String ?? "").lowercased()
            let kind: IconKind = rel.contains("apple-touch") ? .appleTouch : (rel.contains("shortcut") ? .shortcutIcon : .icon)
            let sizesText = (row["sizes"] as? String ?? "").lowercased()
            let any = sizesText.split(separator: " ").contains("any")
            let sizes = sizesText.split(separator: " ").compactMap(parseSize)
            let type = (row["type"] as? String)?.lowercased().trimmingCharacters(in: .whitespaces)
            let media = (row["media"] as? String ?? "").lowercased()
            let scheme: IconColorScheme? = media.contains("prefers-color-scheme") ? (media.contains("dark") ? .dark : .light) : nil
            out.append(IconCandidate(url: url, kind: kind, declaredSizes: sizes, declaresAnySize: any, mimeType: (type?.isEmpty == false) ? type : nil, scheme: scheme, source: .pageDeclared, order: index))
        }
        return out
    }

    static func parseSize(_ token: Substring) -> IconPixelSize? {
        let parts = token.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0, w <= 4096, h <= 4096 else { return nil }
        return IconPixelSize(width: w, height: h)
    }

    /// https always; http only when the page itself is http (a page that was loaded in the clear gains nothing from an upgrade, and an https page may never name an http icon).
    static func isFetchableScheme(_ url: URL, page: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        guard let host = url.host, !host.isEmpty else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && page.scheme?.lowercased() == "http"
    }

    // MARK: Ordering

    /// The icons to try for the page's default (light) appearance, best first, ending with the site's /favicon.ico.
    static func ordered(_ declared: [IconCandidate], pageURL: URL) -> [IconCandidate] {
        var seen = Set<String>()
        let primary = declared.filter { $0.scheme != .dark }
            .sorted(by: precedes)
            .filter { seen.insert(normalised($0.url)).inserted }
        var list = Array(primary.prefix(maxPageCandidates))
        if let fallback = hostDefault(for: pageURL), !list.contains(where: { normalised($0.url) == normalised(fallback.url) }) { list.append(fallback) }
        return list
    }

    /// The icons made for dark appearance, best first (no site default: it has no appearance).
    static func darkVariants(_ declared: [IconCandidate]) -> [IconCandidate] {
        var seen = Set<String>()
        return declared.filter { $0.scheme == .dark }.sorted(by: precedes).filter { seen.insert(normalised($0.url)).inserted }.prefix(2).map { $0 }
    }

    static func hostDefault(for page: URL) -> IconCandidate? {
        guard let host = page.host, let scheme = page.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        var parts = URLComponents(); parts.scheme = scheme; parts.host = host; parts.port = page.port; parts.path = "/favicon.ico"
        guard let url = parts.url else { return nil }
        return IconCandidate(url: url, kind: .hostDefault, source: .hostDefault, order: Int.max)
    }

    /// The fit class: lower is better. See the rules above.
    private static func fitClass(_ c: IconCandidate) -> (cls: Int, within: Int) {
        if c.declaresAnySize || c.isLikelySVG { return (0, 0) }
        guard !c.declaredSizes.isEmpty else { return (2, 0) }
        let best = c.declaredSizes.map(\.longSide)
        let atLeast = best.filter { $0 >= targetPixels }.min()
        if let atLeast { return (1, atLeast - targetPixels) }                       // closest above the target
        return (3, targetPixels - (best.max() ?? 0))                                // the largest of the small ones
    }

    private static func kindRank(_ k: IconKind) -> Int {
        switch k { case .icon: 0; case .shortcutIcon: 1; case .appleTouch: 2; case .hostDefault: 3 }
    }

    static func precedes(_ a: IconCandidate, _ b: IconCandidate) -> Bool {
        if a.source != b.source { return a.source == .pageDeclared }
        let fa = fitClass(a), fb = fitClass(b)
        if fa.cls != fb.cls { return fa.cls < fb.cls }
        if fa.within != fb.within { return fa.within < fb.within }
        if kindRank(a.kind) != kindRank(b.kind) { return kindRank(a.kind) < kindRank(b.kind) }
        return a.order < b.order
    }

    static func normalised(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        return parts.url?.absoluteString ?? url.absoluteString
    }
}
