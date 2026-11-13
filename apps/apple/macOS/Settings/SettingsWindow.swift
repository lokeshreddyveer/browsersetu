import AppKit
import SwiftUI

/// The panels of the Settings window, in toolbar order. Every panel holds only controls that change something real.
enum SettingsPanel: String, CaseIterable, Identifiable {
    case general, appearance, tabs, search, downloads, privacy, ai, websites, profiles, performance, extensions, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tabs: "Tabs"
        case .search: "Search"
        case .downloads: "Downloads"
        case .privacy: "Privacy & Security"
        case .ai: "AI"
        case .websites: "Websites"
        case .profiles: "Profiles"
        case .performance: "Performance"
        case .extensions: "Extensions"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        }
    }

    /// Short label for the toolbar, where room is tight.
    var toolbarLabel: String { self == .privacy ? "Privacy" : title }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .tabs: "square.on.square"
        case .search: "magnifyingglass"
        case .downloads: "arrow.down.circle"
        case .privacy: "hand.raised"
        case .ai: "sparkles"
        case .websites: "globe"
        case .profiles: "person.crop.circle"
        case .performance: "speedometer"
        case .extensions: "puzzlepiece.extension"
        case .shortcuts: "keyboard"
        case .advanced: "wrench.and.screwdriver"
        }
    }

    /// The window grows and shrinks to fit the panel, as Safari's does.
    var height: CGFloat {
        switch self {
        case .general: 590
        case .appearance: 620
        case .tabs: 720
        case .search: 260
        case .downloads: 720
        case .privacy: 700
        case .ai: 640
        case .websites: 360
        case .profiles: 270
        case .performance: 540
        case .extensions: 340
        case .shortcuts: 680
        case .advanced: 660
        }
    }

    /// Wide enough for every panel's button and the search field in the same toolbar, so no panel hides behind the » menu.
    static let width: CGFloat = 900
}

/// Opens the Settings window (the same one ⌘, opens), optionally on a given panel.
@MainActor
enum SettingsRouter {
    static let storageKey = "settings.panel"
    /// Opens the Settings window through SwiftUI itself, which is the one way that always works; set by the main window.
    static var opener: (() -> Void)?

    /// Shows Settings inside the browser window instead (set by the window; true when it did).
    static var inlineOpener: (() -> Bool)?

