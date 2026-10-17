import SwiftUI

/// Everything that decides what the window's chrome looks like, gathered in one place. The browser keeps these as separate settings (a preset, whether the sidebar is
/// shown or tucked to the edge, focus mode, toolbar auto-hide, full screen and so on). `LayoutState.resolve` reads all of them at once and answers every question the
/// screens ask, so no screen has to combine several flags by itself and no combination can slip through unexamined.
struct LayoutInputs: Equatable {
    var isMac = true
    var isPhone = false
    var preset: LayoutPreset = .classic
    var customTabLayout: TabLayout = .separate
    var singleToolbarCustom = false
    /// The sidebar flag as it is now (docked or not), and the user's pin choice.
    var sidebarVisible = false
    var sidebarAutoHide = false
    var sidebarRail = false
    var focusMode = false
    var toolbarAutoHide = false
    var windowFullScreen = false
    var collapseOnScroll = true
    var windowWidth: Double = 1100
}

/// The controls every layout must keep reachable, however much is hidden.
enum LayoutControl: String, CaseIterable, Identifiable {
    case search, newTab, tabOverview, settings, restoreLayout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .search: "Search or address"
        case .newTab: "New tab"
        case .tabOverview: "Tab overview"
        case .settings: "Settings"
        case .restoreLayout: "Restore standard layout"
        }
    }
}

struct LayoutState: Equatable {
    enum TopChrome: String { case toolbar, toolbarOnEdge, singleRow, floatingPill, focusBand, none }
    enum TabsPlacement: String { case strip, compactStrip, sidebar, rail, inRow, none }
    enum AddressPlacement: String { case toolbar, sidebar, inRow, floatingSearch, bottomDock }
    enum SidebarMode: String { case pinned, rail, onEdge, hidden }
    /// How a control is reached: on screen now, by moving the pointer to an edge, or only through the layout handle's menu.
    enum Reach: String { case visible, onHover, handle }

    var topChrome: TopChrome
    var tabs: TabsPlacement
    var address: AddressPlacement
    var sidebar: SidebarMode
    var focus: Bool
    var reach: [LayoutControl: Reach]
    /// Controls folded into the toolbar's More menu because the window is narrow.
    var folded: [LayoutControl]
    var windowWidth: Double

    /// A small always-visible handle is drawn when anything essential could only be found by moving the pointer to an edge.
    var needsHandle: Bool { reach.values.contains(.onHover) }
    /// Whether there is, on screen or behind the handle, a way to every essential control.
    var everythingReachable: Bool { LayoutControl.allCases.allSatisfy { reach[$0] != nil } }
    var hiddenControls: [LayoutControl] { LayoutControl.allCases.filter { reach[$0] != .visible } }

