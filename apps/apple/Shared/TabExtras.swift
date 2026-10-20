import Foundation
import SwiftUI

// MARK: Nested groups

/// Groups nest by writing the parent in the name: "Work/Project A" is the group "Project A" inside "Work".
enum GroupPath {
    static let separator: Character = "/"

    static func parts(_ name: String) -> [String] { name.split(separator: separator).map(String.init) }
    static func depth(_ name: String) -> Int { max(0, parts(name).count - 1) }
    static func leaf(_ name: String) -> String { parts(name).last ?? name }
    static func parent(_ name: String) -> String? {
        let p = parts(name)
        return p.count > 1 ? p.dropLast().joined(separator: String(separator)) : nil
    }

    /// True when `name` is `ancestor` itself or sits anywhere below it.
    static func isInside(_ name: String, of ancestor: String) -> Bool {
        name == ancestor || name.hasPrefix(ancestor + String(separator))
    }

    /// The groups in tree order (each parent, then what is inside it), with parents that were never created added in. Children of a folded
    /// group are left out, and a search keeps only matching groups with the groups above them.
    static func visible(_ names: [String], collapsed: Set<String>, query: String = "") -> [String] {
        var all: [String] = []
        for name in names {
            var path = ""
            for part in parts(name) {
                path = path.isEmpty ? part : path + String(separator) + part
                if !all.contains(path) { all.append(path) }
            }
        }
        func ordered(under parent: String?) -> [String] {
            all.filter { name in Self.parent(name) == parent }
                .flatMap { name in [name] + ordered(under: name) }
        }
        var list = ordered(under: nil)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let hits = list.filter { $0.localizedCaseInsensitiveContains(q) }
            list = list.filter { name in hits.contains { $0 == name || isInside($0, of: name) } }
        } else {
            list = list.filter { name in !collapsed.contains { name != $0 && isInside(name, of: $0) } }
        }
        return list
    }

    static func hasChildren(_ name: String, in names: [String]) -> Bool { names.contains { $0 != name && isInside($0, of: name) } }
}

// MARK: Sorting

enum TabSortOrder: String, CaseIterable, Identifiable {
    case website, title, lastUsed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .website: "By Website"
        case .title: "By Title"
        case .lastUsed: "By Last Used"
        }
    }

    /// Pinned tabs stay ahead; inside each half the order is stable for equal keys.
    static func sorted<T>(_ list: [T], by order: TabSortOrder, pinned: (T) -> Bool, host: (T) -> String, title: (T) -> String, lastUsed: (T) -> Date) -> [T] {
        func key(_ a: T, _ b: T) -> Bool {
            switch order {
            case .website:
                let (x, y) = (host(a).lowercased().replacingOccurrences(of: "www.", with: ""), host(b).lowercased().replacingOccurrences(of: "www.", with: ""))
                return x == y ? title(a).localizedCaseInsensitiveCompare(title(b)) == .orderedAscending : x < y
            case .title: return title(a).localizedCaseInsensitiveCompare(title(b)) == .orderedAscending
            case .lastUsed: return lastUsed(a) > lastUsed(b)
            }
        }
        let indexed = list.enumerated().map { ($0.offset, $0.element) }
        func stable(_ part: [(Int, T)]) -> [T] {
            part.sorted { key($0.1, $1.1) ? true : (key($1.1, $0.1) ? false : $0.0 < $1.0) }.map(\.1)
        }
        return stable(indexed.filter { pinned($0.1) }) + stable(indexed.filter { !pinned($0.1) })
    }
}

// MARK: Snoozed and scheduled tabs

enum ScheduleRepeat: String, Codable, CaseIterable, Identifiable {
    case once, daily, weekdays, weekly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .once: "Once"
        case .daily: "Every Day"
        case .weekdays: "Weekdays"
        case .weekly: "Every Week"
        }
    }
}

/// A page to open later. A snoozed tab is one that runs once; a schedule can repeat.
struct TabSchedule: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String
    var when: Date
    var repeats: ScheduleRepeat = .once
    var snoozed = false

    /// When it opens next after `now`, or nil for a one-time entry that has been used.
    func next(after now: Date, calendar: Calendar = .current) -> Date? {
        switch repeats {
        case .once: return nil
        case .daily: return calendar.nextDate(after: now, matching: calendar.dateComponents([.hour, .minute], from: when), matchingPolicy: .nextTime)
        case .weekly: return calendar.nextDate(after: now, matching: calendar.dateComponents([.weekday, .hour, .minute], from: when), matchingPolicy: .nextTime)
        case .weekdays:
            var date = now
            for _ in 0..<8 {
                guard let d = calendar.nextDate(after: date, matching: calendar.dateComponents([.hour, .minute], from: when), matchingPolicy: .nextTime) else { return nil }
                if !calendar.isDateInWeekend(d) { return d }
                date = d
            }
            return nil
        }
    }
}

