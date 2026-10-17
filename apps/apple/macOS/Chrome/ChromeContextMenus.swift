import SwiftUI

// Right-click menus for the empty parts of the window: the sidebar, the toolbar and tab strip, and the start page.
// Controls and tabs keep their own menus; these appear where nothing else claims the click.

/// The layout choices, shared by the sidebar and toolbar menus.
private struct LayoutMenu: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Menu("Layout") {
            ForEach(LayoutPreset.allCases.filter { $0 != .custom }) { preset in
                Button {
                    animated(.easeOut(duration: 0.2)) { model.layoutPreset = preset }
                } label: {
                    if model.layoutPreset == preset { Label(preset.title, systemImage: "checkmark") } else { Text(preset.title) }
                }
            }
        }
    }
}

private struct DensityMenu: View {
    @EnvironmentObject var model: BrowserModel
    var body: some View {
        Menu("Density") {
            ForEach(InterfaceDensity.allCases) { density in
                Button { animated(.easeOut(duration: 0.2)) { model.density = density } } label: {
                    if model.density == density { Label(density.title, systemImage: "checkmark") } else { Text(density.title) }
                }
            }
        }
    }
}

/// Right-click on the sidebar's empty space.
struct SidebarContextMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if model.showsMenuItem(.newTab) { Button("New Tab") { model.newTab() } }
        if model.showsMenuItem(.newPrivateTab) { Button("New Private Tab") { model.openTab(url: nil, isPrivate: true) } }
        if model.showsMenuItem(.searchTabs) { Button("Search Tabs") { model.tabSearchVisible = true } }
        Divider()
        if model.showsMenuItem(.newGroup) { Button("New Tab Group…") { promptNewGroup(model: model) } }
        if model.showsMenuItem(.newWorkspace) { Button("New Workspace…") { promptNewWorkspace(model: model) } }
        if !model.webPanels.isEmpty {
            Menu("Web Panels") {
                ForEach(model.webPanels) { panel in
                    Button { model.toggleWebPanel(panel.id) } label: {
                        if model.openPanelID == panel.id { Label(panel.name, systemImage: "checkmark") } else { Text(panel.name) }
                    }
                }
            }
        }
        Divider()
        if model.showsMenuItem(.sidebarSections) { Menu("Show in Sidebar") {
            ForEach(SidebarSection.allCases) { section in
                Button { animated(.easeOut(duration: 0.18)) { model.sidebarSection = section } } label: {
                    if model.sidebarSection == section { Label(section.title, systemImage: "checkmark") } else { Label(section.title, systemImage: section.symbol) }
                }
            }
        } }
        if model.showsMenuItem(.sidebarPosition) { Menu("Sidebar Position") {
            ForEach(SidebarPosition.allCases) { side in
                Button { animated(.easeOut(duration: 0.22)) { model.sidebarPosition = side } } label: {
                    if model.sidebarPosition == side { Label(side.title, systemImage: "checkmark") } else { Text(side.title) }
                }
            }
        } }
        if model.showsMenuItem(.collapse) { Button(model.sidebarRail ? "Expand Sidebar" : "Collapse to Icons") { animated(.easeOut(duration: 0.22)) { model.sidebarRail.toggle() } } }
        if model.showsMenuItem(.autoHide) {
            Button(model.sidebarAutoHide ? "Keep Sidebar Open" : "Hide Until Pointer Reaches the Edge") {
                animated(.easeOut(duration: 0.22)) { if model.sidebarAutoHide { model.pinSidebar() } else { model.hideSidebarToEdge() } }
            }
        }
        if model.showsMenuItem(.hideSidebar) { Button("Hide Sidebar") { animated(.easeOut(duration: 0.22)) { model.sidebarVisible = false } } }
        Divider()
        if model.showsMenuItem(.layout) { LayoutMenu() }
        if model.showsMenuItem(.density) { DensityMenu() }
        if model.showsMenuItem(.breakMode) { Button(model.breakActive ? "End Break" : "Break: Pause All Media") { model.toggleBreakMode() } }
        if model.showsMenuItem(.customize) { Button("Customize Sidebar…") { SettingsRouter.open(.tabs) } }
    }
}

