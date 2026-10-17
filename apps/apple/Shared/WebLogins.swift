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

    /// When on, new and changed passwords are kept where iCloud Keychain carries them to the person's other devices. Set from the model at start.
    nonisolated(unsafe) static var synchronizable = false

    @discardableResult
    static func save(_ login: WebLogin, profile: String) -> Bool {
        guard let data = try? JSONEncoder().encode(login) else { return false }
        return SecretStore.set(data, service: service(profile: profile), account: login.id, synchronizable: synchronizable)
    }

    /// Moves every kept password to iCloud Keychain, or back to this device only. `synced` is how many ended up in iCloud Keychain.
    static func migrate(profile: String, toCloud: Bool) -> (synced: Int, total: Int) {
        let all = list(profile: profile)
        var synced = 0
        for login in all {
            guard let data = try? JSONEncoder().encode(login) else { continue }
            if SecretStore.put(data, service: service(profile: profile), account: login.id, synchronizable: toCloud) == .synced { synced += 1 }
        }
        return (synced, all.count)
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
    /// Runs in every normal page. It watches for a sign-in being sent (the form, the Enter key, or a sign-in button, so logins made with fetch and
    /// single-page apps count too) and for the cursor entering a password field. It speaks to the browser only at those two moments.
    static let watcher = """
    (function () {
      if (window.__bsLoginWatch) return; window.__bsLoginWatch = true;
      const post = (m) => { try { window.webkit.messageHandlers.bsLogin.postMessage(m); } catch (e) {} };
      const visible = (e) => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && !e.disabled; };
      const textTypes = ['text', 'email', 'tel', ''];
      const remembered = () => { try { return sessionStorage.getItem('__bsU') || ''; } catch (e) { return ''; } };
      function read() {
        const pw = [...document.querySelectorAll('input[type=password]')].filter(e => visible(e) && e.value);
        if (!pw.length) return null;
        const field = pw[0];
        const scope = field.form || document;
        const cands = [...scope.querySelectorAll('input')].filter(e => visible(e) && e !== field && textTypes.includes((e.getAttribute('type') || '').toLowerCase()) && e.value);
        const before = cands.filter(e => (e.compareDocumentPosition(field) & Node.DOCUMENT_POSITION_FOLLOWING) !== 0);
        const u = before.length ? before[before.length - 1] : cands[0];
        const user = u ? u.value : remembered();
        if (!user) return null;
        return { origin: location.origin, user: user, password: field.value };
      }
      let last = 0;
      function submit() {
        const r = read(); if (!r) return;
        const now = Date.now(); if (now - last < 4000) return; last = now;
        post({ kind: 'submit', origin: r.origin, user: r.user, password: r.password });
      }
      document.addEventListener('submit', submit, true);
      document.addEventListener('keydown', (e) => { if (e.key === 'Enter' && e.target && e.target.tagName === 'INPUT') submit(); }, true);
      document.addEventListener('click', (e) => {
        const b = e.target && e.target.closest ? e.target.closest('button, input[type=submit], input[type=button], [role=button], a') : null;
        if (!b) return;
        const label = (b.innerText || b.value || b.getAttribute('aria-label') || '');
        if (b.type === 'submit' || /log\\s?in|sign\\s?in|submit|continue|next|enter|verify/i.test(label)) submit();
      }, true);
      // The first step of a two-page sign-in: keep the name typed so the next page, with only the password, still has it.
      document.addEventListener('input', (e) => {
        const t = e.target; if (!t || t.tagName !== 'INPUT') return;
        if (textTypes.includes((t.getAttribute('type') || '').toLowerCase()) && t.value && t.value.length < 200) { try { sessionStorage.setItem('__bsU', t.value); } catch (x) {} }
      }, true);
      // Typing a password is reported a moment after it stops, so the browser can offer to keep it even if the page sends the sign-in in a way nothing sees.
      let typedTimer = 0, lastTyped = '';
      document.addEventListener('input', (e) => {
        const t = e.target; if (!t || t.tagName !== 'INPUT' || t.type !== 'password') return;
        clearTimeout(typedTimer);
        typedTimer = setTimeout(() => {
          const r = read(); if (!r) return;
          const key = r.user + '|' + r.password; if (key === lastTyped) return; lastTyped = key;
          post({ kind: 'typed', origin: r.origin, user: r.user, password: r.password });
        }, 700);
      }, true);
      document.addEventListener('focusin', (e) => { if (e.target && e.target.type === 'password') post({ kind: 'focus', origin: location.origin }); }, true);
    })();
    """

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