enum SnoozeChoice: CaseIterable, Identifiable {
    case inAnHour, thisEvening, tomorrow, nextWeek
    var id: Self { self }
    var title: String {
        switch self {
        case .inAnHour: "In an Hour"
        case .thisEvening: "This Evening"
        case .tomorrow: "Tomorrow Morning"
        case .nextWeek: "Next Monday"
        }
    }

    func date(from now: Date = Date(), calendar: Calendar = .current) -> Date {
        func at(_ hour: Int, after d: Date) -> Date { calendar.nextDate(after: d, matching: DateComponents(hour: hour, minute: 0), matchingPolicy: .nextTime) ?? d.addingTimeInterval(86_400) }
        switch self {
        case .inAnHour: return now.addingTimeInterval(3600)
        case .thisEvening: return at(18, after: now)
        case .tomorrow: return at(9, after: calendar.startOfDay(for: now).addingTimeInterval(86_400 - 1))
        case .nextWeek: return calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 2), matchingPolicy: .nextTime) ?? now.addingTimeInterval(7 * 86_400)
        }
    }
}

/// What to do with the list when time passes: which entries are due, and what each becomes afterwards.
enum ScheduleRules {
    static func run(_ list: [TabSchedule], now: Date) -> (due: [TabSchedule], remaining: [TabSchedule]) {
        var due: [TabSchedule] = [], remaining: [TabSchedule] = []
        for item in list {
            guard item.when <= now else { remaining.append(item); continue }
            due.append(item)
            if let next = item.next(after: now) { var again = item; again.when = next; remaining.append(again) }
        }
        return (due, remaining)
    }
}

// MARK: Model

@MainActor
extension BrowserModel {
    // Sorting

    /// Puts the tabs of the current group in order. Other groups and workspaces keep their places.
    func sortTabs(by order: TabSortOrder) {
        let shown = Set(visibleTabs.map(\.id))
        let sorted = TabSortOrder.sorted(visibleTabs, by: order, pinned: \.pinned, host: { $0.url?.host ?? "" }, title: \.displayTitle, lastUsed: \.lastActive)
        var queue = sorted[...]
        let rearranged = tabs.map { shown.contains($0.id) ? queue.popFirst() ?? $0 : $0 }
        guard rearranged.map(\.id) != tabs.map(\.id) else { return }
        animated(.easeOut(duration: 0.2)) { tabs = rearranged }
        for (i, tab) in tabs.enumerated() { try? core.moveTab(tabId: tab.id, index: UInt32(i)) }
        saveSoon()
        notice = "Tabs sorted \(order.title.lowercased())."
    }

    // Snooze and schedule

    func snooze(_ tab: TabController, until date: Date) {
        guard !tab.isPrivate, !tab.isBlank, let url = tab.url else { notice = "This tab can't be snoozed."; return }
        tabSchedules.append(TabSchedule(url: url.absoluteString, title: tab.displayTitle, when: date, repeats: .once, snoozed: true))
        saveSchedules()
        closeTab(id: tab.id, force: true)
        notice = "Snoozed until \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    func schedule(url: URL, title: String, at date: Date, repeats: ScheduleRepeat) {
        tabSchedules.append(TabSchedule(url: url.absoluteString, title: title, when: date, repeats: repeats))
        saveSchedules()
        notice = "“\(title)” will open \(repeats == .once ? "" : repeats.title.lowercased() + ", first ")\(date.formatted(date: .abbreviated, time: .shortened))."
    }

    func cancelSchedule(_ id: UUID) {
        tabSchedules.removeAll { $0.id == id }
        saveSchedules()
    }

    func saveSchedules() {
        saveSetting("tab_schedules", (try? String(data: JSONEncoder().encode(tabSchedules), encoding: .utf8)) ?? "[]")
    }

