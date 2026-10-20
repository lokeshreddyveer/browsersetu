import SwiftUI

/// The iPad's own window: one toolbar row of large touch targets, a strip of tabs under it, and the page. The sidebar slides in
/// from the left for people who like their tabs as a list. Library panels hang from the menu button as a popover.
struct IPadRootView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var showLibrary = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if model.sidebarVisible {
                    IPadSidebar().transition(.move(edge: .leading).combined(with: .opacity))
                    Divider()
                }
                VStack(spacing: 0) {
                    RecoveryBanner()
                    if !barsAway {
                        if let tab = model.active { IPadToolbar(tab: tab, showLibrary: $showLibrary) }
                        IPadTabStrip()
                    }
                    page
                }
                if let docked = model.dockedPanel {
                    DockedPanelView(sheet: docked).transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .motion(.spring(response: 0.38, dampingFraction: 0.88), value: model.sidebarVisible)
            .motion(.easeInOut(duration: 0.26), value: barsAway)
            .motion(.easeOut(duration: 0.22), value: model.dockedPanel)
            if model.overviewVisible { IPadTabOverview().transition(.opacity) }
            if model.showSetup { SetupAssistantView().transition(.opacity).zIndex(10) }
            VStack(spacing: 8) { PendingLoginPill(); PopupBlockedPill() }
                .padding(.top, barsAway ? 64 : 116)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            NoticeToast().padding(.bottom, 40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            DownloadToast(coordinator: model.downloads)
                .padding(.horizontal, 16).padding(.bottom, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .background { Group { if model.themeIsActive { ChromeBackdrop() } else { Color(.systemBackground) } }.ignoresSafeArea() }
        .background { IPadShortcutLayer() }
        // An external keyboard talks to whatever has focus. With nothing focused its keys go nowhere, so the page takes focus whenever
        // the window, the tab or a dialog settles, and the address field keeps it while it is being typed in.
        .onChange(of: scenePhase) { _, phase in if phase == .active { focusPage() } }
        .onChange(of: model.activeID) { _, _ in focusPage() }
        .onChange(of: model.sheet) { _, sheet in if sheet == nil { focusPage() } }
        .onChange(of: model.overviewVisible) { _, shown in if !shown { focusPage() } }
        .onChange(of: model.addressBar.isEditing) { _, editing in if !editing { focusPage() } }
        .onChange(of: showLibrary) { _, shown in if !shown { focusPage() } }
        .onAppear { focusPage() }
        .scrollIndicators(.hidden)
        .motion(.easeOut(duration: 0.18), value: model.overviewVisible)
        .sheet(item: $model.sheet) { SheetContainer(sheet: $0) }
        // A link, a file or some text dragged in from another app opens.
        .sheet(item: $model.storeOffer) { StoreOfferSheet(info: $0) }
        .sheet(item: $model.privacySheet) { PrivacySheetView(kind: $0, privacy: model.privacy) }
        .preferredColorScheme(model.appearance.colorScheme ?? (model.themeIsActive ? model.activeTheme.scheme?.colorScheme : nil))
        .tint(Theme.accent)
    }

    /// One shortcut, from either route: the page's own key commands or the window's button layer.
    private func perform(_ action: ShortcutAction) {
        switch action {
        case .newTab: model.newTab()
        case .newPrivateTab: model.openTab(url: nil, isPrivate: true)
        case .openLocation: model.focusAddressBar()
        case .commandPalette: model.pendingAddressPrefill = ">"; model.focusAddressBar()
        case .closeTab: if let id = model.activeID { model.closeTab(id: id) }
        case .reopenClosedTab: model.reopenClosedTab()
        case .back: model.active?.goBack()
        case .forward: model.active?.goForward()
        case .reload: model.active?.reload()
        case .stop: model.active?.stop()
        case .nextTab: model.selectAdjacent(1)
        case .previousTab: model.selectAdjacent(-1)
        case .tabOverview: if model.overviewVisible { model.hideOverview() } else { model.showOverview() }
        case .find: model.showFind()
        case .bookmarkPage: model.toggleBookmark()
        case .showBookmarks: model.sheet = .bookmarks
        case .showHistory: model.sheet = .history
        case .showDownloads: model.sheet = .downloads
        case .toggleSidebar: model.sidebarVisible.toggle()
        case .zoomIn: model.active?.zoom(by: 0.1)
        case .zoomOut: model.active?.zoom(by: -0.1)
        case .actualSize: model.active?.resetZoom()
        default: break
        }
    }

    /// Hands keyboard focus to the page, unless the address field is being typed in.
    private func focusPage() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !model.addressBar.isEditing, model.sheet == nil, !model.overviewVisible,
                  let view = model.active?.hostView as? UIView, view.window != nil else { return }
            var responder: UIResponder? = view
            while let next = responder?.next {
                if let controller = next as? KeyCommandController { controller.claimKeyboard(); return }
                responder = next
            }
        }
    }

    /// While a page is read the toolbar and tabs slide away and the page takes the room; a small pill at the top brings them back.
    private var barsAway: Bool { model.chromeCollapsed && model.canCollapseChrome && !model.addressBar.isEditing && !model.overviewVisible }

    @ViewBuilder private var page: some View {
        if let tab = model.active {
            ZStack {
                IPadPageHost(view: tab.hostView, shortcuts: model.shortcuts, perform: { perform($0) }, performTab: { model.selectTab(number: $0) }).id(tab.id)
                    .transition(model.tabSlide == 0 ? .opacity : .push(from: model.tabSlide > 0 ? .trailing : .leading))
                if tab.isBlank { StartPageView(isPrivate: tab.isPrivate) }
                // Suggestions drop from under the address field as one card, never over the pill or another dialog.
                if !model.overviewVisible { IPadSuggestions(address: model.addressBar) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .top) { LoadingBar(tab: tab).id(tab.id).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
            .overlay(alignment: .bottom) { WebStoreBanner().padding(.bottom, 12) }
            .overlay(alignment: .top) {
                if barsAway { IPadReturnPill(tab: tab).padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity)) }
            }
            .padding(.horizontal, 12).padding(.bottom, 12)
            .motion(.easeInOut(duration: 0.26), value: model.activeID)
        } else {
            Color.clear
        }
    }
}

