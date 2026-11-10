import SwiftUI

/// A site kept within reach in every workspace. An Essential belongs to the profile, not to a workspace: switching workspaces neither copies nor recreates it.
/// The record says where to go and in which separate identity (container) to browse; the live page is an ordinary tab of the window, marked with the
/// record's id, so its web view, history and scroll place are reused when the Essential is opened again.
struct EssentialTab: Codable, Identifiable, Equatable {
    var id: String
    /// The profile that owns it. A record that turns up in another profile (an import, a copied settings file) is ignored, never opened there: its cookies
    /// must not meet another profile's.
    var profile: String
    var url: String
    var title: String
    /// The container it browses in (a separate cookie jar inside the profile), or nil for the profile's own.
    var container: String?
    var position: Int
    var createdAt: Date
}

/// The pure rules behind Essentials.
enum Essentials {
    static let maxCount = 12

    /// Only ordinary web pages: not Settings, not a panel, not a file, not a blank page.
    static func isEligible(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return url.absoluteString.count <= 2048
    }

    /// The address without a fragment, for telling whether two records point at the same page.
    static func comparable(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        var text = parts?.string ?? url.absoluteString
        if text.hasSuffix("/") { text.removeLast() }
        return text.lowercased()
    }

    static func isDuplicate(_ list: [EssentialTab], url: URL, container: String?) -> EssentialTab? {
        list.first { other in
            other.container == container && URL(string: other.url).map { comparable($0) == comparable(url) } == true
        }
    }

    /// What is kept from a stored list: only this profile's records, once each, in their order, at most `maxCount`, positions closed up.
    static func normalized(_ list: [EssentialTab], profile: String) -> [EssentialTab] {
        var seen = Set<String>()
        let mine = list.filter { $0.profile == profile && isEligible(URL(string: $0.url)) && seen.insert($0.id).inserted }
        return Array(mine.sorted { ($0.position, $0.createdAt) < ($1.position, $1.createdAt) }.prefix(maxCount))
            .enumerated().map { index, item in var copy = item; copy.position = index; return copy }
    }

    /// The same list with positions 0, 1, 2… in list order.
    static func renumbered(_ list: [EssentialTab]) -> [EssentialTab] {
        list.enumerated().map { position, entry in var e = entry; e.position = position; return e }
    }

    /// The list with `id` moved so that it ends up at `index` (clamped).
    static func moved(_ list: [EssentialTab], id: String, to index: Int) -> [EssentialTab] {
        guard let from = list.firstIndex(where: { $0.id == id }) else { return list }
        var copy = list
        let item = copy.remove(at: from)
        copy.insert(item, at: max(0, min(index, copy.count)))
        return renumbered(copy)
    }

    static func title(for url: URL, pageTitle: String) -> String {
        let clean = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty ? (url.host ?? "Site") : clean).prefix(80))
    }
}

@MainActor
extension BrowserModel {
    // MARK: Lookup

    func isEssentialTab(_ tab: TabController) -> Bool { tabMeta[tab.id]?.essential != nil }

    /// The open tab that is this Essential's page in this window, if there is one.
    func liveTab(for essential: EssentialTab) -> TabController? {
        tabs.first { tabMeta[$0.id]?.essential == essential.id }
    }

    func essentialRecord(for tab: TabController) -> EssentialTab? {
        guard let id = tabMeta[tab.id]?.essential else { return nil }
        return essentials.first { $0.id == id }
    }

    /// Why this tab cannot become an Essential, or nil when it can.
    func essentialObstacle(for tab: TabController) -> String? {
        if isGuest || tab.isPrivate { return "Private tabs leave nothing behind, so they cannot be Essentials." }
        if isScratch(tab) { return "A scratch tab is gone when the app quits, so it cannot be an Essential." }
        if isEssentialTab(tab) { return "That tab is already an Essential." }
        guard Essentials.isEligible(tab.url) else { return "Only web pages can be Essentials." }
        if essentials.count >= Essentials.maxCount { return "You can keep up to \(Essentials.maxCount) Essentials." }
        if let url = tab.url, Essentials.isDuplicate(essentials, url: url, container: tabMeta[tab.id]?.container) != nil { return "That page is already an Essential." }
        return nil
    }

    // MARK: Adding and removing

    /// Makes the tab an Essential. The tab itself is kept (its page, history and container), so nothing reloads. It leaves its workspace's list and shows up
    /// among the Essentials in every workspace.
    @discardableResult
    func addToEssentials(_ tab: TabController) -> Bool {
        if let reason = essentialObstacle(for: tab) { notice = reason; return false }
        guard let url = tab.url else { return false }
        let record = EssentialTab(id: UUID().uuidString, profile: profileName, url: url.absoluteString, title: Essentials.title(for: url, pageTitle: tab.title),
                                  container: tabMeta[tab.id]?.container, position: essentials.count, createdAt: Date())
        // The tabs opened from it keep a place in the tree, and a pinned tab is no longer pinned: it is better than pinned now.
        adoptChildren(ofClosing: tab.id)
        if tab.pinned { tab.pinned = false; try? core.setTabPinned(tabId: tab.id, pinned: false) }
        if !tab.group.isEmpty { try? core.setTabGroup(tabId: tab.id, group: ""); tab.group = "" }
        updateMeta(tab) { $0.essential = record.id; $0.parent = nil }
        forgetPinnedAddress(for: tab)
        essentials.append(record)
        saveEssentials()
        // The tab in front was in the list being shown; if it still is the tab in front, the list now shows its neighbours.
        saveSoon()
        objectWillChange.send()
        return true
    }