    /// Opens whatever is due. Called every few seconds and once at start, so an entry that came due while the app was closed opens at launch.
    func openDueSchedules(now: Date = Date()) {
        guard !tabSchedules.isEmpty else { return }
        let result = ScheduleRules.run(tabSchedules, now: now)
        guard !result.due.isEmpty else { return }
        tabSchedules = result.remaining
        saveSchedules()
        for item in result.due {
            if let url = URL(string: item.url) { _ = openTab(url: url, isPrivate: false, select: false) }
        }
        notice = result.due.count == 1 ? "Opened “\(result.due[0].title)”." : "Opened \(result.due.count) scheduled tabs."
    }

    // Closing a pinned tab

    /// True when the tab is pinned and the browser should ask first.
    func needsPinnedConfirmation(_ id: UInt64) -> Bool {
        protectPinned && (tabs.first { $0.id == id }?.pinned ?? false)
    }

    func confirmClosePinned(_ id: UInt64) {
        Task { @MainActor in
            let choice = await Dialogs.choose(title: "Close this pinned tab?", message: "Pinned tabs are kept for things you want to stay open.", buttons: ["Close Tab", "Keep It"])
            if choice == 0 { closeTab(id: id, force: true) }
        }
    }

    // Idle groups

    /// Groups whose every tab has gone unused for `idle` seconds, none of them in front.
    func inactiveGroups(idle: TimeInterval = 30 * 60, now: Date = Date()) -> [String] {
        let grouped = Dictionary(grouping: tabs.filter { !$0.group.isEmpty && !$0.isPrivate }, by: \.group)
        return grouped.filter { _, members in
            members.allSatisfy { $0.id != activeID && now.timeIntervalSince($0.lastActive) >= idle }
        }.keys.sorted()
    }

    /// Puts to sleep every tab in the idle groups. Tabs playing media, loading, locked or on a never-sleep site stay awake.
    func sleepInactiveGroups() async {
        let groups = Set(inactiveGroups())
        guard !groups.isEmpty else { notice = "No group has been idle for 30 minutes."; return }
        var slept = 0
        for tab in tabs where groups.contains(tab.group) && !tab.isDiscarded && !isLocked(tab) && !neverSleeps(host: tab.url?.host) {
            await hibernate(tab)
            if tab.isDiscarded { slept += 1 }
        }
        notice = "Put \(slept) tab\(slept == 1 ? "" : "s") in \(groups.count) idle group\(groups.count == 1 ? "" : "s") to sleep."
    }

    // Audio

    /// Runs for as long as the window lives: looks for sound in open tabs and opens what has come due.
    func startTabWatch() {
        watchTask?.cancel()
        watchTask = Task { @MainActor [weak self] in
            var tickCount = 0
            // Only the first window opens scheduled pages, or each window would open its own copy.
            if self?.isSecondary == false { self?.openDueSchedules() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(self?.governor.watchInterval ?? 3))
                guard let self else { return }
                if !self.isSecondary { self.openDueSchedules() }
                self.checkMediaSleepTimer()
                await self.updateReadingProgress()
                if tickCount % 3 == 0 { await self.watchResponsiveness() }
                tickCount += 1
                if tickCount % 40 == 0 { self.checkpointTick() }
                await self.pollAudio(tick: tickCount)
            }
        }
    }

    /// Looks for sound in the tab in front and any tab already known to be playing, and in one other tab each time round, so a hundred open tabs are
    /// not all asked a question every few seconds.
    func pollAudio(tick: Int) async {
        let live = tabs.filter { !$0.isDiscarded && !$0.isBlank }
        var chosen = live.filter { $0.id == activeID || $0.playingAudio }
        let others = live.filter { tab in !chosen.contains { $0.id == tab.id } }
        if !others.isEmpty { chosen.append(others[tick % others.count]) }
        for tab in chosen { await tab.refreshAudio() }
    }

    /// Mutes or unmutes every tab that is playing sound.
    func muteAllPlaying(_ on: Bool) {
        for tab in tabs where tab.playingAudio || tab.muted { tab.setMuted(on) }
    }
}


/// A speaker on a tab that is playing sound, crossed out when the tab is muted. Tapping it mutes or unmutes.
struct AudioBadge: View {
    @ObservedObject var tab: TabController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if tab.playingAudio || tab.muted {
            Button { tab.setMuted(!tab.muted) } label: {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(tab.muted ? Color.secondary : Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: !tab.muted && !reduceMotion && MotionStyle.current != .off)
                    .frame(width: 16, height: 16).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.muted ? "Unmute tab" : "Mute tab")
            .help(tab.muted ? "Unmute this tab" : "This tab is playing sound. Click to mute.")
            .transition(.scale.combined(with: .opacity))
        }
    }
}
