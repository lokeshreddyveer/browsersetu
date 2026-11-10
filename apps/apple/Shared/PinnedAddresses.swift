import SwiftUI

/// What is remembered about a pinned tab's address: where it was pinned, an address of the person's own to go back to instead, and whether it starts over
/// when its workspace is left. Kept by the address the tab was pinned at, so it is the same on every device that has a pinned tab for that page; it is
/// saved with the profile and travels with sync's "Site rules and styles". What page the tab is on right now is not saved here: the tab knows that.
struct PinnedTabMetadata: Codable, Equatable {
    var originalURL: String
    var customHomeURL: String?
    var resetOnWorkspaceSwitch: Bool = false

    /// The address "Reset to Pinned Address" goes to.
    var home: String { customHomeURL ?? originalURL }
}

/// The pure rules for pinned addresses.
enum PinnedAddresses {
    /// Why an address typed by the person cannot be used, or nil with the address when it can. Only web addresses: no scripts, files or internal pages; no
    /// user name or password inside the address (a way to pass off one site as another); no blanks or control characters.
    static func parse(_ text: String) -> (url: URL?, problem: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, "Type a web address.") }
        guard trimmed.count <= 2048 else { return (nil, "That address is too long.") }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            return (nil, "An address cannot contain spaces.")
        }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased() else { return (nil, "That is not a web address.") }
        guard scheme == "http" || scheme == "https" else { return (nil, "Only http and https addresses can be pinned.") }
        guard let host = url.host, host.contains(".") || host == "localhost" else { return (nil, "That address has no site name.") }
        guard url.user == nil, url.password == nil else { return (nil, "An address with a user name or password in it cannot be pinned.") }
        return (url, nil)
    }

    /// The key a pin is stored under: the pinned address without its fragment, case or trailing slash.
    static func key(for url: URL) -> String { Essentials.comparable(url) }

    /// The saved list with every entry that is not a valid web address removed (a damaged or hand-edited file).
    static func sanitized(_ map: [String: PinnedTabMetadata]) -> [String: PinnedTabMetadata] {
        var out: [String: PinnedTabMetadata] = [:]
        for (key, value) in map {
            guard parse(value.originalURL).url != nil else { continue }
            var clean = value
            if let custom = clean.customHomeURL, parse(custom).url == nil { clean.customHomeURL = nil }
            out[key] = clean
        }
        return out
    }
}

@MainActor
extension BrowserModel {
    // MARK: Lookup

    func pinnedMetadata(for tab: TabController) -> PinnedTabMetadata? {
        tabMeta[tab.id]?.pinKey.flatMap { pinnedAddresses[$0] }
    }

    /// The address a pinned tab goes back to, or nil when there is none yet.
    func pinnedHome(for tab: TabController) -> URL? {
        pinnedMetadata(for: tab).flatMap { PinnedAddresses.parse($0.home).url }
    }

    // MARK: Registering

    /// A tab was pinned: where it is now is where it was pinned. If the same page already has saved settings (from another device), those are kept.
    func registerPinnedAddress(for tab: TabController) {
        guard tab.pinned, !tab.isPrivate, let url = tab.url, Essentials.isEligible(url) else { return }
        let key = PinnedAddresses.key(for: url)
        if pinnedAddresses[key] == nil { pinnedAddresses[key] = PinnedTabMetadata(originalURL: url.absoluteString); savePinnedAddresses() }
        updateMeta(tab) { $0.pinKey = key }
    }

    /// A tab is no longer pinned (or became an Essential): its link to the saved address ends, and the saved address goes if no other pinned tab uses it.
    func forgetPinnedAddress(for tab: TabController) {
        guard let key = tabMeta[tab.id]?.pinKey else { return }
        updateMeta(tab) { $0.pinKey = nil }
        pendingPinnedResets.remove(tab.id)
        if !tabs.contains(where: { $0.id != tab.id && tabMeta[$0.id]?.pinKey == key }), pinnedAddresses[key] != nil {
            pinnedAddresses[key] = nil
            savePinnedAddresses()
        }
    }