    /// Removes the Essential. Its open page stays, as an ordinary tab of the workspace in front.
    func removeFromEssentials(_ id: String) {
        guard let record = essentials.first(where: { $0.id == id }) else { return }
        if let tab = liveTab(for: record) { releaseEssentialTab(tab) }
        essentials = Essentials.renumbered(essentials.filter { $0.id != id })
        saveEssentials()
        objectWillChange.send()
    }

    /// The page of a removed Essential becomes a normal tab here.
    private func releaseEssentialTab(_ tab: TabController) {
        updateMeta(tab) { $0.essential = nil }
        try? core.setTabWorkspace(tabId: tab.id, workspace: activeWorkspace)
        tab.workspace = activeWorkspace
        if tab.group != activeGroup { try? core.setTabGroup(tabId: tab.id, group: activeGroup); tab.group = activeGroup }
    }

    // MARK: Opening

    /// Shows the Essential: its open page if there is one, else a new tab in the Essential's own container. It never changes the workspace in front.
    func openEssential(_ id: String) {
        guard !isGuest, let record = essentials.first(where: { $0.id == id }) else { return }
        if let tab = liveTab(for: record) { select(tab.id); return }
        guard let url = URL(string: record.url), Essentials.isEligible(url) else { notice = "That Essential’s address is not valid any more."; return }
        // Never fall back to another identity: a container that is gone means the Essential cannot be opened as it was.
        if let container = record.container, !containers.contains(container) {
            notice = "The container “\(container)” no longer exists, so “\(record.title)” was not opened. Remove it from Essentials or recreate the container."
            return
        }
        _ = openTab(url: url, isPrivate: false, container: record.container, essential: record.id)
    }

    /// Opens the Essential in a window of its own, in the same container. The other windows' tabs are untouched.
    func openEssentialInNewWindow(_ id: String) {
        guard !isGuest, let record = essentials.first(where: { $0.id == id }), let url = URL(string: record.url), Essentials.isEligible(url) else { return }
        if let container = record.container, !containers.contains(container) { notice = "The container “\(container)” no longer exists."; return }
        windows.reopening = [url]
        windows.reopeningContainer = record.container
        windows.onNeedWindow?()
    }

    // MARK: Closing an Essential's page

    /// Closing an Essential’s tab (⌘W) lets go of its page and memory but keeps the Essential: the next tab comes forward, and opening the Essential again
    /// loads it fresh. Returns true when the tab was an Essential and has been dealt with.
    func closeEssentialTabSoftly(_ tab: TabController) -> Bool {
        guard isEssentialTab(tab) else { return false }
        if tab.id == activeID {
            let next = visibleTabs.max { $0.lastActive < $1.lastActive }
            if let next { select(next.id) } else { newTab() }
        }
        forgetSplitPanel(tab.id)
        tab.discard(reason: "you closed this Essential; it loads again when you open it")
        return true
    }

    // MARK: Order

    func moveEssential(_ id: String, to index: Int) {
        let updated = Essentials.moved(essentials, id: id, to: index)
        guard updated != essentials else { return }
        essentials = updated
        saveEssentials()
    }

    func moveEssential(_ id: String, by offset: Int) {
        guard let index = essentials.firstIndex(where: { $0.id == id }) else { return }
        moveEssential(id, to: index + offset)
    }

    // MARK: Storage

    func saveEssentials() {
        saveSetting("essentials", encodedMap(["list": essentials]))
    }

    /// Reads this profile's Essentials, then settles anything out of step with them: a tab marked for an Essential that no longer exists is an ordinary tab again.
    func reloadEssentials() {
        let stored = Self.decodeMap((try? core.getSetting(key: "essentials")) ?? nil, as: [EssentialTab].self)["list"] ?? []
        let clean = Essentials.normalized(stored, profile: profileName)
        if clean != essentials { essentials = clean }
        let known = Set(clean.map(\.id))
        for tab in tabs { if let id = tabMeta[tab.id]?.essential, !known.contains(id) { releaseEssentialTab(tab) } }
    }

    /// A container was deleted: the Essentials that browsed in it go with it (they are never moved to another identity).
    func dropEssentials(inContainer name: String) {
        let doomed = essentials.filter { $0.container == name }
        guard !doomed.isEmpty else { return }
        essentials = Essentials.renumbered(essentials.filter { $0.container != name })
        saveEssentials()
        notice = "Removed \(doomed.count) Essential\(doomed.count == 1 ? "" : "s") that used the container “\(name)”."
    }
}