/// Everything on one line, every control 44 points: the sidebar, back and forward, the address, then share, new tab, tabs and the menu.
private struct IPadToolbar: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    @Binding var showLibrary: Bool

    var body: some View {
        HStack(spacing: 4) {
            key("sidebar.left", "Sidebar", on: model.sidebarVisible) { model.sidebarVisible.toggle() }
            key("chevron.left", "Back", enabled: tab.canGoBack) { tab.goBack() }
                .contextMenu { NavHistoryItems(tab: tab, back: true) }
            key("chevron.right", "Forward", enabled: tab.canGoForward) { tab.goForward() }
                .contextMenu { NavHistoryItems(tab: tab, back: false) }
            HStack {
                Spacer(minLength: 0)
                PhoneAddressBar(tab: tab, address: model.addressBar)
                    .frame(maxWidth: 620)
                Spacer(minLength: 0)
            }
            if let url = tab.url, !tab.isBlank {
                ShareLink(item: url) { icon("square.and.arrow.up") }.accessibilityLabel("Share")
            }
            key("plus", "New tab") { model.newTab() }
            key(nil, "Tabs", count: model.visibleTabs.count) { model.showOverview() }
            Menu {
                // Everything the iPhone's menu has (find, share, reader, text size, the page's tools, extensions, close tabs)...
                PhoneMenuContent(tab: tab)
                // ...and the library, which on iPad opens beside the page.
                Section {
                    Button { model.sheet = .history } label: { Label("History", systemImage: "clock") }
                    Button { model.sheet = .bookmarks } label: { Label("Bookmarks", systemImage: "book") }
                    Button { model.sheet = .downloads } label: { Label("Downloads", systemImage: "arrow.down.circle") }
                    Button { model.sheet = .readingList } label: { Label("Reading List", systemImage: "books.vertical") }
                }
                Menu { ToolsMenuItems(model: model) } label: { Label("Tools", systemImage: "wrench.and.screwdriver") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .motion(.easeOut(duration: 0.18), value: model.visibleTabs.count)
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44).contentShape(Rectangle())
    }

    private func key(_ symbol: String?, _ label: String, enabled: Bool = true, on: Bool = false, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 18, weight: .medium)) }
                else {
                    Text("\(count ?? 0)").font(.system(size: 14, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary, lineWidth: 1.8))
                }
            }
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? Theme.accent.opacity(0.18) : Color.clear))
            .foregroundStyle(on ? Theme.accent : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }
}

/// The tabs as big rounded chips: the one you are on is tinted, the others are quiet. A + at the end opens another.
private struct IPadTabStrip: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.visibleTabs) { tab in
                        IPadTabChip(tab: tab, selected: tab.id == model.activeID).id(tab.id)
                    }
                    Button { model.newTab() } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain).accessibilityLabel("New tab")
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 46)
            .onChange(of: model.activeID) { _, id in if let id { animated(.easeOut(duration: 0.2)) { proxy.scrollTo(id) } } }
        }
    }
}

