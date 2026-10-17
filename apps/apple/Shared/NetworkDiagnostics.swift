import Foundation

/// Why a page could not be loaded, in words a person can act on. It is worked out from what the system reported about the failed
/// load; nothing is sent anywhere to find out.
enum NetworkProblem: Equatable {
    case offline, timedOut, siteNotFound, cannotConnect, connectionLost, certificate, blocked, other

    init(description: String) {
        let text = description.lowercased()
        if text.contains("certificate") || text.contains("secure connection") || text.contains("ssl") { self = .certificate }
        else if text.contains("offline") || text.contains("not connected to the internet") || text.contains("internet connection appears") { self = .offline }
        else if text.contains("timed out") { self = .timedOut }
        else if text.contains("could not be found") || text.contains("hostname") || text.contains("server with the specified") { self = .siteNotFound }
        else if text.contains("could not connect") || text.contains("cannot connect") || text.contains("refused") { self = .cannotConnect }
        else if text.contains("connection was lost") || text.contains("network connection") || text.contains("reset") { self = .connectionLost }
        else if text.contains("blocked") || text.contains("not allowed") { self = .blocked }
        else { self = .other }
    }

    var title: String {
        switch self {
        case .offline: "You’re offline"
        case .timedOut: "The site took too long"
        case .siteNotFound: "That site can’t be found"
        case .cannotConnect: "Can’t connect to the site"
        case .connectionLost: "The connection was interrupted"
        case .certificate: "This connection isn’t private"
        case .blocked: "This page was blocked"
        case .other: "Can’t open this page"
        }
    }

    /// What to try, most likely first.
    var advice: [String] {
        switch self {
        case .offline: ["Check that Wi-Fi or mobile data is on and that Airplane Mode is off.", "This page loads again by itself when the connection is back."]
        case .timedOut: ["The site or your connection is slow. Try again in a moment.", "If other sites load, the problem is with this one."]
        case .siteNotFound: ["Check the address for a typing mistake.", "If it is right, the site may be down, or your network cannot look it up."]
        case .cannotConnect: ["The site may be down for everyone. Try again later.", "If it works on another network, this one may be blocking it."]
        case .connectionLost: ["Your connection dropped while the page loaded. Try again.", "On public Wi-Fi, a sign-in page may need to be opened first."]
        case .certificate: ["The site’s security certificate could not be verified, so nothing was loaded.", "Someone may be trying to impersonate the site, or its certificate may have expired."]
        case .blocked: ["Browser Setu’s protection blocked this. If the page looks broken, open the menu and choose Disable Blocker for this site."]
        case .other: ["Try again. If it keeps happening, check the address and your connection."]
        }
    }

    /// Whether loading it again by itself is worth doing once the connection returns.
    var retriesAutomatically: Bool { self == .offline || self == .connectionLost || self == .timedOut }

    func detail(raw: String) -> String { (advice + ["", raw]).joined(separator: "\n") }
}
