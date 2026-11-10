import Foundation

/// The hosts the browser's own protection blocks, as a plain set, so an icon fetch obeys the same lists a page load does.
///
/// An icon is fetched by the app, not by WebKit, so the compiled content-rule lists never see it, and WebKit has no call that tests a URL against a list.
/// The lists the privacy engine builds are, for the most part, rules of one shape: block everything from a domain (`||example.com^`). Those are read back here from the
/// compiled rules and kept as a set of domains. Rules that depend on a path, a page, a resource type or a context are not applied here: this is the part of the lists that
/// can be applied exactly, not an approximation of the rest.
///
/// An icon from the page's own site is never refused by this (a site's own address is not a third party to it); a third-party icon host on the list is.
struct IconBlocklist: Sendable, Equatable {
    var domains: Set<String> = []
    static let empty = IconBlocklist()
    var isEmpty: Bool { domains.isEmpty }

    func blocks(iconHost: String, pageHost: String) -> Bool {
        guard !domains.isEmpty else { return false }
        let icon = iconHost.lowercased(), page = pageHost.lowercased()
        let related = icon == page || icon.hasSuffix("." + page) || page.hasSuffix("." + icon)
        if related { return false }
        // The host and each parent domain, down to two labels.
        var labels = icon.split(separator: ".").map(String.init)
        while labels.count >= 2 {
            if domains.contains(labels.joined(separator: ".")) { return true }
            labels.removeFirst()
        }
        return false
    }

    private static let anchoredPrefix = "^https?://([^/]+\\.)?"
    private static let anchoredSuffix = "[/:?&=]"

    /// Reads the block rules of compiled content-rule lists (the JSON the privacy engine installs in WebKit).
    static func build(from lists: [Data]) -> IconBlocklist {
        var out = Set<String>()
        for data in lists {
            guard let rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for rule in rules {
                guard let action = rule["action"] as? [String: Any], action["type"] as? String == "block",
                      let trigger = rule["trigger"] as? [String: Any], let filter = trigger["url-filter"] as? String,
                      filter.hasPrefix(anchoredPrefix), filter.hasSuffix(anchoredSuffix) else { continue }
                // Only a rule that says nothing but "this domain": no page, context or case conditions, and a resource type that includes pictures.
                if ["if-domain", "unless-domain", "if-top-url", "unless-top-url", "load-context", "url-filter-is-case-sensitive"].contains(where: { trigger[$0] != nil }) { continue }
                if let types = trigger["resource-type"] as? [String], !types.contains("image") { continue }
                if let load = trigger["load-type"] as? [String], load != ["third-party"] { continue }
                let middle = String(filter.dropFirst(anchoredPrefix.count).dropLast(anchoredSuffix.count)).replacingOccurrences(of: "\\.", with: ".")
                guard middle.contains("."), middle.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression) != nil else { continue }
                out.insert(middle)
            }
        }
        return IconBlocklist(domains: out)
    }
}