    static func open(_ panel: SettingsPanel? = nil) {
        // A test run keeps its pane in memory only: the standard preferences belong to the person's own Browser Setu.
        if let panel, !TestIsolation.isUITestRun, !TestIsolation.isTestProcess { UserDefaults.standard.set(panel.rawValue, forKey: storageKey) }
        NSApp.activate(ignoringOtherApps: true)
        if let inlineOpener, inlineOpener() { return }
        if let opener { opener() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
}

/// The Settings window: a Safari-style toolbar of panels over native grouped forms. It shares the browser's one
/// `BrowserModel`, so a change here reaches every open browser window at once and is saved as it is made.
struct MacSettingsView: View {
    @EnvironmentObject var model: BrowserModel
    @AppStorage(SettingsRouter.storageKey) private var storedPanel = SettingsPanel.general.rawValue
    /// Where a test run keeps the chosen panel: nowhere outside this window (it used to write the person's own preferences when a panel was clicked).
    @State private var inMemoryPanel = SettingsPanel.general.rawValue
    private var keepsPanelInMemory: Bool { TestIsolation.isUITestRun || TestIsolation.isTestProcess }
    private var selected: String {
        get { keepsPanelInMemory ? inMemoryPanel : storedPanel }
        nonmutating set { if keepsPanelInMemory { inMemoryPanel = newValue } else { storedPanel = newValue } }
    }

    private var panel: SettingsPanel { SettingsPanel(rawValue: selected) ?? .general }
    @State private var query = ""

    @Namespace private var marker
    /// True when shown in the browser window's own page area rather than in the Settings window.
    var inline = false

    /// Panel (its own window) or Tab (a page inside the browser window): one switch, remembered.
    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach([false, true], id: \.self) { asTab in
                let on = model.settingsInTab == asTab
                Button { switchMode(toTab: asTab) } label: {
                    Label(asTab ? "Tab" : "Panel", systemImage: asTab ? "rectangle.topthird.inset.filled" : "macwindow")
                        .labelStyle(.titleAndIcon).font(.system(size: 12, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 26)
                        .foregroundStyle(on ? Theme.accent : Color.secondary)
                        .background { if on { Capsule().fill(Theme.accent.opacity(0.16)) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(asTab ? "Show settings as a tab" : "Show settings as a panel")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func switchMode(toTab: Bool) {
        guard toTab != model.settingsInTab else { return }
        animated(.easeOut(duration: 0.2)) { model.settingsInTab = toTab }
        if toTab {
            // Out of its own window and into the browser's.
            if !inline { NSApp.keyWindow?.close() }
            SettingsRouter.open()
        } else {
            if let tab = model.tabs.first(where: \.isSettingsPage) { model.closeTab(id: tab.id, force: true) }
            SettingsRouter.open()
        }
    }

    /// The panels in three groups down a rail of our own, with the panel's name large above its settings: a window that is
    /// Browser Setu's, not a copy of a system preferences window.
    private static let groups: [(title: String, panels: [SettingsPanel])] = [
        ("Browser", [.general, .appearance, .tabs, .search, .downloads, .ai]),
        ("Protection", [.privacy, .websites, .profiles]),
        ("More", [.performance, .extensions, .shortcuts, .advanced])
    ]

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5)
            ZStack(alignment: .top) {
                // The settings scroll up under the title, which is frosted, instead of being cut off at its edge.
                SettingsPanelView(panel: panel)
                    .contentMargins(.top, 20, for: .scrollContent)
                    .id(panel.rawValue)
                    .transition(.opacity)
                // No header bar: only the Panel / Tab switch (and Close, when shown as a tab), floating at the top right over the settings.
                HStack(spacing: 10) {
                    modeSwitch.background(Capsule().fill(.ultraThinMaterial))
                    if inline {
                        Button { if let tab = model.tabs.first(where: \.isSettingsPage) { model.closeTab(id: tab.id, force: true) } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                                .frame(width: 26, height: 26).background(Circle().fill(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Close settings")
                    }
                }
                .padding(.trailing, 14).padding(.top, 6)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .id(panel.rawValue)
            }
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .topLeading) { settingsSearch.padding(.top, 58).padding(.leading, 6) }
        .frame(minWidth: inline ? 0 : 880, maxWidth: inline ? .infinity : 880,
               minHeight: inline ? 0 : min(680, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 100)),
               maxHeight: inline ? .infinity : min(680, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 100)))
        .chromeFill(ownBackdrop: !inline)
        // The menu bar's Settings item can open this window even when Settings is set to be a tab: it hands over to the tab and closes itself.
        .background(SettingsWindowGuard(enabled: !inline && model.settingsInTab))
        .preferredColorScheme(model.appearance.colorScheme ?? (model.themeIsActive ? model.activeTheme.scheme?.colorScheme : nil))
        .tint(Theme.accent)
        .motion(.easeOut(duration: 0.2), value: selected)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
                TextField("Find a setting", text: $query).textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Self.groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.7)
                                .foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.bottom, 3)
                            ForEach(group.panels) { item in railRow(item) }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Text("Browser Setu \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 10)
        }
        .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 14)
        .frame(width: 210)
        // The rail takes the theme's own raised colour, so a theme reaches this window and not only the page behind it.
        .background((ThemeState.raised ?? Color.primary).opacity(ThemeState.raised == nil ? 0.035 : 0.55))
    }

    /// The glyph colour on an accent tile: dark on a light accent, white on any other.
    private var onAccent: Color { model.themeIsActive && model.activeTheme.accent.luminance > 0.6 ? .black : .white }

    private func railRow(_ item: SettingsPanel) -> some View {
        let on = item == panel
        return Button { selected = item.rawValue } label: {
            HStack(spacing: 10) {
                // Each panel's icon sits in a small tile; the open one's tile takes the theme's accent, with a glyph that stays readable on it.
                Image(systemName: item.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24)
                    .foregroundStyle(on ? onAccent : Color.secondary)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Theme.accent : Color.primary.opacity(0.07)))
                    .shadow(color: on ? Theme.accent.opacity(0.4) : .clear, radius: 5, y: 1)
                Text(item.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 36)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.22), Theme.accent.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.30), lineWidth: 0.75))
                        .matchedGeometryEffect(id: "marker", in: marker)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("settings-nav-\(item.rawValue)")
    }
}

