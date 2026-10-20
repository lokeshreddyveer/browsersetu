import SwiftUI

/// The toolbar buttons that were only to be found in the sidebar or the menu bar: workspaces, profile, split view, history, bookmarks, find and the command palette.
/// Which of them show is up to the person (Settings › Appearance › Toolbar); they appear in the Classic, Minimal and One Row layouts.
struct ToolbarExtras: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        if model.shows(.workspaces) { WorkspaceToolbarMenu() }
        if model.shows(.profile) { ProfileToolbarMenu() }
        if model.shows(.splitView) { SplitToolbarMenu() }
        if model.shows(.history) { ChromeButton(symbol: "clock", help: "History", identifier: "history-button") { model.sheet = .history } }
        if model.shows(.library) { ChromeButton(symbol: "book", help: "Bookmarks", identifier: "library-button") { model.sheet = .bookmarks } }
        if model.shows(.find), model.active?.isBlank == false { ChromeButton(symbol: "magnifyingglass", help: "Find in Page", identifier: "find-button") { model.showFind() } }
        if model.shows(.palette) { ChromeButton(symbol: "command", help: "Command Palette", identifier: "palette-button") { model.paletteVisible.toggle() } }
    }
}

/// A toolbar menu button that looks like the others.
private struct ToolbarMenuButton<Content: View>: View {
    let symbol: String
    let help: String
    var tint: Color?
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(tint ?? .primary)
                .frame(width: 28, height: 28).contentShape(Rectangle()).accessibilityLabel(help)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(ChromeButtonStyle()).fixedSize()
        .help(help).accessibilityLabel(help).accessibilityIdentifier(identifier)
    }
}

struct WorkspaceToolbarMenu: View {
    @EnvironmentObject var model: BrowserModel
    private var icon: String { model.workspaces.first { $0.name == model.activeWorkspace }?.icon ?? "person" }

    var body: some View {
        ToolbarMenuButton(symbol: icon, help: "Workspace: \(model.activeWorkspace.isEmpty ? "Personal" : model.activeWorkspace)", tint: model.activeWorkspace.isEmpty ? nil : Theme.accent, identifier: "workspace-button") {
            Button { model.switchWorkspace("") } label: { Label("Personal", systemImage: model.activeWorkspace.isEmpty ? "checkmark" : "person") }
            ForEach(model.workspaces) { workspace in
                Button { model.switchWorkspace(workspace.name) } label: {
                    Label(workspace.name, systemImage: workspace.name == model.activeWorkspace ? "checkmark" : workspace.icon)
                }
            }
            Divider()
            Button("New Workspace…") { promptNewWorkspace(model: model) }
            Button("Manage Workspaces…") { SettingsRouter.open(.tabs) }
        }
    }
}

struct ProfileToolbarMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ToolbarMenuButton(symbol: model.profileStyle(model.profileName).symbol, help: "Profile: \(model.profileName)", identifier: "profile-button") {
            ForEach(model.profiles, id: \.self) { name in
                Button { model.switchProfile(name) } label: { Label(name, systemImage: name == model.profileName ? "checkmark" : model.profileStyle(name).symbol) }
            }
            Divider()
            if let url = model.active?.url, !(model.active?.isBlank ?? true) {
                Menu("Open This Page in Profile") {
                    ForEach(model.profiles.filter { $0 != model.profileName }, id: \.self) { name in
                        Button(name) { model.openInProfile(url, profile: name) }
                    }
                }
                Menu("Always Open \(url.host ?? "This Site") in") {
                    ForEach(model.profiles, id: \.self) { name in Button(name) { model.assignSite(host: url.host, to: name) } }
                    Divider()
                    Button("No Profile") { model.assignSite(host: url.host, to: nil) }
                }
            }
            Button("Start a Temporary Profile") { model.startTemporaryProfile() }
            Button("Manage Profiles…") { SettingsRouter.open(.profiles) }
        }
    }
}

/// Everything about the split view, in one place: put another tab beside this one, a third panel, direction, swap, close.
struct SplitToolbarMenu: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        ToolbarMenuButton(symbol: model.splitTabID == nil ? "rectangle.split.2x1" : "rectangle.split.2x1.fill", help: "Split View", tint: model.splitTabID == nil ? nil : Theme.accent, identifier: "split-button") {
            SplitViewMenuItems()
        }
    }
}

/// The split-view commands, shared by the toolbar button, the More menu and the menu bar.
struct SplitViewMenuItems: View {
    @EnvironmentObject var model: BrowserModel

    private var others: [TabController] {
        model.visibleTabs.filter { $0.id != model.activeID && $0.id != model.splitTabID && $0.id != model.thirdSplitTabID && $0.id != model.fourthSplitTabID && !$0.isBlank && $0.isPrivate == model.activeIsPrivate }
    }

    var body: some View {
        Menu("Show Another Tab Beside This One") {
            if others.isEmpty { Text("No other tab is open") }
            ForEach(others.prefix(20)) { tab in
                Button(tab.displayTitle) { model.splitTabID == nil ? model.openSplit(with: tab) : model.addThirdPanel(with: tab) }
            }
        }
        Button("New Tab Beside This One") { model.splitTabID == nil ? model.openSplitNewTab() : model.addThirdPanelNewTab() }
            .disabled(model.fourthSplitTabID != nil)
        if model.splitTabID != nil {
            Divider()
            if model.thirdSplitTab != nil { Button("Remove the Last Panel") { model.removeThirdPanel() } }
            Button(model.splitOrientation == .sideBySide ? "Stack the Panels" : "Put the Panels Side by Side") {
                model.splitOrientation = model.splitOrientation == .sideBySide ? .stacked : .sideBySide
            }
            Button("Swap Panels") { model.swapSplit() }
            Button("Close Split View") { model.closeSplit() }
        }
    }
}

/// The Downloads button, with a ring that fills while something downloads, so the button itself shows that a download is under way.
struct DownloadsToolbarButton: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var coordinator: DownloadCoordinator

    var body: some View {
        let items = Array(coordinator.active.values)
        let average = items.isEmpty ? 0 : items.map(\.fraction).reduce(0, +) / Double(items.count)
        Button { model.sheet = .downloads } label: {
            ZStack {
                if !items.isEmpty {
                    Circle().stroke(Color.primary.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: max(0.04, average)).stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                }
                Image(systemName: items.isEmpty ? "arrow.down.circle" : "arrow.down").foregroundStyle(items.isEmpty ? Color.primary : Theme.accent)
            }
            .frame(width: items.isEmpty ? nil : 20, height: items.isEmpty ? nil : 20)
        }
        .buttonStyle(ChromeButtonStyle())
        .help(items.isEmpty ? "Downloads" : "Downloading… \(Int((average * 100).rounded()))%")
        .accessibilityLabel(items.isEmpty ? "Downloads" : "Downloads, \(Int((average * 100).rounded())) percent")
        .accessibilityIdentifier("downloads-button")
        .motion(.easeOut(duration: 0.2), value: items.isEmpty)
    }
}
