import SwiftUI

/// The open tabs as one glass capsule along the top of a phone held on its side, as Safari shows them: each tab is its site's icon and name with a thin
/// divider between, and the tab in front is lifted in its own pill with a cross to close it. Tap a tab to switch. Beyond about seven tabs the capsule
/// scrolls and keeps the tab in front in view. A long press gives the same menu as the tab overview.
struct PhoneTabStrip: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let tabs = model.visibleTabs
        HStack(spacing: 8) {
            EssentialsInline(size: 32)
            ScrollViewReader { proxy in
                GeometryReader { geo in
                    // Few tabs share the whole capsule equally, as in Safari; many keep a readable width and scroll.
                    let width = max(120, (geo.size.width - 6) / CGFloat(max(tabs.count, 1)))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                                PhoneTabItem(tab: tab, selected: tab.id == model.activeID, showsDivider: index > 0 && tab.id != model.activeID && tabs[index - 1].id != model.activeID)
                                    .frame(width: width).id(tab.id)
                            }
                        }
                        .padding(.horizontal, 3)
                        .frame(minWidth: geo.size.width)
                    }
                    .onAppear { proxy.scrollTo(model.activeID, anchor: .center) }
                    .onChange(of: model.activeID) { _, id in withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } }
                }
                .frame(height: 34)
                .phoneGlassCapsule()
            }
            Button { _ = model.newTab() } label: { Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).frame(width: 34, height: 34).phoneGlassCapsule() }
                .accessibilityLabel("New tab")
        }
        .padding(.horizontal, PhoneChrome.margin)
        .padding(.bottom, 4)
        .motion(.easeInOut(duration: 0.25), value: tabs.count)
    }
}

private struct PhoneTabItem: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @ObservedObject private var icons = FaviconStore.shared
    let selected: Bool
    let showsDivider: Bool

    private var name: String {
        if tab.isBlank { return tab.isPrivate ? "Private" : "Start Page" }
        let host = displayHost(tab.url)
        return tab.title.isEmpty ? (host.isEmpty ? "Untitled" : host) : tab.title
    }

    var body: some View {
        // The name sits in the middle of the tab; the close cross (tab in front) or the site's icon is at its leading edge.
        ZStack {
            HStack(spacing: 7) {
                if selected { Color.clear.frame(width: 22, height: 22) } else { iconWithCapture }
                Text(name).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                Color.clear.frame(width: selected ? 22 : 0, height: 1)
            }
            .padding(.horizontal, 6)
            if selected {
                HStack {
                    Button { model.closeTab(id: tab.id) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.hierarchical).frame(width: 28, height: 28) }
                        .accessibilityLabel("Close tab")
                    Spacer()
                }
                .padding(.leading, 4)
            }
        }
        .frame(maxHeight: .infinity)
        .background {
            if selected { Capsule().fill(Color.primary.opacity(0.14)).padding(.vertical, 3) }
        }
        .overlay(alignment: .leading) {
            if showsDivider { Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 0.5, height: 16) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(tab.id) }
        .motion(.easeInOut(duration: 0.2), value: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(name)
        .contextMenu { TabMenuItems(tab: tab) }
    }

    private var iconWithCapture: some View {
        icon.overlay(alignment: .topTrailing) {
            if tab.usesCamera || tab.usesMicrophone {
                Circle().fill(Color.red).frame(width: 7, height: 7).overlay(Circle().strokeBorder(.background, lineWidth: 1)).offset(x: 3, y: -3)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel(tab.usesCamera ? "Using the camera" : "Using the microphone")
            }
        }
        .motion(.easeOut(duration: 0.18), value: tab.usesCamera || tab.usesMicrophone)
    }

    @ViewBuilder private var icon: some View {
        if tab.isLoading { ProgressView().controlSize(.mini).frame(width: 18, height: 18) }
        else if tab.isBlank { Image(systemName: tab.isPrivate ? "eye.slash" : "square.grid.2x2").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 18, height: 18) }
        else if let url = tab.url, let image = icons.image(forURL: url.absoluteString, points: 18) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 18)
        }
    }
}