    /// Pinned tabs from before this feature have no saved address: the page they are on now becomes it, the first time one is asked about.
    @discardableResult
    func ensurePinnedMetadata(for tab: TabController) -> PinnedTabMetadata? {
        if let existing = pinnedMetadata(for: tab) { return existing }
        registerPinnedAddress(for: tab)
        return pinnedMetadata(for: tab)
    }

    // MARK: Actions

    /// Back to the pinned address in the same tab: its page, container and history are kept, and the pinned page is simply the newest entry.
    func resetPinnedTab(_ tab: TabController, becauseOfWorkspaceSwitch automatic: Bool = false) {
        guard tab.pinned, let meta = ensurePinnedMetadata(for: tab), let home = PinnedAddresses.parse(meta.home).url else { return }
        if let current = tab.url, PinnedAddresses.key(for: current) == PinnedAddresses.key(for: home) {
            if !automatic { notice = "This tab is already at its pinned address." }
            return
        }
        tab.goToAddress(home)
        if !automatic { notice = "Back at the pinned address." }
    }

    /// The page in front becomes the address this pinned tab returns to.
    func setCurrentPageAsPinnedAddress(_ tab: TabController) {
        guard tab.pinned, var meta = ensurePinnedMetadata(for: tab), let key = tabMeta[tab.id]?.pinKey else { return }
        guard let url = tab.url, Essentials.isEligible(url) else { notice = "Only a web page can be a pinned address."; return }
        meta.customHomeURL = PinnedAddresses.key(for: url) == PinnedAddresses.key(for: URL(string: meta.originalURL) ?? url) ? nil : url.absoluteString
        pinnedAddresses[key] = meta
        savePinnedAddresses()
        notice = "This page is now the pinned address."
    }

    /// Lets the person type the address. Blank goes back to the address the tab was first pinned at.
    func editPinnedAddress(for tab: TabController) {
        guard tab.pinned, let meta = ensurePinnedMetadata(for: tab), let key = tabMeta[tab.id]?.pinKey else { return }
        Task { @MainActor [weak self] in
            guard let answer = await Dialogs.promptText(title: "Pinned Address", message: "The address this tab returns to. Leave it empty to use the address it was pinned at.", placeholder: meta.home) else { return }
            guard let self else { return }
            var updated = meta
            if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.customHomeURL = nil
            } else {
                let parsed = PinnedAddresses.parse(answer)
                guard let url = parsed.url else { notice = parsed.problem; return }
                updated.customHomeURL = PinnedAddresses.key(for: url) == PinnedAddresses.key(for: URL(string: meta.originalURL) ?? url) ? nil : url.absoluteString
            }
            pinnedAddresses[key] = updated
            savePinnedAddresses()
        }
    }

    func setResetOnWorkspaceSwitch(_ tab: TabController, _ on: Bool) {
        guard tab.pinned, var meta = ensurePinnedMetadata(for: tab), let key = tabMeta[tab.id]?.pinKey else { return }
        meta.resetOnWorkspaceSwitch = on
        pinnedAddresses[key] = meta
        savePinnedAddresses()
    }

    // MARK: Workspace switching

    /// A workspace was left: its pinned tabs that start over are marked, and each goes back to its pinned address when it is next shown (a page the person is
    /// not looking at is not loaded in the background).
    func workspaceLeft(_ old: String) {
        for tab in tabs where tab.pinned && tab.workspace == old && tabMeta[tab.id]?.essential == nil {
            guard let meta = pinnedMetadata(for: tab), meta.resetOnWorkspaceSwitch else { continue }
            pendingPinnedResets.insert(tab.id)
        }
    }

    // MARK: Storage

    func savePinnedAddresses() {
        saveSetting("pinned_addresses", encodedMap(pinnedAddresses))
    }

    func loadPinnedAddresses(_ json: String?) {
        pinnedAddresses = PinnedAddresses.sanitized(Self.decodeMap(json, as: PinnedTabMetadata.self))
    }
}
