import Foundation

/// A sign-in the person chose to keep for a website's own login form. Stored in the Keychain, one item per site and name, separately for each profile.
struct WebLogin: Codable, Equatable, Identifiable {
    var origin: String
    var user: String
    var password: String
    var saved = Date()
    var id: String { WebLoginVault.account(origin: origin, user: user) }
}

enum WebLoginOrigin {
    /// "https://example.com" or "https://example.com:8443": the exact place a sign-in belongs to. Plain http is only accepted for this computer itself, so a password
    /// is never saved for, or filled into, a page anyone on the network could have changed.
    static func normalized(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        return port == defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    static func normalized(_ string: String) -> String? { normalized(URL(string: string)) }
}

enum WebLoginVault {
    static func service(profile: String) -> String { "com.browsersetu.weblogin." + profile }
    static func account(origin: String, user: String) -> String { origin + "\n" + user }

    static func list(origin: String? = nil, profile: String) -> [WebLogin] {
        SecretStore.accounts(service: service(profile: profile)).compactMap { account in
            SecretStore.get(service: service(profile: profile), account: account).flatMap { try? JSONDecoder().decode(WebLogin.self, from: $0) }
        }
        .filter { origin == nil || $0.origin == origin }
        .sorted { $0.saved > $1.saved }
    }

    @discardableResult
    static func save(_ login: WebLogin, profile: String) -> Bool {
        guard let data = try? JSONEncoder().encode(login) else { return false }
        return SecretStore.set(data, service: service(profile: profile), account: login.id)
    }

    static func forget(_ login: WebLogin, profile: String) { SecretStore.delete(service: service(profile: profile), account: login.id) }
    static func removeAll(profile: String) { SecretStore.deleteAll(service: service(profile: profile)) }
}

enum LoginOffer: Equatable {
    case nothing, save, update
}

enum LoginRules {
    static let maxUser = 256, maxPassword = 512

    /// What to ask after a login form was submitted: nothing, save it, or update the password already kept for that name.
    static func offer(origin: String, user: String, password: String, kept: [WebLogin], neverFor: Set<String>) -> LoginOffer {
        guard !user.isEmpty, !password.isEmpty, user.count <= maxUser, password.count <= maxPassword, !neverFor.contains(origin) else { return .nothing }
        if let same = kept.first(where: { $0.origin == origin && $0.user == user }) { return same.password == password ? .nothing : .update }
        return .save
    }

    /// Reads what the page script returned. Anything missing or oversized is refused.
    static func capture(_ raw: [String: Any]?) -> (origin: String, user: String, password: String)? {
        guard let raw, let origin = (raw["origin"] as? String).flatMap(WebLoginOrigin.normalized),
              let user = (raw["user"] as? String)?.trimmingCharacters(in: .whitespaces), let password = raw["password"] as? String,
              !user.isEmpty, !password.isEmpty, user.count <= maxUser, password.count <= maxPassword else { return nil }
        return (origin, user, password)
    }
}

/// The page-side scripts. They run only when the browser asks (before a form is submitted, or when the person chooses to fill); the page never sends anything.
enum LoginScripts {
    static let capture = """
    const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && !e.disabled; };
    const pw = [...document.querySelectorAll('input[type=password]')].filter(e => visible(e) && e.value);
    if (!pw.length) return null;
    const field = pw[0];
    const scope = field.form || document;
    const candidates = [...scope.querySelectorAll('input')].filter(e => visible(e) && e !== field && ['text', 'email', 'tel', ''].includes((e.getAttribute('type') || '').toLowerCase()) && e.value);
    const before = candidates.filter(e => (e.compareDocumentPosition(field) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0);
    const user = (before.length ? before[before.length - 1] : candidates[0]);
    if (!user) return null;
    return { origin: location.origin, user: user.value, password: field.value };
    """

    static let probe = """
    return [...document.querySelectorAll('input[type=password]')].some(e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !e.disabled && !e.readOnly; }) ? location.origin : null;
    """

    static let fill = """
    const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && !e.disabled && !e.readOnly; };
    if (location.origin !== origin) return false;
    const pw = [...document.querySelectorAll('input[type=password]')].find(visible);
    if (!pw) return false;
    const scope = pw.form || document;
    const users = [...scope.querySelectorAll('input')].filter(e => visible(e) && e !== pw && ['text', 'email', 'tel', ''].includes((e.getAttribute('type') || '').toLowerCase()));
    const before = users.filter(e => (e.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0);
    const userField = before.length ? before[before.length - 1] : users[0];
    const set = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      setter.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (userField) set(userField, user);
    set(pw, password);
    return true;
    """
}