private struct IPadTabChip: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if tab.isPrivate { Image(systemName: "eye.slash.fill").foregroundStyle(Theme.privateAccent).frame(width: 18) }
            else { SiteTile(url: tab.url?.absoluteString ?? "", title: tab.title, size: 18).opacity(tab.isBlank ? 0.4 : 1) }
            Text(tab.displayTitle).font(.system(size: 14, weight: selected ? .semibold : .regular)).lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            if tab.isLoading { ProgressView().controlSize(.mini) }
            if selected {
                Button { model.closeTab(id: tab.id) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).frame(width: 24, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .foregroundStyle(selected ? Theme.accent : Color.primary.opacity(0.75))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { model.select(tab.id) }
        .contextMenu { TabMenuItems(tab: tab) }
        .motion(.easeOut(duration: 0.18), value: selected)
    }
}

/// Bookmarks, History, Downloads and Settings: tall rows that are easy to hit with a finger.
private struct IPadLibraryMenu: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var showLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("LIBRARY").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 8)
            row("clock", "History", .history)
            row("book", "Bookmarks", .bookmarks)
            row("arrow.down.circle", "Downloads", .downloads)
            Divider().padding(.vertical, 4)
            row("books.vertical", "Reading List", .readingList)
            row("gearshape", "Settings", .settings)
        }
        .padding(8).frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private func row(_ symbol: String, _ title: String, _ sheet: Sheet) -> some View {
        Button {
            showLibrary = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { model.sheet = sheet }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 24)
                Text(title).font(.system(size: 16))
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


/// The one small control left while the bars are away: the site's name. Tapping it, or scrolling back up, brings everything back.
private struct IPadReturnPill: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController

    var body: some View {
        Button { model.expandChrome() } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.isSecure ? "lock.fill" : "globe").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(tab.isBlank ? "Search or enter address" : displayHost(tab.url)).font(.system(size: 14, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 40)
            .background(ThemeState.animated ? AnyShapeStyle(Color.black.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        }
        .buttonStyle(.plain).accessibilityLabel("Show toolbar")
    }
}


/// What the address bar offers as you type: one card under the field, without dimming the page or stacking another dialog on it.
private struct IPadSuggestions: View {
    @ObservedObject var address: AddressBarController

    var body: some View {
        if address.isEditing && !address.suggestions.isEmpty {
            ZStack(alignment: .top) {
                Color.clear.contentShape(Rectangle()).onTapGesture { address.isEditing = false }
                SuggestionsList(address: address)
                    .padding(8).frame(maxWidth: 640)
                    .background(ThemeState.animated ? AnyShapeStyle(Color.black.opacity(0.35)) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Keyboard shortcuts for an external keyboard, registered by the window itself so they work whichever part of the page has focus.
/// They use the same keys as the Mac, and the same choices in Settings › Shortcuts.
private struct IPadShortcutLayer: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let map = model.shortcuts
        ZStack {
            Button("New Tab") { model.newTab() }.shortcut(.newTab, map)
            Button("New Private Tab") { model.openTab(url: nil, isPrivate: true) }.shortcut(.newPrivateTab, map)
            Button("Open Location") { model.focusAddressBar() }.shortcut(.openLocation, map)
            Button("Command Center") { model.pendingAddressPrefill = ">"; model.focusAddressBar() }.shortcut(.commandPalette, map)
            Button("Close Tab") { if let id = model.activeID { model.closeTab(id: id) } }.shortcut(.closeTab, map)
            Button("Reopen Closed Tab") { model.reopenClosedTab() }.shortcut(.reopenClosedTab, map)
            Button("Back") { model.active?.goBack() }.shortcut(.back, map)
            Button("Forward") { model.active?.goForward() }.shortcut(.forward, map)
            Button("Reload") { model.active?.reload() }.shortcut(.reload, map)
            Button("Stop") { model.active?.stop() }.shortcut(.stop, map)
            Button("Next Tab") { model.selectAdjacent(1) }.shortcut(.nextTab, map)
            Button("Previous Tab") { model.selectAdjacent(-1) }.shortcut(.previousTab, map)
            Button("Show All Tabs") { model.overviewVisible ? model.hideOverview() : model.showOverview() }.shortcut(.tabOverview, map)
            Button("Find in Page") { model.showFind() }.shortcut(.find, map)
            Button("Bookmark This Page") { model.toggleBookmark() }.shortcut(.bookmarkPage, map)
            Button("Bookmarks") { model.sheet = .bookmarks }.shortcut(.showBookmarks, map)
            Button("History") { model.sheet = .history }.shortcut(.showHistory, map)
            Button("Downloads") { model.sheet = .downloads }.shortcut(.showDownloads, map)
            Button("Show Sidebar") { model.sidebarVisible.toggle() }.shortcut(.toggleSidebar, map)
            Button("Zoom In") { model.active?.zoom(by: 0.1) }.shortcut(.zoomIn, map)
            Button("Zoom Out") { model.active?.zoom(by: -0.1) }.shortcut(.zoomOut, map)
            Button("Actual Size") { model.active?.resetZoom() }.shortcut(.actualSize, map)
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { model.selectTab(number: n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        .frame(width: 0, height: 0).opacity(0)
    }
}