    static func resolve(_ i: LayoutInputs) -> LayoutState {
        // iPhone: the bottom dock is always there; nothing hides.
        if i.isPhone {
            var reach: [LayoutControl: Reach] = [.search: .visible, .newTab: .visible, .tabOverview: .visible, .settings: .visible, .restoreLayout: .handle]
            if i.focusMode { reach[.search] = .handle }
            return LayoutState(topChrome: .none, tabs: .none, address: .bottomDock, sidebar: .hidden, focus: i.focusMode, reach: reach, folded: [], windowWidth: i.windowWidth)
        }
        let resolved = resolveLayout(preset: i.preset, customTabLayout: i.customTabLayout, customSidebarVisible: i.sidebarVisible, customSingleToolbar: i.singleToolbarCustom)
        let single = resolved.singleToolbar
        let autoHidesToolbar = (i.preset == .custom && i.toolbarAutoHide) || (i.windowFullScreen && !single)

        let sidebar: SidebarMode
        if i.focusMode { sidebar = .hidden }
        else if i.sidebarVisible { sidebar = i.sidebarRail ? .rail : .pinned }
        else if i.sidebarAutoHide || resolved.tabLayout == .sidebar { sidebar = .onEdge }
        else { sidebar = .hidden }

        let top: TopChrome
        if i.focusMode { top = .focusBand }
        else if i.preset == .floating { top = .floatingPill }
        else if single { top = .none }
        else if i.preset == .inline { top = .singleRow }
        else if autoHidesToolbar { top = .toolbarOnEdge }
        else { top = .toolbar }

        let tabs: TabsPlacement
        if i.focusMode { tabs = .none }
        else if i.preset == .inline { tabs = .inRow }
        else if resolved.tabLayout == .sidebar { tabs = sidebar == .rail ? .rail : .sidebar }
        else if resolved.tabLayout == .compact { tabs = .compactStrip }
        else { tabs = .strip }

        let address: AddressPlacement
        if i.focusMode || i.preset == .floating { address = .floatingSearch }
        else if single { address = sidebar == .pinned ? .sidebar : .floatingSearch }
        else if i.preset == .inline { address = .inRow }
        else { address = .toolbar }

        // How each essential control is reached.
        var reach: [LayoutControl: Reach] = [.restoreLayout: .handle]
        var folded: [LayoutControl] = []
        switch top {
        case .toolbar, .singleRow:
            // The toolbar drops its optional buttons from the right as the window narrows; they stay one click away in More.
            let priority = ToolbarPriority(fitting: CGFloat(i.windowWidth), leadingInset: i.windowFullScreen ? 10 : 84)
            reach[.search] = .visible
            reach[.settings] = .handle
            reach[.newTab] = priority.showOptional ? .visible : .handle
            reach[.tabOverview] = priority.showOptional ? .visible : .handle
            if !priority.showOptional { folded = [.newTab, .tabOverview] }
        case .floatingPill:
            reach[.search] = .visible; reach[.newTab] = .handle; reach[.tabOverview] = .handle; reach[.settings] = .handle
        case .focusBand:
            // The focus band carries a menu with everything.
            reach[.search] = .handle; reach[.newTab] = .handle; reach[.tabOverview] = .handle; reach[.settings] = .handle
        case .toolbarOnEdge:
            reach[.search] = .onHover; reach[.newTab] = .onHover; reach[.tabOverview] = .onHover; reach[.settings] = .handle
        case .none:
            // The sidebar layout: everything lives in the sidebar, which is on screen only when it is docked.
            let shown = sidebar == .pinned
            reach[.search] = shown ? .visible : .onHover
            reach[.newTab] = shown ? .visible : .onHover
            reach[.tabOverview] = shown ? .visible : .onHover
            reach[.settings] = shown ? .visible : .onHover
        }
        return LayoutState(topChrome: top, tabs: tabs, address: address, sidebar: sidebar, focus: i.focusMode, reach: reach, folded: folded, windowWidth: i.windowWidth)
    }

    /// A few plain lines for the diagnostics view.
    var summary: [(String, String)] {
        [("Top of the window", topChrome.rawValue), ("Tabs", tabs.rawValue), ("Address bar", address.rawValue), ("Sidebar", sidebar.rawValue),
         ("Focus mode", focus ? "on" : "off"), ("Window width", "\(Int(windowWidth)) pt"),
         ("Folded into More", folded.isEmpty ? "nothing" : folded.map(\.title).joined(separator: ", ")),
         ("Not on screen", hiddenControls.isEmpty ? "nothing" : hiddenControls.map { "\($0.title) (\(reach[$0]?.rawValue ?? "?"))" }.joined(separator: ", ")),
         ("Layout handle", needsHandle ? "shown" : "not needed")]
    }
}

/// A saved arrangement of the window: the preset and the sidebar, focus and split choices that go with it.
struct LayoutSnapshot: Codable, Equatable {
    var preset: String
    var sidebarPosition: String
    var sidebarVisible: Bool
    var sidebarRail: Bool
    var sidebarAutoHide: Bool
    var focusMode: Bool
    var splitOrientation: String
    var toolbarAutoHide: Bool
    var collapseOnScroll: Bool
}

/// Ready-made arrangements.
enum WindowPreset: String, CaseIterable, Identifiable {
    case research, writing, media, minimal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var summary: String {
        switch self {
        case .research: "Vertical tabs docked on the left, so many pages stay in view"
        case .writing: "One quiet row of controls and focus mode"
        case .media: "Floating pill and search, the page fills the window"
        case .minimal: "Everything on one line"
        }
    }

