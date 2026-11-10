import SwiftUI

/// Real vertical tabs for the phone: a slim column down the left edge that is always there, one tile per tab, with the page beside it. The tabs button folds it out into a
/// list with titles and close buttons, over the page (the page does not move or reflow); tapping a tab, or the button again, folds it back. The floating list is a
/// different choice ("Floating tabs") and is untouched.
struct PhoneTabRail: View {
    @EnvironmentObject var model: BrowserModel
    /// Room the floating bar takes at the top or bottom, which the column keeps clear of so its buttons are never behind it.
    var extraTop: CGFloat = 0
    var extraBottom: CGFloat = 0
    static let collapsedWidth: CGFloat = 54
    static let expandedWidth: CGFloat = 236

    private var expanded: Bool { model.tabRailExpanded }
    private func fold() { withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { model.tabRailExpanded = false } }

    var body: some View {
        // The column keeps its slim width in the layout; the open list is drawn over the page from it.
        Color.clear
            .frame(width: Self.collapsedWidth)
            .overlay(alignment: .leading) {
                column
                    .frame(width: expanded ? Self.expandedWidth : Self.collapsedWidth)
                    .themedBar(fallback: .bar)
                    .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 0.5) }
                    .shadow(color: .black.opacity(expanded ? 0.22 : 0), radius: 14, x: 3)
            }
            .zIndex(10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Tabs")
            .accessibilityIdentifier("tab-rail")
    }

    private var column: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(model.visibleTabs) { tab in
                            PhoneRailTab(tab: tab, current: tab.id == model.activeID, expanded: expanded) { model.select(tab.id); fold() }
                                .id(tab.id)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 6)
                }
                .onAppear { if let id = model.activeID { proxy.scrollTo(id, anchor: .center) } }
                .onChange(of: model.activeID) { _, id in if let id { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) } } }
            }
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                Button { _ = model.newTab() } label: { railGlyph("plus", label: "New tab") }
                if expanded {
                    Button { _ = model.openTab(url: nil, isPrivate: true) } label: { railGlyph("eye.slash", label: "New private tab") }
                    Spacer(minLength: 0)
                    Button { withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { model.tabRailExpanded = false } } label: { railGlyph("sidebar.left", label: "Fold the tabs") }
                }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.accent)
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        // Clear of the status bar and the home indicator; only the colour behind them runs to the edge.
        .safeAreaPadding(.vertical, 4)
        .padding(.top, extraTop).padding(.bottom, extraBottom)
        .background { Color.clear.themedBar(fallback: .bar).ignoresSafeArea() }
    }

    private func railGlyph(_ name: String, label: String) -> some View {
        Image(systemName: name).font(.system(size: 17, weight: .medium)).frame(width: 42, height: 44).contentShape(Rectangle()).accessibilityLabel(label)
    }
}

private struct PhoneRailTab: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let current: Bool
    let expanded: Bool
    let onChoose: () -> Void

    private var host: String { tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "" }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onChoose) {
                HStack(spacing: 10) {
                    ZStack {
                        if tab.isPrivate { Image(systemName: "eye.slash.fill").foregroundStyle(Theme.privateAccent).frame(width: 30, height: 30) }
                        else { SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 30).opacity(tab.isBlank ? 0.45 : 1) }
                        if tab.isLoading { ProgressView().controlSize(.mini).padding(3).background(.ultraThinMaterial, in: Circle()) }
                    }
                    .frame(width: 30, height: 30)
                    if expanded {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.isBlank ? "New Tab" : tab.displayTitle).font(.system(size: 14, weight: current ? .semibold : .regular)).lineLimit(1)
                            if !host.isEmpty { Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Button { model.closeTab(id: tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 28, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close \(tab.displayTitle)")
            }
        }
        .padding(.horizontal, expanded ? 8 : 4).frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(current ? Theme.accent.opacity(0.2) : Color.clear))
        .overlay { if current { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1) } }
        .contextMenu { TabMenuItems(tab: tab) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? .isSelected : [])
    }
}
