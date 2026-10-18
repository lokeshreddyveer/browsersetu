import Foundation

/// Offers to keep a sign-in after a login form is submitted, and fills a kept one when the person agrees. Nothing is read from a page without the browser asking,
/// nothing is kept without a yes, and a private tab is never looked at.
extension BrowserModel {
    /// The tab being looked at is not private, and the person has not turned this off.
    var offersToSaveLogins: Bool { saveLoginsEnabled }

    func setSaveLogins(_ on: Bool) {
        saveLoginsEnabled = on
        saveSetting("save_logins", on ? "1" : "0")
    }

    func neverSaveLogins(for origin: String) {
        neverSaveOrigins.insert(origin)
        saveSetting("never_save_logins", encodedMap(["list": Array(neverSaveOrigins).sorted()]))
    }

    func allowSavingLogins(for origin: String) {
        neverSaveOrigins.remove(origin)
        saveSetting("never_save_logins", encodedMap(["list": Array(neverSaveOrigins).sorted()]))
    }

    func loadLoginSettings(_ get: (String) -> String?) {
        saveLoginsEnabled = get("save_logins") != "0"
        neverSaveOrigins = Set(Self.decodeMap(get("never_save_logins"), as: [String].self)["list"] ?? [])
    }

    /// A login form was submitted in `tab`.
    func loginSubmitted(origin: String, user: String, password: String, in tab: TabController) {
        guard !tab.isPrivate, saveLoginsEnabled, !askingAboutLogin else { return }
        tab.typedLogin = nil
        let offer = LoginRules.offer(origin: origin, user: user, password: password, kept: WebLoginVault.list(origin: origin, profile: profileName), neverFor: neverSaveOrigins)
        guard offer != .nothing else { return }
        askingAboutLogin = true
        Task { @MainActor in
            defer { askingAboutLogin = false }
            // Let the page finish what it is doing before a sheet covers it.
            try? await Task.sleep(for: .milliseconds(700))
            let host = URL(string: origin)?.host ?? origin
            let title = offer == .update ? "Update the saved password for \(user)?" : "Save the password for \(user)?"
            let message = "On \(host). It is kept in your Keychain on this device, for this profile, and you confirm with Touch ID or your password before it is filled in."
            switch await Dialogs.choose(title: title, message: message, buttons: [offer == .update ? "Update" : "Save", "Never for This Site", "Not Now"]) {
            case 0:
                if !WebLoginVault.save(WebLogin(origin: origin, user: user, password: password), profile: profileName) { notice = "The password could not be saved." }
                else { notice = offer == .update ? "Password updated." : "Password saved." }
            case 1: neverSaveLogins(for: origin)
            default: break
            }
        }
    }

    /// After a page has loaded: if kept sign-ins exist for it and it shows a login form, offer to fill. `force` is the menu command and asks even if declined before.
    func offerToFillLogin(in tab: TabController, force: Bool = false, frameOrigin: String? = nil, usernameOnly: Bool = false) {
        guard !tab.isPrivate, !askingAboutLogin, let origin = frameOrigin ?? WebLoginOrigin.normalized(tab.url) else { return }
        let kept = WebLoginVault.list(origin: origin, profile: profileName)
        guard !kept.isEmpty, force || !declinedFill.contains(origin) else { if force { notice = "No saved sign-in for this site." }; return }
        Task { @MainActor in
            // A password field the person just clicked into is proof enough; otherwise the page is asked whether it has a sign-in form.
            var hasForm = frameOrigin != nil
            if !hasForm { hasForm = (await tab.engine.loginFormOrigin()) == origin }
            guard hasForm, !askingAboutLogin else { if force { notice = "No sign-in form on this page." }; return }
            askingAboutLogin = true
            defer { askingAboutLogin = false }
            let names = Array(kept.prefix(3))
            let host = URL(string: origin)?.host ?? origin
            // The first step of a sign-in asks for the name alone. A name is not a secret, so it needs no Touch ID: with one saved name it is filled at once, with several the person picks one.
            // The password is offered, behind Touch ID as always, when the next step shows its password field.
            if usernameOnly {
                var index = 0
                if names.count > 1 {
                    let picked = await Dialogs.choose(title: "Fill in your name?", message: "For \(host).", buttons: names.map(\.user) + ["Not Now"])
                    guard picked < names.count else { return }
                    index = picked
                }
                _ = await tab.engine.fillLogin(origin: origin, user: names[index].user, password: "")
                return
            }
            let choice = await Dialogs.choose(title: "Fill a saved sign-in?", message: "For \(host).", buttons: names.map(\.user) + ["Not Now"])
            guard choice < names.count else { declinedFill.insert(origin); return }
            guard await authenticateForFill(host: host) else { return }
            guard frameOrigin != nil || tab.url.flatMap(WebLoginOrigin.normalized) == origin else { return }       // the page moved on while the sheet was open
            if await tab.engine.fillLogin(origin: origin, user: names[choice].user, password: names[choice].password) { notice = "Filled in." }
            else { notice = "This page did not take the sign-in." }
        }
    }

    /// Always asks for Touch ID or the password before a saved password leaves the Keychain, except for a minute after it was just asked.
    private func authenticateForFill(host: String) async -> Bool {
        if Date().timeIntervalSince(lastAuthentication) < 60 { return true }
        let ok = await BiometricGate.authenticate(reason: "Fill your saved sign-in for \(host)")
        if ok { lastAuthentication = Date() } else { notice = "Not filled: it could not be confirmed." }
        return ok
    }
}

extension BrowserModel {
    /// Adds the passwords from another browser's file. Nothing is overwritten: a name already saved for a site keeps its password.
    func importPasswords(csv: String) -> (added: Int, skippedInsecure: Int, skippedDuplicate: Int) {
        let kept = WebLoginVault.list(profile: profileName)
        let result = PasswordImport.parse(csv: csv, existing: kept)
        var added = 0
        for login in result.logins.prefix(5_000) where WebLoginVault.save(login, profile: profileName) { added += 1 }
        return (added, result.skippedInsecure, result.skippedDuplicate)
    }

    /// History from another browser, written by the core in one transaction away from the main thread.
    func importHistory(_ visits: [HistoryImport.Visit]) async -> Int {
        let core = self.core
        let batch = visits.map { ImportedVisit(url: $0.url, title: $0.title, lastVisit: $0.seconds, visitCount: $0.count) }
        return await Task.detached(priority: .userInitiated) { Int((try? core.importHistory(visits: batch)) ?? 0) }.value
    }
}