extension MacSettingsView {
    /// One search field for the whole window, in its toolbar; what it finds opens the pane that holds it.
    @ViewBuilder fileprivate var settingsSearch: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                let found = SettingsIndex.search(query)
                VStack(alignment: .leading, spacing: 0) {
                    if found.isEmpty { Text("No settings match.").font(.callout).foregroundStyle(.secondary).padding(10) }
                    ForEach(found.prefix(8)) { entry in
                        Button {
                            selected = entry.mac
                            model.settingsReveal = SettingsIndex.macSection(for: entry).map { SettingsReveal(section: $0) }
                            query = ""
                        } label: {
                            HStack {
                                Text(entry.title).lineLimit(1)
                                Spacer()
                                Text((SettingsPanel(rawValue: entry.mac) ?? .general).title).settingsNote()
                            }
                            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 280)
                .themedFill(in: RoundedRectangle(cornerRadius: 10, style: .continuous), fallback: .regularMaterial)
                .hairline(RoundedRectangle(cornerRadius: 10, style: .continuous), opacity: 0.12, width: 0.5)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            }
        }
        .padding(10)
    }
}

struct SettingsPanelView: View {
    let panel: SettingsPanel
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .settingsPaneLayout()
            .themedSurface()
            .onAppear { reveal() }
            .onChange(of: model.settingsReveal) { _, _ in reveal() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(panel.title)
            .accessibilityIdentifier("settings-\(panel.rawValue)")
            .motion(.easeOut(duration: 0.22), value: model.layoutPreset)
            .motion(.easeOut(duration: 0.22), value: model.memoryMode)
            .motion(.easeOut(duration: 0.22), value: model.extensionCenter.extensions.count)
    }

