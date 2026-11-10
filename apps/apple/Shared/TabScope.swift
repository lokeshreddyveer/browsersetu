import Foundation

/// Which tabs a list, a count, a saved session or a restore point may show. There is one answer, here, so a new kind of tab (an Essential, a Glance preview, a
/// web panel's page) is kept out of all of them by changing one place.
@MainActor
extension BrowserModel {
    /// A page that is not in any list at all: the web panel's page and a Glance preview.
    func isHiddenTab(_ tab: TabController) -> Bool { tab.id == panelTabID || tab.workspace == GlanceCoordinator.hiddenWorkspace }

    /// Whether the tab belongs in a workspace's lists: not hidden, and not an Essential (an Essential is shown with the Essentials, in every workspace).
    func belongsInLists(_ tab: TabController) -> Bool { !isHiddenTab(tab) && tabMeta[tab.id]?.essential == nil }

    /// The tabs of one workspace as every list, count, session and restore point sees them, in tab order.
    func listedTabs(inWorkspace name: String, includePrivate: Bool = true) -> [TabController] {
        tabs.filter { $0.workspace == name && belongsInLists($0) && (includePrivate || !$0.isPrivate) }
    }
}
