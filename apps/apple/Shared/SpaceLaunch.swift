import SwiftUI

@MainActor
extension BrowserModel {
    /// Shows the workspace a request names, in this window or in a new one (Settings › Workspaces). A name that matches nothing, or more than one workspace,
    /// is answered with a clear message and nothing else happens.
    func openSpace(matching query: String) {
        switch SpaceLookup.resolve(query, in: workspaces) {
        case .failure(let problem):
            notice = problem.message
        case .success(let id):
            #if os(macOS)
            NSApp.activate(ignoringOtherApps: true)
            if spaceRequestsOpenNewWindow, !isGuest {
                windows.openingWorkspace = id
                windows.onNeedWindow?()
                return
            }
            #endif
            if activeWorkspace != id { switchWorkspace(id) }
            notice = "Now in \(id.isEmpty ? SpaceLookup.personalName : id)."
        }
    }
}
