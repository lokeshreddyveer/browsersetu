import SwiftUI

/// A button offered beside a short message (the toast), such as "Undo".
struct NoticeAction {
    let title: String
    let run: () -> Void
}

/// What a closed tab needs to be opened again as it was: its address, where it sat, the container it browsed in and the name, colour and note the person gave it.
struct ClearedTab: Equatable {
    var url: URL
    var title: String
    var group: String
    var workspace: String
    var container: String?
    var name: String?
    var color: String?
    var note: String?
}

enum ClearTabs {
    /// A clear that closes at least this many tabs asks first (unless the person turned that off).
    static let confirmFrom = 8
    /// How many tabs Undo loads at once; the others are brought back asleep.
    static let loadedOnUndo = 5
}

@MainActor
extension BrowserModel {
    /// The tabs "Clear Tabs" would close: every unpinned, unlocked tab of this workspace (in any group), not an Essential, not Settings or a panel, not the
    /// private tabs of another set. Sleeping ones are left out when the person said so.
    func clearableTabs(includeSleeping: Bool? = nil) -> [TabController] {
        let withSleeping = includeSleeping ?? clearIncludesSleeping
        return listedTabs(inWorkspace: activeWorkspace).filter { tab in
            !tab.pinned && !tab.isInternalPage && !lockedTabIDs.contains(tab.id)
                && (!separatesPrivate || tab.isPrivate == privateMode) && (withSleeping || !tab.isDiscarded)
        }
    }

    /// Closes the unpinned tabs of this workspace through the same bulk close as "Close Other Tabs", and offers Undo on the toast. A fresh tab is opened if
    /// none is left in front.
    func clearTabs(includeSleeping: Bool? = nil) {
        let doomed = clearableTabs(includeSleeping: includeSleeping)
        guard !doomed.isEmpty else { notice = "There are no unpinned tabs to clear."; return }
        if doomed.count >= ClearTabs.confirmFrom, clearTabsAsks {
            Task { @MainActor [weak self] in
                let choice = await Dialogs.choose(title: "Close \(doomed.count) tabs?",
                                                  message: "Pinned tabs and Essentials stay. You can undo this right after.",
                                                  buttons: ["Close \(doomed.count) Tabs", "Close and Don't Ask Again", "Cancel"])
                guard let self, choice == 0 || choice == 1 else { return }
                if choice == 1 { clearTabsAsks = false }
                performClear(doomed)
            }
        } else {
            performClear(doomed)
        }
    }

    private func performClear(_ requested: [TabController]) {
        // The list may have changed while a question was open.
        let doomed = requested.filter { tab in tabs.contains { $0.id == tab.id } }
        guard !doomed.isEmpty else { return }
        let snapshot: [ClearedTab] = doomed.compactMap { tab in
            guard !tab.isPrivate, !isScratch(tab), Essentials.isEligible(tab.url), let url = tab.url else { return nil }
            let meta = tabMeta[tab.id]
            return ClearedTab(url: url, title: tab.title, group: tab.group, workspace: tab.workspace, container: meta?.container, name: meta?.name, color: meta?.color, note: meta?.note)
        }
        closeInBulk(doomed, reason: "Before clearing tabs")
        if visibleTabs.isEmpty { newTab() }
        notice = "Closed \(doomed.count) tab\(doomed.count == 1 ? "" : "s")."
        if !snapshot.isEmpty {
            noticeUndo = NoticeAction(title: "Undo") { [weak self] in self?.restore(snapshot) }
        }
    }

    /// Opens the cleared tabs again, in their order, with their group, container and notes; the page in front stays in front.
    private func restore(_ cleared: [ClearedTab]) {
        let front = activeID
        var opened = 0
        for item in cleared {
            if let container = item.container, !containers.contains(container) { continue }      // never open it in another identity
            // The first few load now; the rest wait until they are shown, so bringing back a hundred tabs is not a hundred page loads at once.
            let loadNow = opened < ClearTabs.loadedOnUndo
            let tab = openTab(url: loadNow ? item.url : nil, isPrivate: false, select: false, container: item.container)
            if !loadNow { tab.holdAddress(item.url, title: item.title) }
            opened += 1
            if item.workspace != tab.workspace { moveTab(tab, toWorkspace: item.workspace) }
            if !item.group.isEmpty, groupNames.contains(item.group) { moveTab(tab, to: item.group) }
            updateMeta(tab) { $0.name = item.name; $0.color = item.color; $0.note = item.note }
        }
        if let front, tabs.contains(where: { $0.id == front }) { select(front) }
        notice = "Brought back \(cleared.count) tab\(cleared.count == 1 ? "" : "s")."
    }
}