    var snapshot: LayoutSnapshot {
        switch self {
        case .research: LayoutSnapshot(preset: "sidebar", sidebarPosition: "left", sidebarVisible: true, sidebarRail: false, sidebarAutoHide: false, focusMode: false, splitOrientation: "sideBySide", toolbarAutoHide: false, collapseOnScroll: true)
        case .writing: LayoutSnapshot(preset: "inline", sidebarPosition: "left", sidebarVisible: false, sidebarRail: false, sidebarAutoHide: false, focusMode: true, splitOrientation: "sideBySide", toolbarAutoHide: false, collapseOnScroll: true)
        case .media: LayoutSnapshot(preset: "floating", sidebarPosition: "left", sidebarVisible: false, sidebarRail: false, sidebarAutoHide: false, focusMode: false, splitOrientation: "sideBySide", toolbarAutoHide: false, collapseOnScroll: true)
        case .minimal: LayoutSnapshot(preset: "inline", sidebarPosition: "left", sidebarVisible: false, sidebarRail: false, sidebarAutoHide: false, focusMode: false, splitOrientation: "sideBySide", toolbarAutoHide: false, collapseOnScroll: true)
        }
    }
}

extension BrowserModel {
    func layoutInputs(width: Double = 1100) -> LayoutInputs {
        var inputs = LayoutInputs()
        #if os(iOS)
        inputs.isMac = false
        inputs.isPhone = UIDevice.current.userInterfaceIdiom == .phone
        #endif
        inputs.preset = layoutPreset
        inputs.customTabLayout = tabLayout
        inputs.singleToolbarCustom = singleToolbarCustom
        inputs.sidebarVisible = sidebarVisible
        inputs.sidebarAutoHide = sidebarAutoHide
        inputs.sidebarRail = sidebarRail
        inputs.focusMode = focusMode
        inputs.toolbarAutoHide = toolbarAutoHide
        inputs.windowFullScreen = windowFullScreen
        inputs.collapseOnScroll = collapseOnScroll
        inputs.windowWidth = width
        return inputs
    }

    func layoutState(width: Double = 1100) -> LayoutState { LayoutState.resolve(layoutInputs(width: width)) }

    func layoutSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(preset: layoutPreset.rawValue, sidebarPosition: sidebarPosition.rawValue, sidebarVisible: sidebarVisible, sidebarRail: sidebarRail,
                       sidebarAutoHide: sidebarAutoHide, focusMode: focusMode, splitOrientation: splitOrientation.rawValue, toolbarAutoHide: toolbarAutoHide,
                       collapseOnScroll: collapseOnScroll)
    }

    /// Puts the window into a saved arrangement. Unknown values are ignored, so an old or damaged snapshot cannot leave the layout in a state nobody chose.
    func apply(_ snapshot: LayoutSnapshot) {
        #if os(macOS)
        if let preset = LayoutPreset(rawValue: snapshot.preset), preset != .custom { layoutPreset = preset }
        if let position = SidebarPosition(rawValue: snapshot.sidebarPosition) { sidebarPosition = position }
        sidebarRail = snapshot.sidebarRail
        if snapshot.sidebarVisible && !snapshot.sidebarRail { pinSidebar() } else if snapshot.sidebarAutoHide { hideSidebarToEdge() } else { sidebarVisible = snapshot.sidebarVisible }
        if let orientation = SplitOrientation(rawValue: snapshot.splitOrientation) { splitOrientation = orientation }
        toolbarAutoHide = snapshot.toolbarAutoHide
        collapseOnScroll = snapshot.collapseOnScroll
        if snapshot.focusMode != focusMode { toggleFocusMode() }
        #endif
    }

    func applyWindowPreset(_ preset: WindowPreset) {
        apply(preset.snapshot)
        notice = "Window layout: \(preset.title)."
    }

    /// The way back from any combination: the standard layout, nothing hidden, no focus mode, no half-open search, the default toolbar.
    func restoreStandardLayout() {
        focusMode = false
        floatingAddressVisible = false
        paletteVisible = false
        overviewVisible = false
        #if os(macOS)
        layoutPreset = .classic
        sidebarRail = false
        sidebarAutoHide = false
        toolbarAutoHide = false
        sidebarPosition = .left
        singleToolbarCustom = false
        #endif
        toolbarItems = ToolbarItemID.defaults
        collapseOnScroll = true
        expandChrome()
        notice = "Standard layout restored."
    }
}

