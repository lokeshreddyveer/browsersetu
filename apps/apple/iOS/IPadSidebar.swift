import SwiftUI

/// Sidebar for wide iPad windows. Narrow windows (iPhone, Slide Over, small Split View) use the tab overview instead.
struct IPadSidebar: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceMenu().padding(.horizontal, 12).padding(.top, 12)
            GroupChips().padding(.horizontal, 12).padding(.vertical, 8)
            List {
                ForEach(model.visibleTabs) { tab in
                    IPadTabRow(tab: tab, selected: tab.id == model.activeID)
                        .contentShape(Rectangle())
                        .onTapGesture { model.select(tab.id) }
                        .contextMenu { TabMenuItems(tab: tab) }
                }
                .onDelete { idx in idx.map { model.visibleTabs[$0].id }.forEach { model.closeTab(id: $0) } }
            }
            .listStyle(.sidebar)
            Divider().opacity(0.5)
            HStack(spacing: 4) {
                Button { model.newTab() } label: { Label("New Tab", systemImage: "plus").font(.system(size: 15, weight: .medium)).lineLimit(1).fixedSize() }
                    .frame(minHeight: 44)
                Spacer()
                ForEach([("book", "Bookmarks", Sheet.bookmarks), ("clock", "History", .history), ("arrow.down.circle", "Downloads", .downloads), ("gearshape", "Settings", .settings)], id: \.1) { symbol, label, sheet in
                    Button { model.sheet = sheet } label: { Image(systemName: symbol).font(.system(size: 17)).frame(width: 40, height: 44).contentShape(Rectangle()) }
                        .accessibilityLabel(label)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12).padding(.vertical, 2)
        }
        .frame(width: 300)
        .themedBar(fallback: .bar)
        .accessibilityIdentifier("sidebar")
    }
}

struct IPadTabRow: View {
    @ObservedObject var tab: TabController
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if tab.isPrivate {
                Image(systemName: "eye.slash.fill").foregroundStyle(Theme.privateAccent)
            } else {
                SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 22).opacity(tab.isBlank ? 0.4 : 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if tab.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    Text(tab.displayTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
                }
                if tab.isBlank || tab.displayTitle != displayHost(tab.url) {
                    Text(tab.isBlank ? "Start page" : displayHost(tab.url)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if tab.isShowingError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            if tab.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.vertical, 3)
        .listRowBackground(selected ? Theme.accent.opacity(0.18) : Color.clear)
    }
}
