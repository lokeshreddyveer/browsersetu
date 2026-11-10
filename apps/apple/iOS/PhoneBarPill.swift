import SwiftUI

/// In the Bottom Bar and Top Bar layouts the bar, while a page is read, shrinks in place to a slim strip on the same edge, as Safari's does: the site's name with a lock, and nothing
/// else. A tap brings the whole bar back, a sideways swipe changes tab, a swipe toward the page opens the bar too, and a press and hold opens the same menu as the three dots (⋮).
/// (The floating layouts have their own pills.)
struct PhoneBarStrip: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let atBottom: Bool
    /// The compact layouts: the site sits in a small capsule in the middle of the strip, as the shrunk address bar did, instead of plain text.
    var capsule = false
    @ObservedObject private var icons = FaviconStore.shared

    private var label: String {
        guard !tab.isBlank else { return "Search" }
        let host = displayHost(tab.url)
        return host.isEmpty ? tab.displayTitle : host
    }

    var body: some View {
        Menu {
            PhoneMenuContent(tab: tab)
        } label: {
            HStack(spacing: 6) {
                icon
                Text(label).font(.system(size: capsule ? 12 : 13, weight: capsule ? .medium : .semibold)).lineLimit(1).truncationMode(.middle).foregroundStyle(Color.primary)
            }
            .padding(.horizontal, capsule ? 12 : 0)
            .frame(height: capsule ? 26 : nil)
            .frame(maxWidth: capsule ? 190 : .infinity)
            .background { if capsule { Capsule(style: .continuous).fill(.quaternary) } }
            .frame(maxWidth: .infinity, minHeight: capsule ? 32 : 34)
            .contentShape(Rectangle())
            .overlay(alignment: atBottom ? .top : .bottom) { LoadingBar(tab: tab, height: 2).id(tab.id) }
        } primaryAction: {
            if !SwipeGuard.recent { UIImpactFeedbackGenerator(style: .light).impactOccurred(); model.expandChrome(userRequested: true) }
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .barSurface(atBottom: atBottom)
        .modifier(TabSwipe(up: atBottom ? .openDock : .nothing))
        .accessibilityLabel("\(label). Show the toolbar")
        .accessibilityIdentifier("bar-pill")
    }

    @ViewBuilder private var icon: some View {
        if tab.isPrivate { Image(systemName: "eye.slash.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.privateAccent) }
        else if tab.isBlank { Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary) }
        else if let url = tab.url, let image = icons.image(forURL: url.absoluteString, points: 14) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 14, height: 14).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: tab.isSecure ? "lock.fill" : "globe").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary)
        }
    }
}
