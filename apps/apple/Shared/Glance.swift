import SwiftUI

/// How a link is sent to Glance without a menu.
enum GlanceTrigger: String, CaseIterable, Identifiable, Codable {
    case option, control, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .option: "Option-click a link"
        case .control: "Control-click a link"
        case .none: "Only from the link’s menu"
        }
    }
}

enum GlanceRules {
    /// Only an ordinary web address can be glanced at: no scripts, files, data or app links, and nothing that is the browser's own page.
    static func isEligible(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil && url.absoluteString.count <= 4096
    }
}

/// A temporary look at a link, over the page, without leaving it.
///
/// The preview is a real tab that lives outside every tab list (its workspace is one that does not exist, so no list, count, session save, restore point or
/// suggestion picks it up). That gives it the browser's own protections, its own back and forward, and a web view that is simply put into the tab list when the
/// person promotes it, with nothing reloaded.
///
/// **Identity.** It browses in the page's own container (or a private session if the page is private), so it can never see another identity's cookies or reach
/// outside the one it was started from. "Temporary session" in Settings instead gives it storage that is gone when it closes, with no sign-ins.
/// **Pop-ups.** A page in Glance cannot open tabs or windows: a click-made pop-up goes to the preview itself, and one without a click is dropped.
/// **History.** A previewed page is not recorded in history, in suggestions or in Recently Closed unless it is promoted.
/// **Lifetime.** One at a time. It closes when the person closes it, picks another tab or workspace, or closes the tab it came from.
@MainActor
final class GlanceCoordinator: ObservableObject {
    struct Session: Identifiable, Equatable {
        let id = UUID()
        let sourceID: UInt64
        let tabID: UInt64
    }

    /// No real workspace has this name, so the preview's tab is in none.
    static let hiddenWorkspace = "\u{1}glance"

    @Published private(set) var session: Session?
    private unowned let model: BrowserModel

    init(model: BrowserModel) { self.model = model }

    var tab: TabController? { session.flatMap { s in model.tabs.first { $0.id == s.tabID } } }
    func isGlance(_ tab: TabController) -> Bool { session?.tabID == tab.id }

    /// Opens `url` in a floating preview above `source`'s page.
    func present(_ url: URL, from source: TabController) {
        guard model.glanceEnabled else { model.notice = "Glance is turned off. Turn it on in Settings › Tabs."; return }
        guard !model.isGuest || source.isPrivate, GlanceRules.isEligible(url), !source.isInternalPage else { return }
        if isGlance(source) { source.load(url); return }          // a link followed inside the preview stays in the preview
        dismiss(animated: false)                                  // one at a time
        let isPrivate = source.isPrivate || model.isGuest
        let temporary = model.glanceTemporarySession && !isPrivate
        let container = isPrivate ? nil : (temporary ? TabOrganizing.scratchContainer : model.tabMeta[source.id]?.container)
        let preview = model.openTab(url: url, isPrivate: isPrivate, select: false, container: container, scratch: temporary)
        try? model.core.setTabWorkspace(tabId: preview.id, workspace: Self.hiddenWorkspace)
        preview.workspace = Self.hiddenWorkspace
        animated(.spring(response: 0.34, dampingFraction: 0.86)) { session = Session(sourceID: source.id, tabID: preview.id) }
    }

    /// The preview becomes an ordinary tab next to the page it came from, in that page's workspace and group, in the same container. Its web view is the same
    /// one, so its history and place are kept.
    func promote() {
        guard let current = session, let preview = tab else { dismiss(); return }
        let source = model.tabs.first { $0.id == current.sourceID }
        animated(.easeOut(duration: 0.22)) { session = nil }
        let workspace = source?.workspace ?? model.activeWorkspace
        try? model.core.setTabWorkspace(tabId: preview.id, workspace: workspace)
        preview.workspace = workspace
        if let source, !preview.isPrivate, source.group != preview.group { try? model.core.setTabGroup(tabId: preview.id, group: source.group); preview.group = source.group }
        if let source { model.updateMeta(preview) { $0.parent = source.id } }
        // The scratch mark of a temporary session stays: that tab leaves no history either, which is what that setting promised.
        if let source { model.placeNextToOpener(preview, opener: source, foreground: true) }
        if model.tabMeta[preview.id]?.scratch != true, !preview.isPrivate, let url = preview.url {
            try? model.core.commitNavigation(tabId: preview.id, url: url.absoluteString, title: preview.title)
            model.learnVisit(preview, url: url)
        }
        model.select(preview.id)
    }

    /// Closes the preview and everything it loaded.
    func dismiss(animated shouldAnimate: Bool = true) {
        guard let current = session else { return }
        if shouldAnimate { animated(.easeOut(duration: 0.18)) { session = nil } } else { session = nil }
        if let preview = model.tabs.first(where: { $0.id == current.tabID }) { model.closeTab(id: preview.id, force: true) }
    }

    /// A page inside the preview asked for a window. With a click it goes to the preview itself; without one it is dropped.
    func handlePopup(url: URL?, userInitiated: Bool, in preview: TabController) {
        if userInitiated, GlanceRules.isEligible(url), let url { preview.load(url) } else { model.notice = "A pop-up in the preview was blocked." }
    }

    /// Left over from a session that ended while a preview was open (the app quit): such tabs are closed when the browser starts.
    func closeLeftovers() {
        for tab in model.tabs where tab.workspace == Self.hiddenWorkspace && tab.id != session?.tabID { model.closeTab(id: tab.id, force: true) }
    }
}
