import SwiftUI

/// What the user has written down about one tab: a name of their own, a colour, where it stands in their work, a note, which tab it was opened from,
/// and which separate identity (container) it browses in. Kept per tab id, on this device, in this profile.
struct TabMeta: Codable, Equatable {
    var name: String?
    var color: String?
    var status: TabStatus?
    var note: String?
    var parent: UInt64?
    var container: String?
    /// A scratch tab leaves no trace: its own temporary storage, no history, not in Recently Closed, gone when the app quits.
    var scratch: Bool?

    var isEmpty: Bool { name == nil && color == nil && status == nil && note == nil && parent == nil && container == nil && scratch != true }
}

enum TabStatus: String, Codable, CaseIterable, Identifiable {
    case todo, doing, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .todo: "To do"
        case .doing: "In progress"
        case .done: "Done"
        }
    }
    var symbol: String {
        switch self {
        case .todo: "circle"
        case .doing: "circle.lefthalf.filled"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// Two tabs shown side by side, remembered so the same pair can be opened again in one step.
struct SplitTemplate: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var left: String
    var right: String
    var vertical: Bool
}

/// The pure rules behind tab trees, website grouping and the names of containers.
enum TabOrganizing {
    static let maxDepth = 5
    static let scratchContainer = "scratch"

    /// How deep each tab sits under the tab it was opened from. A tab whose parent is gone, or that would make a loop, is at the top.
    static func depths(_ tabs: [(id: UInt64, parent: UInt64?)]) -> [UInt64: Int] {
        let parents = Dictionary(tabs.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var result: [UInt64: Int] = [:]
        for tab in tabs {
            var depth = 0, current = tab.parent, seen: Set<UInt64> = [tab.id]
            while let parent = current, parents[parent] != nil, !seen.contains(parent), depth < maxDepth {
                seen.insert(parent); depth += 1; current = parents[parent] ?? nil
            }
            result[tab.id] = depth
        }
        return result
    }

    /// The order that puts every tab straight after the tab it was opened from (and after that tab's other children), the rest keeping their order.
    static func treeOrder(_ tabs: [(id: UInt64, parent: UInt64?)]) -> [UInt64] {
        let ids = Set(tabs.map(\.id))
        var children: [UInt64: [UInt64]] = [:]
        var roots: [UInt64] = []
        for tab in tabs {
            if let parent = tab.parent, parent != tab.id, ids.contains(parent) { children[parent, default: []].append(tab.id) } else { roots.append(tab.id) }
        }
        var out: [UInt64] = [], seen = Set<UInt64>()
        func visit(_ id: UInt64) {
            guard seen.insert(id).inserted else { return }
            out.append(id)
            for child in children[id] ?? [] { visit(child) }
        }
        for root in roots { visit(root) }
        for tab in tabs where !seen.contains(tab.id) { visit(tab.id) }      // a loop, if one ever got in
        return out
    }

    private static let twoPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "org.au", "co.nz", "co.in", "co.jp", "co.kr", "co.za", "com.br", "com.mx", "com.ar", "com.tr", "com.cn", "com.hk", "com.sg", "com.tw",
    ]

    /// The part of a host people think of as the site: "docs.example.co.uk" is "example.co.uk".
    static func siteName(forHost host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return (twoPartSuffixes.contains(lastTwo) ? labels.suffix(3) : labels.suffix(2)).joined(separator: ".")
    }

    /// A short, friendly group name for a site: "example.co.uk" becomes "Example".
    static func groupName(forSite site: String) -> String {
        let first = site.split(separator: ".").first.map(String.init) ?? site
        return first.prefix(1).uppercased() + first.dropFirst()
    }

    /// A colour for a container, the same every time, from its name.
    static func containerColor(_ name: String) -> GroupColor {
        let all = GroupColor.allCases
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return all[sum % all.count]
    }

    static func cleanContainerName(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 24, clean.lowercased() != scratchContainer,
              clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }) else { return nil }
        return clean
    }
}

extension BrowserModel {
    // MARK: Meta

    func meta(for tab: TabController) -> TabMeta { tabMeta[tab.id] ?? TabMeta() }

    func updateMeta(_ tab: TabController, _ change: (inout TabMeta) -> Void) {
        var value = tabMeta[tab.id] ?? TabMeta()
        change(&value)
        tabMeta[tab.id] = value.isEmpty ? nil : value
        saveTabMeta()
    }

