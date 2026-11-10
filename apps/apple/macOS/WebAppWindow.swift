import SwiftUI

/// The window of a web app: the page, and a slim bar with back, forward, reload and the app's name. No tabs, no address bar: the app's rules decide where it may go.
struct WebAppWindowView: View {
    @EnvironmentObject var model: BrowserModel
    let app: WebAppRecord

    var body: some View {
        VStack(spacing: 0) {
            if let tab = model.active {
                WebAppBar(app: app, tab: tab)
                ZStack {
                    EngineViewHost(view: tab.hostView).id(tab.id).tabErrorOverlay(tab)
                }
                .overlay(alignment: .top) { LoadingBar(tab: tab).id(tab.id) }
            } else {
                Color.platformBackground
            }
        }
        .background(Color.platformBackground)
        .accessibilityIdentifier("web-app-window")
    }
}

private struct WebAppBar: View {
    @EnvironmentObject var model: BrowserModel
    let app: WebAppRecord
    @ObservedObject var tab: TabController

    var body: some View {
        HStack(spacing: 6) {
            // The window has no title bar of its own, so the controls start clear of the traffic lights.
            Color.clear.frame(width: 70, height: 1)
            if app.showsNavigation {
                button("chevron.left", disabled: !tab.canGoBack, label: "Back") { tab.goBack() }
                button("chevron.right", disabled: !tab.canGoForward, label: "Forward") { tab.goForward() }
                button(tab.isLoading ? "xmark" : "arrow.clockwise", disabled: false, label: tab.isLoading ? "Stop" : "Reload") { if tab.isLoading { tab.stop() } else { tab.reload() } }
            }
            Spacer()
            Text(app.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button { _ = tab.url.map { NSWorkspace.shared.open($0) } } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless).help("Open this page outside the app").accessibilityLabel("Open outside the app")
            Color.clear.frame(width: 8, height: 1)
        }
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func button(_ symbol: String, disabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 26, height: 26) }
            .buttonStyle(.borderless).disabled(disabled).accessibilityLabel(label)
    }
}
