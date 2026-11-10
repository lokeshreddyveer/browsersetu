import Foundation

/// A workspace is stored by name in several places (its tabs, rules, saved sessions, schedules, extension choices, restore points, the groups it holds). Renaming it
/// must change all of them, in every window, or whatever still holds the old name quietly stops finding it.
@MainActor
extension BrowserModel {
    /// What one window does when a workspace is renamed. Tabs go first, so that changing the workspace in front is not mistaken for leaving it.
    func followWorkspaceRename(from old: String, to new: String) {
        for tab in tabs where tab.workspace == old {
            tab.workspace = new
            try? core.setTabWorkspace(tabId: tab.id, workspace: new)
        }
        if activeWorkspace == old { activeWorkspace = new }
        closedTabs = closedTabs.map { var c = $0; if c.workspace == old { c.workspace = new }; return c }
        renameWorkspaceInCheckpoints(from: old, to: new)
        if let list = groupLists[old] { var all = groupLists; all[old] = nil; all[new] = list; groupLists = all }
        workbench.followWorkspaceRename(from: old, to: new)
        focusRules = focusRules.map { var r = $0; if r.workspace == old { r.workspace = new }; return r }
        let renamed = savedSessions.map { session -> SavedSession in var s = session; if s.workspace == old { s.workspace = new }; return s }
        if renamed != savedSessions { setSavedSessions(renamed) }
        if (try? core.getSetting(key: "startup_workspace")) == old { saveSetting("startup_workspace", new) }
    }
}

@MainActor
extension Workbench {
    /// Rules that file a site into the workspace, and the extensions chosen for it, follow the new name.
    func followWorkspaceRename(from old: String, to new: String) {
        let moved = siteRules.map { rule -> SiteOpenRule in
            var r = rule
            if case .workspace(let name) = r.action, name == old { r.action = .workspace(new) }
            return r
        }
        if moved != siteRules { setSiteRules(moved) }
        if let ids = extensionProfiles[old] {
            extensionProfiles[old] = nil
            setExtensions(ids, forWorkspace: new)
        }
    }
}