    func saveTabMeta() {
        // Every window's tabs are written together: one window must not erase another's names and colours.
        let live = Set(windows.allTabs.map(\.id))
        var kept: [UInt64: TabMeta] = [:]
        for window in windows.all { for (id, meta) in window.tabMeta where live.contains(id) { kept[id] = meta } }
        saveSetting("tab_meta", encodedMap(Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value) })))
    }

    func setTabName(_ tab: TabController, _ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMeta(tab) { $0.name = clean.isEmpty ? nil : String(clean.prefix(80)) }
    }
    func setTabColor(_ tab: TabController, _ color: GroupColor?) { updateMeta(tab) { $0.color = color?.rawValue } }
    func setTabStatus(_ tab: TabController, _ status: TabStatus?) { updateMeta(tab) { $0.status = status } }
    func setTabNote(_ tab: TabController, _ note: String) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updateMeta(tab) { $0.note = clean.isEmpty ? nil : String(clean.prefix(2000)) }
    }

    func isScratch(_ tab: TabController) -> Bool { tabMeta[tab.id]?.scratch == true }
    func container(of tab: TabController) -> String? { tabMeta[tab.id]?.container }

    // MARK: Tab tree

    /// How far in each tab is drawn when the tab tree is on (0 when it is off).
    func treeDepth(of tab: TabController) -> Int {
        guard tabTree else { return 0 }
        return TabOrganizing.depths(visibleTabs.map { ($0.id, tabMeta[$0.id]?.parent) })[tab.id] ?? 0
    }

    /// A tab opened from another goes straight after it (and its other children) when the tree is on.
    func placeAfterOpener(_ tab: TabController) {
        guard tabTree, let parent = tabMeta[tab.id]?.parent else { return }
        let order = TabOrganizing.treeOrder(tabs.map { ($0.id, tabMeta[$0.id]?.parent) })
        guard let position = order.firstIndex(of: tab.id) else { return }
        let next = order.dropFirst(position + 1).first
        if parent != tab.id { reorder(tab.id, before: next) }
    }

    /// Puts every tab in tree order: each under the tab it was opened from.
    func arrangeAsTree() {
        let order = TabOrganizing.treeOrder(tabs.map { ($0.id, tabMeta[$0.id]?.parent) })
        // Moved from the last to the first, each one placed in front of the one that follows it.
        for (index, id) in order.enumerated().reversed() {
            reorder(id, before: index + 1 < order.count ? order[index + 1] : nil)
        }
    }

    // MARK: Automatic groups, sleeping, scratch tabs, containers

    /// Puts the tabs of each website that has two or more tabs into a group named after it. Tabs already in a group, pinned ones and private ones are left.
    @discardableResult
    func groupTabsByWebsite() -> Int {
        let candidates = tabs.filter { !$0.isPrivate && !$0.isBlank && !$0.pinned && $0.group.isEmpty && $0.workspace == activeWorkspace }
        var bySite: [String: [TabController]] = [:]
        for tab in candidates { if let host = tab.url?.host { bySite[TabOrganizing.siteName(forHost: host), default: []].append(tab) } }
        var moved = 0
        for (site, list) in bySite where list.count >= 2 {
            let name = TabOrganizing.groupName(forSite: site)
            createGroup(name)
            for tab in list { moveTab(tab, to: name); moved += 1 }
        }
        notice = moved == 0 ? "No website has two or more ungrouped tabs." : "Grouped \(moved) tabs by website."
        return moved
    }

    /// Puts every tab to sleep except these, the one in front, pinned and locked ones, sites set to never sleep, and any that are playing or loading.
    @discardableResult
    func suspendAll(except keep: Set<UInt64> = []) async -> Int {
        var slept = 0
        for tab in tabs where !keep.contains(tab.id) && tab.id != activeID && tab.id != splitTabID && tab.id != thirdSplitTabID && !tab.pinned && !isLocked(tab) && !tab.isPrivate && !tab.isBlank && !tab.isDiscarded && !neverSleeps(host: tab.url?.host) {
            if await tab.engine.isBusy() { continue }
            guard tab.id != activeID else { continue }
            tab.discard(reason: "you put all other tabs to sleep")
            slept += 1
        }
        notice = slept == 0 ? "No other tab could be put to sleep." : "Put \(slept) tab\(slept == 1 ? "" : "s") to sleep."
        return slept
    }

    /// A tab with its own temporary storage that leaves nothing behind.
    @discardableResult
    func openScratchTab(url: URL? = nil) -> TabController {
        openTab(url: url, isPrivate: false, container: TabOrganizing.scratchContainer, scratch: true)
    }

    /// Closes the scratch tabs left from a session that ended; called when the app starts.
    func closeLeftoverScratchTabs() {
        for tab in tabs where isScratch(tab) { closeTab(id: tab.id, force: true) }
    }

    @discardableResult
    func openTab(inContainer name: String, url: URL? = nil) -> TabController? {
        guard let clean = TabOrganizing.cleanContainerName(name) else { notice = "A container name is up to 24 letters, numbers, spaces, - or _."; return nil }
        if !containers.contains(clean) { setContainers(containers + [clean]) }
        return openTab(url: url, isPrivate: false, container: clean)
    }

    func setContainers(_ names: [String]) {
        containers = names
        saveSetting("containers", encodedMap(["list": names]))
    }

    /// Forgets a container: its tabs are closed and everything it stored is deleted.
    func deleteContainer(_ name: String) async {
        for tab in tabs where tabMeta[tab.id]?.container == name { closeTab(id: tab.id, force: true) }
        await engine.clearData(profile: profileName + "#" + name)
        setContainers(containers.filter { $0 != name })
    }

    // MARK: Split templates

    func saveSplitTemplate(named name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, let left = active?.url, let other = splitTabID.flatMap({ id in tabs.first { $0.id == id } })?.url else {
            notice = "Open two pages side by side first."; return
        }
        let template = SplitTemplate(name: clean, left: left.absoluteString, right: other.absoluteString, vertical: splitOrientation == .stacked)
        splitTemplates = Array(([template] + splitTemplates.filter { $0.name != clean }).prefix(30))
        saveSetting("split_templates", encodedMap(["list": splitTemplates]))
        notice = "Saved the layout “\(clean)”."
    }

    func openSplitTemplate(_ template: SplitTemplate) {
        guard let left = URL(string: template.left), let right = URL(string: template.right),
              ["http", "https"].contains(left.scheme?.lowercased() ?? ""), ["http", "https"].contains(right.scheme?.lowercased() ?? "") else { return }
        let first = openTab(url: left, isPrivate: false)
        let second = openTab(url: right, isPrivate: false, select: false)
        select(first.id)
        splitOrientation = template.vertical ? .stacked : .sideBySide
        openSplit(with: second)
    }

    func deleteSplitTemplate(_ template: SplitTemplate) {
        splitTemplates.removeAll { $0.id == template.id }
        saveSetting("split_templates", encodedMap(["list": splitTemplates]))
    }
}


