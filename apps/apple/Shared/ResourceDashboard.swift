import SwiftUI

/// A plain view of what the browser is holding: this app's memory, which tabs are awake and which were put to sleep, and why. The system does
/// not report memory for each web page, so tabs are shown by state and by how long ago they were used, not by an invented number.
struct ResourceDashboardView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var memory = currentMemoryFootprint()
    @State private var tick = Date()

    private var tabs: [TabController] { model.tabs.filter { !$0.isPrivate || model.privateMode } }
    private var awake: [TabController] { tabs.filter { !$0.isDiscarded && !$0.isBlank } }
    private var asleep: [TabController] { tabs.filter(\.isDiscarded) }

    var body: some View {
        List {
            Section {
                HStack { Label("Memory used by Browser Setu", systemImage: "memorychip"); Spacer(); Text(Self.format(memory)).monospacedDigit().foregroundStyle(.secondary) }
                HStack { Label("Tabs awake", systemImage: "bolt.fill"); Spacer(); Text("\(awake.count)").foregroundStyle(.secondary) }
                HStack { Label("Tabs asleep", systemImage: "moon.zzz"); Spacer(); Text("\(asleep.count)").foregroundStyle(.secondary) }
                Button { memory = currentMemoryFootprint(); tick = Date() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            } footer: {
                Text("A sleeping tab keeps its place and loads again when you open it. Tabs playing media or loading are never put to sleep. The system does not report memory for each page, so tabs are listed by state.")
            }
            if !awake.isEmpty {
                Section("Awake, least recently used first") {
                    ForEach(awake.sorted { $0.lastActive < $1.lastActive }) { tab in row(tab) }
                }
            }
            if !asleep.isEmpty {
                Section("Asleep") {
                    ForEach(asleep) { tab in row(tab) }
                }
            }
        }
        .accessibilityIdentifier("resource-dashboard")
    }

    private func row(_ tab: TabController) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.displayTitle).lineLimit(1)
                Text(detail(tab)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if tab.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Pinned") }
            if !tab.isDiscarded, tab.id != model.activeID, !tab.isBlank, !tab.isPrivate {
                Button { Task { await model.hibernate(tab); memory = currentMemoryFootprint() } } label: { Image(systemName: "moon.zzz") }
                    .buttonStyle(.borderless).help("Put to sleep").accessibilityLabel("Put \(tab.displayTitle) to sleep")
            }
            Button { model.closeTab(id: tab.id); memory = currentMemoryFootprint() } label: { Image(systemName: "xmark").accessibilityLabel("Close tab") }
                .buttonStyle(.borderless).help("Close").accessibilityLabel("Close \(tab.displayTitle)")
        }
    }

    private func detail(_ tab: TabController) -> String {
        let used = RelativeDateTimeFormatter().localizedString(for: tab.lastActive, relativeTo: tick)
        if tab.isDiscarded { return "Asleep: \(tab.sleepReason). Last used \(used)." }
        if tab.id == model.activeID { return "In use now" }
        return "Last used \(used)\(model.isLocked(tab) ? ". Locked, so it stays awake" : "")"
    }

    static func format(_ bytes: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) }
}