extension BrowserModel {
    /// Writes down how the window looks now, under the workspace it belongs to ("" is the personal one, kept in the profile's settings).
    func rememberLayout(forWorkspace name: String) {
        let snapshot = layoutSnapshot()
        if name.isEmpty { saveSetting("personal_layout", encodedMap(["layout": snapshot])) } else { setWorkspaceLayout(name, snapshot) }
    }

    func layout(forWorkspace name: String) -> LayoutSnapshot? {
        if name.isEmpty { return Self.decodeMap(((try? core.getSetting(key: "personal_layout")) ?? nil), as: LayoutSnapshot.self)["layout"] }
        return workspaces.first { $0.name == name }?.layout
    }
}

// MARK: - Views

/// The commands every layout must keep within reach. Shown by the layout handle, the focus band and the toolbar's More menu, so a hidden control is always one
/// click from somewhere visible.
struct LayoutEscapeMenuItems: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Button("Search or Enter Address", systemImage: "magnifyingglass") { model.focusAddressBar() }
        Button("New Tab", systemImage: "plus") { model.newTab() }
        Button("Show Tab Overview", systemImage: "square.on.square") { model.showOverview() }
        Button("Command Palette", systemImage: "command") { model.paletteVisible = true }
        Button("Settings", systemImage: "gearshape") {
            #if os(macOS)
            SettingsRouter.open()
            #else
            model.sheet = .settings
            #endif
        }
        Divider()
        Menu("Window Layout") {
            ForEach(WindowPreset.allCases) { preset in Button(preset.title) { model.applyWindowPreset(preset) } }
        }
        Button("Restore Standard Layout", systemImage: "arrow.counterclockwise") { model.restoreStandardLayout() }
        Button("Layout Diagnostics…", systemImage: "square.dashed.inset.filled") { model.sheet = .layout }
        if model.focusMode { Button("Exit Focus Mode", systemImage: "rectangle.expand.vertical") { model.toggleFocusMode() } }
    }
}

/// A small handle at the top of the window, drawn only when something essential could otherwise be found by moving the pointer to an edge.
struct LayoutHandle: View {
    var body: some View {
        Menu { LayoutEscapeMenuItems() } label: {
            Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                .accessibilityLabel("Layout menu")
                .frame(width: 34, height: 16)
                .environment(\.colorScheme, .dark)
                .background(Obsidian.fill.opacity(0.9), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(Obsidian.edge, lineWidth: 0.6))
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        .help("Controls, window layout and the way back to the standard layout")
        .accessibilityLabel("Window controls")
        .accessibilityIdentifier("layout-handle")
    }
}

/// What the window is doing and why: every decision the layout made, and what is not on screen.
struct LayoutDiagnosticsView: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        let state = model.layoutState(width: model.windowWidth)
        List {
            Section("Now") {
                ForEach(Array(state.summary.enumerated()), id: \.offset) { _, line in LabeledContent(line.0, value: line.1) }
            }
            Section("Essential controls") {
                ForEach(LayoutControl.allCases) { control in
                    LabeledContent(control.title, value: state.reach[control].map { $0 == .visible ? "on screen" : ($0 == .onHover ? "at the window edge" : "in the window menu") } ?? "not reachable")
                }
            }
            Section("Settings behind it") {
                LabeledContent("Preset", value: model.layoutPreset.title)
                LabeledContent("Sidebar docked", value: model.sidebarVisible ? "yes" : "no")
                LabeledContent("Sidebar on the edge", value: model.sidebarAutoHide ? "yes" : "no")
                LabeledContent("Sidebar as icons", value: model.sidebarRail ? "yes" : "no")
                LabeledContent("Toolbar hides itself", value: model.toolbarAutoHide ? "yes" : "no")
                LabeledContent("Folds on scroll", value: model.collapseOnScroll ? "yes" : "no")
            }
            Section {
                Button("Restore Standard Layout") { model.restoreStandardLayout() }
                Toggle("Each workspace remembers its layout", isOn: $model.rememberLayoutPerWorkspace)
                Menu("Window Layout") { ForEach(WindowPreset.allCases) { preset in Button("\(preset.title): \(preset.summary)") { model.applyWindowPreset(preset) } } }
            }
        }
        .accessibilityIdentifier("layout-diagnostics")
    }
}
