import SwiftUI

extension BrowserModel {
    // MARK: Look-alike addresses

    func lookalikeFinding(host: String) -> LookalikeCheck.Finding? {
        guard lookalikeGuard, !allowedLookalikes.contains(host.lowercased()) else { return nil }
        return LookalikeCheck.check(host: host)
    }

    func presentLookalikeWarning(_ finding: LookalikeCheck.Finding, for url: URL, in tab: TabController) {
        guard let host = url.host?.lowercased(), lookalikePrompting.insert(host).inserted else { return }   // a redirect chain must not stack the same question
        Task { @MainActor [self] in
            defer { lookalikePrompting.remove(host) }
            let choice = await Dialogs.choose(
                title: "This address may be a fake",
                message: "“\(host)” looks like \(finding.imitates.capitalized), but it is not. \(finding.reason) Do not enter a password or payment details here.",
                buttons: ["Go Back", "Continue Anyway"])
            if choice == 1 {
                allowedLookalikes.insert(host)
                tab.load(url)
            }
        }
    }

    // MARK: Panic

    /// Closes every tab of this window, locked and private ones too, and forgets what was recently closed.
    func closeEverythingInThisWindow() {
        privateMode = false
        for tab in tabs { closeTab(id: tab.id, force: true) }
        closedTabs = []
    }

    /// One step that leaves nothing behind: every tab in every window closed (locked and private ones too), the lists of recently closed tabs and windows,
    /// history, the downloads list, website data, time on sites, clipboard history and what the widgets and share sheet hold are erased. Bookmarks, passwords
    /// and settings stay.
    func panic() async {
        let choice = await Dialogs.choose(
            title: "Clear everything now?",
            message: "Closes every tab in every window, including locked and private ones, and erases history, recently closed tabs, the downloads list, website data and cookies, time on sites, copied text and the shared inbox. Bookmarks, passwords and settings stay.",
            buttons: ["Cancel", "Clear Everything"])
        guard choice == 1 else { return }
        for window in windows.all { window.closeEverythingInThisWindow() }
        windows.closedWindows = []
        await clearBrowsingData()
        clipboardHistory = []
        feedItems = []
        clearSiteTime()
        SharedStore.eraseAll()
        if visibleTabs.isEmpty { newTab() }
        notice = "Everything was cleared."
    }

    // MARK: Groups from another device

    /// Opens a group another device sent as a group here, with its tabs inside it.
    func adoptSyncedGroup(_ name: String, tabs list: [BackupPayload.Tab]) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !name.isEmpty else { return }
        if !groupNames.contains(name) { createGroup(name) }
        var opened = 0
        for item in list.prefix(40) {
            guard let url = URL(string: item.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let tab = openTab(url: url, isPrivate: false, select: opened == 0)
            moveTab(tab, to: name)
            opened += 1
        }
        notice = opened == 0 ? "Nothing to open." : "Opened “\(name)” with \(opened) tab\(opened == 1 ? "" : "s")."
    }

    // MARK: Focus schedule

    /// Moves to the workspace of the rule whose time has just begun. A rule is applied once per window, so a switch made by hand afterwards stays.
    func applyFocusSchedule(now: Date = Date()) {
        guard let rule = FocusSchedule.current(focusRules, at: now) else { focusAppliedKey = ""; return }
        let key = FocusSchedule.windowKey(rule, at: now)
        guard key != focusAppliedKey else { return }
        focusAppliedKey = key
        guard rule.workspace.isEmpty || workspaces.contains(where: { $0.name == rule.workspace }), activeWorkspace != rule.workspace else { return }
        switchWorkspace(rule.workspace)
        notice = "\(rule.name) has begun: now in \(rule.workspace.isEmpty ? "Personal" : rule.workspace)."
    }

    // MARK: Asking for a page in plain words

    /// History matches for text such as "pasta recipe last week"; empty when the text names no time.
    func plainRecall(_ text: String, limit: Int = 8) -> (phrase: String, items: [HistoryItem])? {
        guard !activeIsPrivate, let request = PlainRecall.parse(text) else { return nil }
        let pool = (try? core.recentHistory(limit: 4_000)) ?? []
        let found = pool.filter { PlainRecall.matches($0, request) }.sorted { $0.visitCount != $1.visitCount ? $0.visitCount > $1.visitCount : $0.lastVisit > $1.lastVisit }
        return (request.phrase, Array(found.prefix(limit)))
    }
}

