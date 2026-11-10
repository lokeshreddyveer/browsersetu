import Foundation

/// The blocking rules behind three switches that sit beside the privacy kit's own lists: pages reaching this device or the home network, Google's analytics
/// and font servers, and embedded social widgets. Plain text in WebKit's content-blocker format, built from `WebPolicy`; the engine compiles and attaches it.
/// WebKit's pattern language has no "or" between alternatives, so every address form is a rule of its own.
enum ExtraRules {
    /// The addresses that belong to this device or the home network, as patterns for the start of a web or WebSocket address.
    private static let localHostPatterns = [
        "localhost[:/]", "localhost$",
        "127\\.[0-9]+\\.[0-9]+\\.[0-9]+[:/]",
        "0\\.0\\.0\\.0[:/]",
        "10\\.[0-9]+\\.[0-9]+\\.[0-9]+[:/]",
        "192\\.168\\.[0-9]+\\.[0-9]+[:/]",
        "172\\.1[6-9]\\.[0-9]+\\.[0-9]+[:/]", "172\\.2[0-9]\\.[0-9]+\\.[0-9]+[:/]", "172\\.3[01]\\.[0-9]+\\.[0-9]+[:/]",
        "169\\.254\\.[0-9]+\\.[0-9]+[:/]",
        "\\[::1\\][:/]",
        "[^/:]+\\.local[:/]",
    ]
    private static let schemes = ["^https?://", "^wss?://"]

    private static let googleHosts = [
        "google-analytics.com", "googletagmanager.com", "googletagservices.com", "doubleclick.net", "googlesyndication.com",
        "googleadservices.com", "fonts.googleapis.com", "fonts.gstatic.com", "app-measurement.com",
    ]

    private static let socialHosts = [
        "connect.facebook.net", "platform.twitter.com", "syndication.twitter.com", "platform.linkedin.com", "platform.instagram.com",
        "assets.pinterest.com", "widgets.pinterest.com", "platform.tumblr.com", "static.addtoany.com", "w.sharethis.com",
    ]

    /// The rules for these switches as JSON text, or nil when none of them is on.
    static func json(for policy: WebPolicy) -> String? {
        var rules: [[String: Any]] = []
        if policy.blockLocalNetwork { rules += localNetworkRules(allowed: policy.localNetworkAllowed) }
        if policy.blockGoogleServices { rules += hostRules(googleHosts, thirdPartyOnly: false) }
        if policy.blockSocialWidgets { rules += hostRules(socialHosts, thirdPartyOnly: true) }
        guard !rules.isEmpty, let data = try? JSONSerialization.data(withJSONObject: rules), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// A page on the internet may not load anything from a local address. A page that is itself on a local address, or on a site the person allowed, may.
    private static func localNetworkRules(allowed: Set<String>) -> [[String: Any]] {
        var exceptions = localHostPatterns.map { "^https?://" + $0 }
        for host in allowed.sorted() {
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            exceptions.append("^https?://([^/]*\\.)?" + escaped + "[:/]")
        }
        var rules: [[String: Any]] = []
        for scheme in schemes {
            for pattern in localHostPatterns {
                rules.append(["trigger": ["url-filter": scheme + pattern, "load-type": ["third-party"], "unless-top-url": exceptions],
                              "action": ["type": "block"]])
            }
        }
        return rules
    }

    private static func hostRules(_ hosts: [String], thirdPartyOnly: Bool) -> [[String: Any]] {
        hosts.map { host in
            var trigger: [String: Any] = ["url-filter": "^https?://([^/]*\\.)?" + host.replacingOccurrences(of: ".", with: "\\.") + "[:/]"]
            if thirdPartyOnly { trigger["load-type"] = ["third-party"] }
            return ["trigger": trigger, "action": ["type": "block"]]
        }
    }
}