/// Small marks beside a tab's title: its colour, where it stands, whether it has a note, and the container it browses in.
struct TabBadges: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        let meta = model.tabMeta[tab.id]
        HStack(spacing: 4) {
            if let color = meta?.color.flatMap(GroupColor.init(rawValue:)) { Circle().fill(color.color).frame(width: 7, height: 7).accessibilityLabel("\(color.title) label") }
            if let status = meta?.status { Image(systemName: status.symbol).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).accessibilityLabel(status.title) }
            if meta?.note != nil { Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Has a note") }
            if let container = meta?.container {
                if container == TabOrganizing.scratchContainer {
                    Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(.secondary).accessibilityLabel("Scratch tab")
                } else {
                    Text(String(container.prefix(1)).uppercased()).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 13, height: 13).background(Circle().fill(TabOrganizing.containerColor(container).color))
                        .accessibilityLabel("Container \(container)")
                }
            }
        }
    }
}

/// The details of one tab, in its context menu: a name, a colour, a status, a note, and a new tab in a container.
struct TabDetailsMenu: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        Menu("Tab Details") {
            Button("Rename…") { prompt(title: "Name This Tab", message: "A name of your own, shown instead of the page title.", initial: model.tabMeta[tab.id]?.name ?? "") { model.setTabName(tab, $0) } }
            if model.tabMeta[tab.id]?.name != nil { Button("Use the Page Title") { model.setTabName(tab, "") } }
            Menu("Colour") {
                Button("None") { model.setTabColor(tab, nil) }
                ForEach(GroupColor.allCases) { color in Button(color.title) { model.setTabColor(tab, color) } }
            }
            Menu("Status") {
                Button("None") { model.setTabStatus(tab, nil) }
                ForEach(TabStatus.allCases) { status in Button(status.title, systemImage: status.symbol) { model.setTabStatus(tab, status) } }
            }
            Button("Note…") { prompt(title: "Note for This Tab", message: "Kept on this device.", initial: model.tabMeta[tab.id]?.note ?? "") { model.setTabNote(tab, $0) } }
        }
        if !tab.isPrivate {
            Menu("New Tab in Container") {
                ForEach(model.containers, id: \.self) { name in Button(name) { model.openTab(inContainer: name) } }
                Button("New Container…") {
                    prompt(title: "New Container", message: "A container keeps its own cookies and sign-ins, so you can use two accounts on one website.", initial: "") { model.openTab(inContainer: $0) }
                }
            }
        }
    }

    private func prompt(title: String, message: String, initial: String, done: @escaping (String) -> Void) {
        Task { @MainActor in
            if let text = await Dialogs.promptText(title: title, message: message, placeholder: initial) { done(text) }
        }
    }
}