// MARK: Daily digest

struct DigestView: View {
    @EnvironmentObject var model: BrowserModel

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Late night"
        }
    }
    private var unread: [ReadingItem] { Array(model.readingList.filter { !$0.read }.prefix(5)) }
    private var news: [FeedItem] {
        Array(model.feedItems.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }.prefix(8))
    }
    private var tasks: [SiteTask] { Array(model.siteTasks.filter { !$0.done }.prefix(5)) }
    private var today: [(host: String, minutes: Int)] {
        (model.siteTimeLog.days[SiteTimeLog.day()] ?? [:]).sorted { $0.value > $1.value }.prefix(3).map { ($0.key, max(1, Int($0.value / 60))) }
    }

    private func open(_ address: String) {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        model.sheet = nil
        _ = model.openTab(url: url, isPrivate: false)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.title2.weight(.bold))
                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide))).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
                Label("\(model.blockedStats.total(.today)) ads and trackers stopped today", systemImage: "shield.lefthalf.filled").foregroundStyle(.secondary)
            }
            if !tasks.isEmpty {
                Section("To do") {
                    ForEach(tasks) { task in
                        HStack {
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading) { Text(task.text); if !task.site.isEmpty { Text(task.site).font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                }
            }
            if !unread.isEmpty {
                Section("Saved to read") {
                    ForEach(unread) { item in
                        Button { open(item.url) } label: {
                            VStack(alignment: .leading, spacing: 2) { Text(item.title).lineLimit(2); Text(item.site).font(.caption).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !news.isEmpty {
                Section("From your feeds") {
                    ForEach(news) { item in
                        Button { open(item.link) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).lineLimit(2)
                                Text([item.feed, item.date.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if !today.isEmpty {
                Section("Your time so far today") {
                    ForEach(today, id: \.host) { LabeledContent($0.host, value: "\($0.minutes) min") }
                }
            }
            if tasks.isEmpty && unread.isEmpty && news.isEmpty {
                Section { Text("Nothing waiting. Save articles to read later, follow a feed or add a task, and they will show up here each day.").foregroundStyle(.secondary) }
            }
        }
        .onAppear { model.loadFeedsIfNeeded() }
    }
}

// MARK: Focus schedule settings

struct FocusScheduleSection: View {
    @EnvironmentObject var model: BrowserModel

    private let days: [(Int, String)] = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    private func time(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minute.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }

    var body: some View {
        Section {
            ForEach($model.focusRules) { $rule in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name", text: $rule.name).textFieldStyle(.plain).font(.headline)
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                    }
                    HStack(spacing: 4) {
                        ForEach(days, id: \.0) { day in
                            let on = rule.weekdays.contains(day.0)
                            Text(day.1).font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 4)
                                .background(Capsule().fill(on ? Theme.accent.opacity(0.2) : Color.primary.opacity(0.06)))
                                .foregroundStyle(on ? Theme.accent : Color.secondary)
                                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { if on { rule.weekdays.remove(day.0) } else { rule.weekdays.insert(day.0) } } }
                        }
                    }
                    HStack {
                        DatePicker("From", selection: time($rule.startMinute), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: time($rule.endMinute), displayedComponents: .hourAndMinute)
                    }.font(.callout)
                    Picker("Workspace", selection: $rule.workspace) {
                        Text("Personal").tag("")
                        ForEach(model.workspaces, id: \.name) { Text($0.name).tag($0.name) }
                    }
                }
                .padding(.vertical, 4)
            }
            .onDelete { model.focusRules.remove(atOffsets: $0) }
            Button { model.focusRules.append(FocusRule(name: "Focus \(model.focusRules.count + 1)")) } label: { Label("Add a Time Rule", systemImage: "plus") }
        } header: { Text("Automatic Switching") } footer: {
            Text("When a rule's time begins, the browser moves to that workspace once. If you switch by hand afterwards, it leaves your choice alone until the next time begins.")
        }
    }
}

struct SafetySettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Section {
            Toggle("Warn about look-alike addresses", isOn: $model.lookalikeGuard)
            Button("Clear Everything Now…", role: .destructive) { Task { await model.panic() } }
        } header: { Text("Safety") } footer: {
            Text("The warning compares an address with well-known sites, on this device only. Clear Everything closes every tab and erases history, downloads list, website data, copied text and the shared inbox; bookmarks, passwords and settings stay.")
        }
    }
}