    /// Scrolls to the section a search result asked for. A pane lays its rows out a moment after it appears (and a window a moment after it opens), so the scroll is tried
    /// again a few times; the request is forgotten once it has run.
    private func reveal() {
        guard let request = model.settingsReveal else { return }
        Task { @MainActor in
            for delay in [150, 400, 900] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard model.settingsReveal == request else { return }
                let found = SettingsAnchors.reveal(request.section)
                #if DEBUG
                WallpaperDebug.log("SETTINGS reveal \(request.section) after \(delay) ms found=\(found)")
                #endif
            }
            if model.settingsReveal == request { model.settingsReveal = nil }
        }
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .general:
            DefaultBrowserSection().settingsAnchor("DefaultBrowserSection")
            StartupSettingsSection().settingsAnchor("StartupSettingsSection")
            StartPageSettingsSection().settingsAnchor("StartPageSettingsSection")
            SyncSection().settingsAnchor("SyncSection")
        case .appearance:
            AppearanceSettingsSection().settingsAnchor("AppearanceSettingsSection")
            DarkPagesSection().settingsAnchor("DarkPagesSection")
        case .tabs:
            TabPositionSection().settingsAnchor("TabPositionSection")
            TabsSettingsSection().settingsAnchor("TabsSettingsSection")
            TabHoverAndStacksSection().settingsAnchor("TabHoverAndStacksSection")
            SidebarFooterSection().settingsAnchor("SidebarFooterSection")
            DockedPanelsSection().settingsAnchor("DockedPanelsSection")
            SplitAndWindowSettingsSection().settingsAnchor("SplitAndWindowSettingsSection")
            WorkspacesSettingsSection().settingsAnchor("WorkspacesSettingsSection")
            FocusScheduleSection().settingsAnchor("FocusScheduleSection")
            WebPanelsSection().settingsAnchor("WebPanelsSection")
            ContextMenusSection().settingsAnchor("ContextMenusSection")
        case .search:
            SearchSettingsSection().settingsAnchor("SearchSettingsSection")
            AddressSourcesSection().settingsAnchor("AddressSourcesSection")
            AddressBarButtonsSection().settingsAnchor("AddressBarButtonsSection")
            SearchShortcutsSection().settingsAnchor("SearchShortcutsSection")
            MenuBarSearchSettingsSection().settingsAnchor("MenuBarSearchSettingsSection")
        case .downloads:
            DownloadsSettingsSection().settingsAnchor("DownloadsSettingsSection")
        case .privacy:
            VayuLevelSection(privacy: model.privacy).settingsAnchor("VayuLevelSection")
            PrivacyPresetSection().settingsAnchor("PrivacyPresetSection")
            SecurityFactsSection().settingsAnchor("SecurityFactsSection")
            ThreatListSection().settingsAnchor("ThreatListSection")
            ProxySection().settingsAnchor("ProxySection")
            PageDefensesSection().settingsAnchor("PageDefensesSection")
            SafetySettingsSection().settingsAnchor("SafetySettingsSection")
            VayuSetuSection().settingsAnchor("VayuSetuSection")
            SensitiveLockSection().settingsAnchor("SensitiveLockSection")
            ClearOnQuitSection().settingsAnchor("ClearOnQuitSection")
            PageMemorySection().settingsAnchor("PageMemorySection")
            SearchableCopySection().settingsAnchor("SearchableCopySection")
            BrowsingDataSection().settingsAnchor("BrowsingDataSection")
        case .ai:
            AISettingsSection().settingsAnchor("AISettingsSection")
        case .websites:
            SitePermissionsSection().settingsAnchor("SitePermissionsSection")
            PopupSettingsSection().settingsAnchor("PopupSettingsSection")
            SavedSignInsSection().settingsAnchor("SavedSignInsSection")
            PasswordsInfoSection().settingsAnchor("PasswordsInfoSection")
            AddressesSection().settingsAnchor("AddressesSection")
            PermissionActivitySection().settingsAnchor("PermissionActivitySection")
            SiteZoomSection().settingsAnchor("SiteZoomSection")
            GlobalStyleSection().settingsAnchor("GlobalStyleSection")
            WebsiteDataSection().settingsAnchor("WebsiteDataSection")
        case .profiles:
            ProfileSettingsSection().settingsAnchor("ProfileSettingsSection")
        case .performance:
            MemorySettingsSection().settingsAnchor("MemorySettingsSection")
            NeverSleepSection().settingsAnchor("NeverSleepSection")
            ResourceMonitorSection().settingsAnchor("ResourceMonitorSection")
        case .extensions:
            ExtensionsSettingsSection().settingsAnchor("ExtensionsSettingsSection")
            RemoteExtensionsSection().settingsAnchor("RemoteExtensionsSection")
            UserScriptsSection().settingsAnchor("UserScriptsSection")
            SponsorBlockSection().settingsAnchor("SponsorBlockSection")
            WebAppsSection().settingsAnchor("WebAppsSection")
            EnhancementsSection().settingsAnchor("EnhancementsSection")
        case .shortcuts:
            ShortcutsSettingsSection().settingsAnchor("ShortcutsSettingsSection")
        case .advanced:
            AdvancedSettingsSection().settingsAnchor("AdvancedSettingsSection")
            BreakAndPageActionsSection().settingsAnchor("BreakAndPageActionsSection")
            CommandChainsSection().settingsAnchor("CommandChainsSection")
            GesturesSection().settingsAnchor("GesturesSection")
            HealthCheckSection().settingsAnchor("HealthCheckSection")
            #if DIRECT_BUILD
            UpdatesSettingsSection().settingsAnchor("UpdatesSettingsSection")
            #endif
            MediaCompatibilitySection().settingsAnchor("MediaCompatibilitySection")
            LinkCleaningSection().settingsAnchor("LinkCleaningSection")
            PageExtrasSection().settingsAnchor("PageExtrasSection")
            SiteIconsSection().settingsAnchor("SiteIconsSection")
            BookmarkTransferSection().settingsAnchor("BookmarkTransferSection")
            ImportExportSection().settingsAnchor("ImportExportSection")
            BackupSection().settingsAnchor("BackupSection")
            RecoverySection().settingsAnchor("RecoverySection")
            AboutSection().settingsAnchor("AboutSection")
        }
    }
}

/// Horizontal strip or vertical sidebar: the one tab choice most people want, without the layout presets.
struct TabPositionSection: View {
    @EnvironmentObject var model: BrowserModel

    enum Position: String, CaseIterable, Identifiable {
        case horizontal, vertical
        var id: String { rawValue }
        var title: String { self == .horizontal ? "Across the top" : "Down the side" }
    }

