import Foundation

/// Skips a tracker's redirect page. A link such as `l.facebook.com/l.php?u=https%3A%2F%2Fexample.com` is answered by a page that logs the click and then
/// sends the visitor on; this returns the address it would send them to, so the visit goes there directly. Pure and local: nothing is fetched, and only
/// the known redirect forms below are touched (a short link like t.co needs a request to resolve, so it is left alone).
enum LinkDebouncer {
    private struct Redirector {
        let hosts: Set<String>
        /// The path the redirect lives at ("/" matches any), and the query parameters that carry the destination, in order.
        let path: String
        let parameters: [String]
    }

    private static let redirectors: [Redirector] = [
        Redirector(hosts: ["l.facebook.com", "lm.facebook.com", "l.messenger.com"], path: "/l.php", parameters: ["u"]),
        Redirector(hosts: ["l.instagram.com"], path: "/", parameters: ["u"]),
        Redirector(hosts: ["www.google.com", "google.com"], path: "/url", parameters: ["q", "url"]),
        Redirector(hosts: ["www.youtube.com", "youtube.com", "m.youtube.com"], path: "/redirect", parameters: ["q"]),
        Redirector(hosts: ["out.reddit.com"], path: "/", parameters: ["url"]),
        Redirector(hosts: ["steamcommunity.com"], path: "/linkfilter/", parameters: ["u", "url"]),
        Redirector(hosts: ["www.linkedin.com"], path: "/safety/go", parameters: ["url"]),
        Redirector(hosts: ["vk.com"], path: "/away.php", parameters: ["to"]),
    ]

    /// The address a redirect page would send the visitor to, or nil when `url` is not one of the known forms or the destination is not a plain web address.
    static func destination(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host?.lowercased() else { return nil }
        guard let redirector = redirectors.first(where: { $0.hosts.contains(host) }) else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        guard redirector.path == "/" || path == redirector.path || path == redirector.path + "/" else { return nil }
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for name in redirector.parameters {
            guard let value = items.first(where: { $0.name == name })?.value, let target = plainWebAddress(value) else { continue }
            // A redirect that points back at itself would loop; a destination on the same host is not a tracker hop.
            if target.host?.lowercased() == host { continue }
            return target
        }
        return nil
    }

    private static func plainWebAddress(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".") else { return nil }
        return url
    }
}
