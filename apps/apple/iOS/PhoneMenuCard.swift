import SwiftUI

/// The contents of the ⋮ menu. It is the system's own menu: iOS draws it, sizes it, blurs it and puts it next to the button, the way it does
/// in Safari, so it always looks like the rest of the phone. A row of the four most-used things on top, New Tab and New Private Tab, the
/// page's own tools, then whatever the user put in the More menu, the two red close actions, and back, forward and reload at the bottom.
struct PhoneMenuContent: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    /// Shown in fixed places in the menu; the list skips them.
    private static let fixed: Set<PhoneAction> = [.newTab, .newPrivateTab, .history, .bookmark, .javaScript, .share, .darkPages, .reader,
                                                  .back, .forward, .reload, .tabs, .copyLink, .find, .settings, .zoomIn, .zoomOut, .zoomReset]

    private var host: String? { tab.url?.host }
    private var blockerOn: Bool { !model.privacy.configuration.isException(host: host) }
    private var extras: [PhoneAction] { model.phoneLayout.more.filter { !Self.fixed.contains($0) } }

    var body: some View {
        ControlGroup {
            Button { model.sheet = .history } label: { Label("History", systemImage: "clock") }
            Button { model.showFind() } label: { Label("Find in Page", systemImage: "doc.text.magnifyingglass") }.disabled(tab.isBlank)
            Button { model.shareActivePage() } label: { Label("Share", systemImage: "square.and.arrow.up") }.disabled(tab.isBlank)
        }
        Section {
            Button { _ = model.newTab() } label: { Label("New Tab", systemImage: "plus.square") }
            Button { model.openTab(url: nil, isPrivate: true) } label: { Label("New Private Tab", systemImage: "plus.square.on.square") }
        }
        Section {
            if !tab.isBlank {
                Button { model.toggleBookmark() } label: {
                    Label(model.activeBookmarked ? "Remove Favorite" : "Favorite", systemImage: model.activeBookmarked ? "star.fill" : "star")
                }
                Button { PhoneAction.reader.run(model, tab) } label: { Label(tab.isReading ? "Exit Reader" : "Reader", systemImage: "doc.plaintext") }
                textSizeMenu
            }
            moreMenu
            Button { model.sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
        Section {
            Button(role: .destructive) { if let id = model.activeID { model.closeTab(id: id) } } label: { Label("Close This Tab", systemImage: "xmark") }
            Button(role: .destructive) { confirmCloseAll() } label: {
                Label("Close All \(model.visibleTabs.count) Tabs", systemImage: "rectangle.on.rectangle.slash")
            }
        }
        ControlGroup {
            Button { tab.goBack() } label: { Label("Back", systemImage: "chevron.left") }.disabled(!tab.canGoBack)
            Button { tab.goForward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(!tab.canGoForward)
            Button { tab.isLoading ? tab.stop() : tab.reload() } label: {
                Label(tab.isLoading ? "Stop" : "Reload", systemImage: tab.isLoading ? "xmark" : "arrow.clockwise")
            }
            .disabled(tab.isBlank)
        }
    }

    private var textSizeMenu: some View {
        Menu {
            Button { tab.zoom(by: 0.1) } label: { Label("Larger Text", systemImage: "plus.magnifyingglass") }
            Button { tab.zoom(by: -0.1) } label: { Label("Smaller Text", systemImage: "minus.magnifyingglass") }
            Button { tab.resetZoom() } label: { Label("Actual Size", systemImage: "arrow.counterclockwise") }
        } label: { Label("Text Size", systemImage: "textformat.size") }
    }

    /// The things used now and then, one level in, so the menu itself stays short.
    private var moreMenu: some View {
        Menu {
            if !tab.isBlank {
                Button { PhoneAction.darkPages.run(model, tab) } label: {
                    Label(model.isDarkSite(host) ? "Undarken" : "Darken", systemImage: model.isDarkSite(host) ? "moon.stars.fill" : "moon.stars")
                }
                Button { model.privacy.toggleSite(host: host); tab.reload() } label: {
                    Label(blockerOn ? "Disable Blocker" : "Enable Blocker", systemImage: blockerOn ? "shield.slash" : "shield")
                }
                Button { tab.toggleJavaScript() } label: {
                    Label(tab.javaScriptOn ? "Turn JavaScript Off" : "Turn JavaScript On", systemImage: "curlybraces")
                }
                Menu {
                    let current = model.siteHasAppearance(host) ? model.effectiveWebsiteAppearance(host: host) : AppearanceMode.system
                    ForEach([AppearanceMode.system, .light, .dark]) { mode in
                        Button { model.setSiteAppearance(host, mode) } label: {
                            Label(mode == .system ? "Follow Settings" : mode.title, systemImage: current == mode ? "checkmark" : (mode == .light ? "sun.max" : (mode == .dark ? "moon" : "circle.lefthalf.filled")))
                        }
                    }
                    Divider()
                    Button { model.resetSiteAppearance(host) } label: { Label("Reset Appearance for This Site", systemImage: "arrow.uturn.backward") }
                } label: { Label("Website Appearance", systemImage: "circle.lefthalf.filled") }
            }
            Button { model.showNetworkSpeed() } label: { Label("Show Network Speed", systemImage: "speedometer") }
            ForEach(extras.filter { !tab.isBlank || $0.isEnabled(model, tab) }) { action in
                Button { action.run(model, tab) } label: {
                    Label(action.title, systemImage: action.isToggle && action.isOn(model, tab) ? "checkmark" : action.symbol(model, tab))
                }
                .disabled(!action.isEnabled(model, tab))
            }
        } label: { Label("More", systemImage: "ellipsis.circle") }
    }

    private func confirmCloseAll() {
        let count = model.visibleTabs.count
        Task { @MainActor in
            let choice = await Dialogs.choose(title: "Close all \(count) tabs?", message: "Pinned tabs are closed too.", buttons: ["Close All", "Cancel"])
            if choice == 0 { model.closeAllTabs() }
        }
    }
}