    private var position: Position { model.effectiveTabLayout == .sidebar ? .vertical : .horizontal }

    var body: some View {
        Section("Tab Position") {
            if model.layoutPreset == .custom {
                // A layout you set up yourself: this changes only where the tabs go.
                Picker("Tabs appear", selection: Binding(get: { position }, set: { model.tabLayout = $0 == .vertical ? .sidebar : .separate })) {
                    ForEach(Position.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } else {
                // A ready-made layout decides this itself, so it is shown, not offered as a second, conflicting switch.
                LabeledContent("Layout", value: model.layoutPreset.title)
                LabeledContent("Tabs appear", value: position.title)
                Button("Choose Another Layout…") { SettingsRouter.open(.appearance) }
            }
            Text(model.layoutPreset == .custom
                 ? "This is your own layout. The Appearance panel has the ready-made ones."
                 : "The \(model.layoutPreset.title) layout decides where the tabs go. To set it yourself, choose Custom in the Appearance panel.")
                .settingsNote()
        }
    }
}

/// Sits behind the Settings window: when Settings is meant to be a tab, shows the tab and closes this window.
private struct SettingsWindowGuard: NSViewRepresentable {
    let enabled: Bool

    final class Anchor: NSView {
        var enabled = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Our own header names the panel, so the window's title is hidden and the content runs up under a clear title bar.
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
            }
            check()
        }
        func check() {
            guard enabled, let window else { return }
            DispatchQueue.main.async {
                if SettingsRouter.inlineOpener?() == true { window.close() }
            }
        }
    }

    func makeNSView(context: Context) -> Anchor { let view = Anchor(); view.enabled = enabled; return view }
    func updateNSView(_ view: Anchor, context: Context) { view.enabled = enabled; view.check() }
}


// MARK: - Finding a section on screen

extension View {
    /// Marks a section of a Settings pane so a search result can scroll to it.
    func settingsAnchor(_ name: String) -> some View { background(SettingsAnchorMarker(name: name)) }
}

/// An invisible AppKit view placed behind a section. The pane's own scroll view cannot be asked to scroll to a SwiftUI id (a grouped Form ignores it), so the section is found
/// by where its marker actually is, and that scroll view is moved to it.
private struct SettingsAnchorMarker: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> SettingsAnchorView { SettingsAnchorView(name: name) }
    func updateNSView(_ view: SettingsAnchorView, context: Context) { view.name = name }
}

final class SettingsAnchorView: NSView {
    var name: String
    init(name: String) { self.name = name; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window != nil { SettingsAnchors.views.add(self) } }
}

@MainActor
enum SettingsAnchors {
    static let views = NSHashTable<SettingsAnchorView>.weakObjects()

    /// Scrolls the pane that holds the section called `name` so the section starts at the top. Returns whether it was found. (A section is a few rows, each with a marker; the top one counts.)
    @discardableResult
    static func reveal(_ name: String) -> Bool {
        #if DEBUG
        let all = views.allObjects
        WallpaperDebug.log("SETTINGS anchors: \(all.count) registered, \(all.filter { $0.window != nil }.count) in a window, \(all.filter { $0.enclosingScrollView != nil }.count) in a scroll view; names \(Set(all.map(\.name)).sorted())")
        #endif
        let candidates = views.allObjects.filter { $0.name == name && $0.window != nil && $0.enclosingScrollView != nil }
        guard let scroll = candidates.first?.enclosingScrollView, let document = scroll.documentView else { return false }
        let inThisPane = candidates.filter { $0.enclosingScrollView === scroll }
        let frames = inThisPane.map { $0.convert($0.bounds, to: document) }
        let clip = scroll.contentView
        let margin: CGFloat = 14
        let target: CGFloat
        if document.isFlipped {
            guard let top = frames.map(\.minY).min() else { return false }
            target = top - margin - scroll.contentInsets.top
        } else {
            guard let top = frames.map(\.maxY).max() else { return false }
            target = top + margin - clip.bounds.height
        }
        let limit = max(0, document.frame.height - clip.bounds.height)
        let y = min(max(target, -scroll.contentInsets.top), limit)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        }
        scroll.reflectScrolledClipView(clip)
        return true
    }
}