/// Right-click on the toolbar or the tab strip.
struct ToolbarContextMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if model.showsMenuItem(.newTab) { Button("New Tab") { model.newTab() } }
        if model.showsMenuItem(.newPrivateTab) { Button("New Private Tab") { model.openTab(url: nil, isPrivate: true) } }
        if model.showsMenuItem(.reopenClosed) { Button("Reopen Closed Tab") { model.reopenClosedTab() }.disabled(model.closedTabs.isEmpty) }
        Divider()
        Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") { animated(.easeOut(duration: 0.22)) { model.sidebarVisible.toggle() } }
        if model.showsMenuItem(.breakMode) { Button(model.breakActive ? "End Break" : "Break: Pause All Media") { model.toggleBreakMode() } }
        if let tab = model.active, let host = tab.url?.host?.lowercased(), !tab.isBlank {
            let allowed = model.popupAllowedHosts.contains(host)
            Button(allowed ? "Stop Allowing Pop-ups from \(host)" : "Allow Pop-ups from \(host)") {
                if allowed { model.popupAllowedHosts.remove(host) } else { model.popupAllowedHosts.insert(host) }
            }
        }
        if model.showsMenuItem(.pageActions) {
            Menu("Page Actions") {
                ForEach(PageAction.allCases) { action in
                    Button { model.togglePageAction(action) } label: {
                        if model.active?.pageActions.contains(action) == true { Label(action.title, systemImage: "checkmark") } else { Label(action.title, systemImage: action.symbol) }
                    }
                }
                Divider()
                Button("Reset This Page") { model.clearPageActions() }.disabled(model.active?.pageActions.isEmpty ?? true)
            }
            .disabled(model.active == nil || model.active?.isBlank == true)
        }
        if model.showsMenuItem(.toolbarButtons) { Menu("Toolbar Buttons") {
            ForEach(ToolbarItemID.allCases) { item in
                Button {
                    if model.shows(item) { model.toolbarItems.removeAll { $0 == item } }
                    else { model.toolbarItems = ToolbarItemID.allCases.filter { $0 == item || model.shows($0) } }
                } label: {
                    if model.shows(item) { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
            Divider()
            Button("Reset to Default") { model.toolbarItems = ToolbarItemID.defaults }
        } }
        if model.showsMenuItem(.layout) { LayoutMenu() }
        if model.showsMenuItem(.density) { DensityMenu() }
        Divider()
        if model.showsMenuItem(.customize) { Button("Customize Toolbar…") { SettingsRouter.open(.appearance) } }
    }
}

/// Right-click on the start page's background.
struct StartPageContextMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button("Customize…") { animated(.easeOut(duration: 0.22)) { model.startDrawerOpen = true } }
        Menu("Theme") {
            ForEach(model.allThemes) { theme in
                Button { animated(.easeOut(duration: 0.2)) { model.chooseTheme(theme.id) } } label: {
                    if model.themeID == theme.id { Label(theme.name, systemImage: "checkmark") } else { Text(theme.name) }
                }
            }
        }
        Menu("Background") {
            ForEach(StartBackground.allCases) { style in
                Button { model.startBackground = style } label: {
                    if model.startBackground == style { Label(style.title, systemImage: "checkmark") } else { Text(style.title) }
                }
            }
        }
        Menu("Size") {
            ForEach(StartTile.allCases) { size in
                Button { model.startTile = size } label: {
                    if model.startTile == size { Label(size.title, systemImage: "checkmark") } else { Text(size.title) }
                }
            }
        }
        Divider()
        Toggle("Greeting", isOn: $model.showGreeting)
        Toggle("Favorites", isOn: $model.showFavorites)
        Toggle("Continue Browsing", isOn: $model.showContinue)
        Toggle("Often Visited", isOn: $model.showFrequent)
        Toggle("Recently Closed", isOn: $model.showRecentlyClosed)
    }
}
