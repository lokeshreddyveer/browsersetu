import Foundation

extension BrowserModel {
    /// The rows to show for text that starts with a slash, or nil when the text is not a command and should be handled as usual.
    func slashSuggestions(for query: String) -> [Suggestion]? {
        switch SlashParse.parse(query) {
        case .notACommand:
            return nil
        case .choosing(let list):
            return list.map { Suggestion(kind: .command, title: $0.usage, subtitle: $0.summary, target: "slash:/\($0.rawValue) " + ($0.takesText ? "" : ""), action: nil) }
        case .command(let command, let argument):
            return rows(for: command, argument: argument)
        }
    }

    private func command(_ title: String, _ subtitle: String, id: String, _ run: @escaping @MainActor () -> Void) -> Suggestion {
        Suggestion(kind: .command, title: title, subtitle: subtitle, target: id, action: run)
    }

    private func rows(for command: SlashCommand, argument: String) -> [Suggestion] {
        let word = argument
        let normal = tabs.filter { $0.isPrivate == activeIsPrivate && !$0.isBlank }
        func matching() -> [TabController] { normal.filter { TabMatch.matches(title: $0.displayTitle, url: $0.url?.absoluteString ?? "", words: word) } }
        switch command {
        case .tabs:
            let here = matching().prefix(8).map { tab in
                Suggestion(kind: .openTab, title: tab.displayTitle, subtitle: displayHost(tab.url) + (tab.isDiscarded ? " · asleep" : ""), target: tab.url?.absoluteString ?? "", tabID: tab.id)
            }
            // Tabs in the other windows too: choosing one brings it into this window.
            let elsewhere: [Suggestion] = otherWindows.flatMap { other in
                other.model.tabs.filter { $0.isPrivate == activeIsPrivate && !$0.isBlank && TabMatch.matches(title: $0.displayTitle, url: $0.url?.absoluteString ?? "", words: word) }
                    .prefix(4).map { tab in
                        self.command(tab.displayTitle, displayHost(tab.url) + " · in another window, bring it here", id: "slash-bring-\(tab.id)") { [weak self, weak other = other.model] in
                            guard let self, let other else { return }
                            _ = other.moveTab(tab.id, to: self)
                        }
                    }
            }
            return Array(here) + elsewhere
        case .close:
            let list = matching().filter { !$0.pinned && !isLocked($0) && $0.id != activeID }
            guard !word.isEmpty else { return [Suggestion(kind: .command, title: "/close <words>", subtitle: "Type words from a tab's title or address", target: "slash:/close ", action: nil)] }
            guard !list.isEmpty else { return [Suggestion(kind: .command, title: "No tab to close matches “\(word)”", subtitle: "Pinned, locked and the tab you are on are left alone", target: "slash:/close \(word)", action: nil)] }
            return [self.command("Close \(list.count) tab\(list.count == 1 ? "" : "s") matching “\(word)”", list.prefix(3).map(\.displayTitle).joined(separator: ", "), id: "slash-close-\(word)") { [weak self] in
                for tab in list { self?.closeTab(id: tab.id) }
                self?.notice = "Closed \(list.count) tab\(list.count == 1 ? "" : "s")."
            }]
        case .find:
            guard word.count >= 2 else { return [Suggestion(kind: .command, title: "/find <words>", subtitle: command.summary, target: "slash:/find ", action: nil)] }
            return [self.command("Search “\(word)” in every open tab", "The text of loaded tabs, and the saved copy of tabs that are asleep", id: "slash-find-\(word)") { [weak self] in
                self?.findAllPrefill = word; self?.sheet = .findAll
            }]
        case .group:
            if word.lowercased() == "site" || word.lowercased() == "sites" {
                return [self.command("Group tabs by website", "One group for each site with two or more tabs", id: "slash-group-site") { [weak self] in
                    guard let self else { return }
                    let n = groupTabsByWebsite(); notice = n == 0 ? "No site has two or more tabs." : "Made \(n) group\(n == 1 ? "" : "s")."
                }]
            }
            guard !word.isEmpty, word.count <= 40, let tab = active else {
                return [Suggestion(kind: .command, title: "/group <name>", subtitle: "Move this tab to a group, or type “site” to group all tabs by website", target: "slash:/group ", action: nil)]
            }
            return [self.command("Move this tab to the group “\(word)”", groupNames.contains(word) ? "An existing group" : "A new group", id: "slash-group-\(word)") { [weak self] in self?.moveTab(tab, to: word) }]
        case .sleep:
            return [self.command("Put every other tab to sleep", "Keeps this tab, pinned and locked tabs", id: "slash-sleep") { [weak self] in
                guard let self else { return }
                Task { let n = await self.suspendAll(); self.notice = "Put \(n) tab\(n == 1 ? "" : "s") to sleep." }
            }]
        case .duplicates:
            return [self.command("Close duplicate tabs", "Keeps one copy of each page", id: "slash-dupes") { [weak self] in _ = self?.closeDuplicateTabs() }]
        case .save:
            guard !word.isEmpty else { return [Suggestion(kind: .command, title: "/save <name>", subtitle: command.summary, target: "slash:/save ", action: nil)] }
            return [self.command("Save the open tabs as “\(word)”", "Tabs, pinned state, layout and each page's place", id: "slash-save-\(word)") { [weak self] in self?.saveSession(named: word) }]
        case .open:
            let list = savedSessions.filter { word.isEmpty || $0.name.localizedCaseInsensitiveContains(word) }.prefix(6)
            if list.isEmpty { return [Suggestion(kind: .command, title: word.isEmpty ? "No saved sessions" : "No session named like “\(word)”", subtitle: "Save one with /save <name>", target: "slash:/open ", action: nil)] }
            return list.map { session in self.command("Open “\(session.name)”", "\(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s")", id: "slash-open-\(session.id)") { [weak self] in self?.openSession(session) } }
        case .workspace:
            let list = ([Workspace(name: "", icon: "person", preset: nil)] + workspaces).filter { word.isEmpty || ($0.name.isEmpty ? "personal" : $0.name).localizedCaseInsensitiveContains(word) }.prefix(6)
            return list.map { ws in self.command("Switch to \(ws.name.isEmpty ? "Personal" : ws.name)", "Workspace", id: "slash-ws-\(ws.name)") { [weak self] in self?.switchWorkspace(ws.name) } }
        case .forget:
            return [self.command("Forget this site completely", "Its data, history, permissions and sign-ins", id: "slash-forget") { [weak self] in Task { await self?.forgetActiveSiteCompletely() } }]
        case .privateTab:
            guard !word.isEmpty else { return [self.command("New private tab", "", id: "slash-private") { [weak self] in _ = self?.openTab(url: nil, isPrivate: true) }] }
            return [self.command("Open “\(word)” in a private tab", "", id: "slash-private-\(word)") { [weak self] in
                guard let self else { return }
                if let result = resolveInput(input: word, searchTemplate: searchTemplate) {
                    let target: String
                    switch result { case .url(let u), .search(let u): target = u }
                    _ = openTab(url: URL(string: target), isPrivate: true)
                }
            }]
        case .scratch:
            return [self.command("New scratch tab", "No history, nothing saved, gone when closed", id: "slash-scratch") { [weak self] in self?.openScratchTab() }]
        case .note:
            guard !word.isEmpty, active?.isBlank == false else { return [Suggestion(kind: .command, title: "/note <text>", subtitle: "Open a page first, then type your note", target: "slash:/note ", action: nil)] }
            return [self.command("Add this note to the page", word.prefix(80) + (word.count > 80 ? "…" : ""), id: "slash-note-\(word)") { [weak self] in
                guard let self else { return }
                let old = noteForActivePage()
                setNoteForActivePage(old.isEmpty ? word : old + "\n" + word)
                notice = "Note added."
            }]
        case .split:
            let list = matching().filter { $0.id != activeID }.prefix(6)
            return list.map { tab in self.command("Open “\(tab.displayTitle)” beside this tab", displayHost(tab.url), id: "slash-split-\(tab.id)") { [weak self] in self?.openSplit(with: tab) } }
        case .restore:
            return [self.command("Restore the standard layout", "The way back from any layout", id: "slash-restore") { [weak self] in self?.restoreStandardLayout() }]
        }
    }
}
