import Foundation

// Skipping a tracker's redirect page, with the safeguards that keep it from ever getting in the way. This is separate from removing tracking parameters (TrackingParameters.swift):
// both are asked from the navigation code, but each has its own switch, its own rules and its own record. Only the known forms in LinkDebouncer are ever followed automatically; a
// link that merely looks like a redirect is never rewritten, it is only described.

extension LinkDebouncer {
    enum Decision: Equatable {
        case none
        /// Go straight to `destination`, skipping the click tracker at `redirector`.
        case skip(destination: URL, redirector: String)
        /// A known redirect that is left alone, and why (a sign-in, a payment, an invitation, a signed link, or a site the person excepted).
        case keep(reason: String)
    }

    /// Query names that carry a sign-in, a session, a signature or an invitation. A link with one of these is never touched.
    static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "code", "state", "nonce", "sig", "signature", "x-amz-signature", "x-amz-credential", "x-goog-signature", "sv", "sp",
        "expires", "session", "sessionid", "sid", "invite", "invitation", "invite_code", "ticket", "otp", "password", "saml", "samlrequest", "samlresponse", "relaystate",
        "client_id", "redirect_uri", "response_type", "scope", "auth", "oauth_token", "magic", "verify", "confirm", "reset",
    ]
    static let sensitivePathWords: [String] = ["oauth", "oauth2", "authorize", "login", "logout", "signin", "sign-in", "sso", "saml", "auth", "checkout", "payment", "pay", "billing",
                                               "invite", "invitation", "verify", "confirm", "reset", "unsubscribe", "password", "account", "secure"]
    static let sensitiveHostSuffixes: [String] = ["accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "id.apple.com", "paypal.com", "stripe.com",
                                                  "auth0.com", "okta.com", "onelogin.com", "authy.com", "duosecurity.com"]

    /// Why this address belongs to a sign-in, payment, invitation or signed link, or nil when it does not look like one.
    static func sensitiveReason(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if sensitiveHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return "a sign-in or payment site" }
        let segments = url.path.lowercased().split(whereSeparator: { "/-_.".contains($0) && $0 != "-" }).map(String.init)
        if segments.contains(where: { part in sensitivePathWords.contains(part) }) { return "a sign-in, payment or account page" }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, items.contains(where: { sensitiveQueryKeys.contains($0.name.lowercased()) }) { return "a signed or one-time link" }
        if url.user != nil || url.password != nil { return "an address with a name and password in it" }
        return nil
    }

    /// The destination as it will be loaded: http or https only, a plain public host, no name or password, scheme and host in lower case, the default port and the fragment left out.
    static func normalized(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), host.contains("."), parts.user == nil, parts.password == nil, !host.hasSuffix(".local"), !host.hasSuffix(".internal"),
              !UserScriptNet.isLocalHost(host), host.split(separator: ".").contains(where: { label in label.contains(where: { $0.isLetter }) }) else { return nil }     // a plain public name: never an address made of numbers
        if host.unicodeScalars.allSatisfy({ $0.value < 128 }) == false { return nil }          // an address that is not plain ASCII is left to the lookalike check
        parts.scheme = scheme; parts.host = host; parts.fragment = nil
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.url
    }

    /// What to do with a link: skip a known tracker redirect, leave it, or nothing (it is not one). `excepted` holds sites the person said never to skip (the redirect's site, or
    /// the destination's).
    static func decision(for url: URL, excepted: Set<String>) -> Decision {
        guard let direct = destination(for: url), let host = url.host?.lowercased() else { return .none }
        if let reason = sensitiveReason(url) { return .keep(reason: reason) }
        guard let target = normalized(direct) else { return .keep(reason: "a destination that is not a plain web address") }
        if let reason = sensitiveReason(target) { return .keep(reason: reason) }
        for site in [host, target.host?.lowercased()].compactMap({ $0 }) {
            // A site excepted as "facebook.com" covers its subdomains too (l.facebook.com).
            if excepted.contains(where: { site == $0 || site.hasSuffix("." + $0) }) { return .keep(reason: "a site you excepted") }
        }
        return .skip(destination: target, redirector: host)
    }

    private static let hintParameters: Set<String> = ["url", "u", "redirect", "redirect_url", "target", "dest", "destination", "goto", "link", "to", "out", "next", "continue"]
    private static let hintPathWords: Set<String> = ["redirect", "redir", "away", "exit", "go", "out", "link", "click", "r", "l", "jump", "outbound", "external", "track"]

    /// For a link that is NOT a known redirect but looks like one (a path such as /redirect or /out with an address in its query): where it seems to lead. Only ever described to the
    /// person, never followed or rewritten.
    static func unfamiliarDestination(for url: URL) -> URL? {
        guard destination(for: url) == nil, let host = url.host?.lowercased(), sensitiveReason(url) == nil,
              url.path.lowercased().split(whereSeparator: { "/-_.".contains($0) }).contains(where: { hintPathWords.contains(String($0)) }),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        for item in items where hintParameters.contains(item.name.lowercased()) {
            guard let value = item.value, let candidate = URL(string: value), let target = normalized(candidate), sensitiveReason(target) == nil,
                  FaviconStore.key(forHost: target.host) != FaviconStore.key(forHost: host) else { continue }
            return target
        }
        return nil
    }
}

extension BrowserModel {
    /// A known tracker redirect on its way to being skipped: the address to go to instead, or nil to carry on normally. Says what happened and offers the original link.
    func skipRedirect(_ url: URL, in tab: TabController) -> URL? {
        guard debounceLinks else { return nil }
        if tab.redirectBypass == url { tab.redirectBypass = nil; return nil }
        switch LinkDebouncer.decision(for: url, excepted: redirectSkipOff) {
        case .none: return nil
        case .keep: redirectsKept += 1; return nil
        case .skip(let destination, let redirector):
            let now = Date()
            recentStrips.removeAll { now.timeIntervalSince($0) > 5 }
            guard recentStrips.count < 3 else { return nil }          // a page that keeps sending the visit back through a redirect can never loop
            recentStrips.append(now)
            strippedLinkCount += 1
            redirectsSkipped += 1
            notice = "Skipped the click tracker at \(redirector). Going to \(destination.host ?? "the page")."
            noticeUndo = NoticeAction(title: "Use the Original Link") { [weak tab] in tab?.redirectBypass = url; tab?.load(url) }
            return destination
        }
    }

    /// A link that looks like a redirect but is not a known one: it is not changed. The person is told where it seems to lead, and may go there directly.
    func describeUnfamiliarRedirect(_ url: URL, in tab: TabController) {
        guard debounceLinks, let target = LinkDebouncer.unfamiliarDestination(for: url), let host = url.host?.lowercased() else { return }
        let destinationKey = FaviconStore.key(forHost: target.host) ?? ""
        guard !redirectSkipOff.contains(FaviconStore.key(forHost: host) ?? host), !redirectSkipOff.contains(destinationKey), describedRedirects.insert(host + ">" + (target.host ?? "")).inserted else { return }
        notice = "This link goes through \(host) to \(target.host ?? "another site")."
        noticeUndo = NoticeAction(title: "Go to \(target.host ?? "It") Directly") { [weak tab] in tab?.load(target) }
    }

    func setRedirectSkipOff(_ text: String) {
        redirectSkipOff = Set(text.split(whereSeparator: { ", \n;".contains($0) }).compactMap { FaviconStore.key(forHost: String($0).lowercased()) })
        saveSetting("redirect_skip_off", encodedMap(["list": Array(redirectSkipOff).sorted()]))
    }
}
