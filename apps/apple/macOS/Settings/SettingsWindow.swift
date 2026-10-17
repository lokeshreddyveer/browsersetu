import AppKit
import SwiftUI

/// The panels of the Settings window, in toolbar order. Every panel holds only controls that change something real.
enum SettingsPanel: String, CaseIterable, Identifiable {
    case general, appearance, tabs, search, privacy, websites, profiles, performance, extensions, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .tabs: "Tabs"
        case .search: "Search"
        case .privacy: "Privacy & Security"
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
        case .privacy: "hand.raised"
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
        case .privacy: 640
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

    static func open(_ panel: SettingsPanel? = nil) {
        if let panel { UserDefaults.standard.set(panel.rawValue, forKey: storageKey) }
        NSApp.activate(ignoringOtherApps: true)
        if let opener { opener() } else { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
    }
}

/// The Settings window: a Safari-style toolbar of panels over native grouped forms. It shares the browser's one
/// `BrowserModel`, so a change here reaches every open browser window at once and is saved as it is made.
struct MacSettingsView: View {
    @EnvironmentObject var model: BrowserModel
    @AppStorage(SettingsRouter.storageKey) private var selected = SettingsPanel.general.rawValue

    private var panel: SettingsPanel { SettingsPanel(rawValue: selected) ?? .general }
    @State private var query = ""

    var body: some View {
        TabView(selection: $selected) {
            ForEach(SettingsPanel.allCases) { item in
                SettingsPanelView(panel: item)
                    .tabItem { Label(item.toolbarLabel, systemImage: item.symbol) }
                    .tag(item.rawValue)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search Settings")
        .overlay(alignment: .topTrailing) { settingsSearch }
        .frame(width: SettingsPanel.width, height: min(panel.height, max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 120)))
        .preferredColorScheme(model.appearance.colorScheme ?? (model.themeIsActive ? model.activeTheme.scheme?.colorScheme : nil))
        .tint(Theme.accent)
        .animation(.easeOut(duration: 0.18), value: selected)
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
                            query = ""
                        } label: {
                            HStack {
                                Text(entry.title).lineLimit(1)
                                Spacer()
                                Text((SettingsPanel(rawValue: entry.mac) ?? .general).title).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 280)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .themedSurface()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(panel.title)
            .accessibilityIdentifier("settings-\(panel.rawValue)")
            .motion(.easeOut(duration: 0.22), value: model.layoutPreset)
            .motion(.easeOut(duration: 0.22), value: model.memoryMode)
            .motion(.easeOut(duration: 0.22), value: model.extensionCenter.extensions.count)
    }

    @ViewBuilder private var content: some View {
        switch panel {
        case .general:
            DefaultBrowserSection()
            StartupSettingsSection()
            StartPageSettingsSection()
            DownloadsSettingsSection()
            SyncSection()
        case .appearance:
            AppearanceSettingsSection()
            DarkPagesSection()
        case .tabs:
            TabPositionSection()
            TabsSettingsSection()
            SplitAndWindowSettingsSection()
            WorkspacesSettingsSection()
        case .search:
            SearchSettingsSection()
            SearchShortcutsSection()
        case .privacy:
            VayuLevelSection(privacy: model.privacy)
            SecurityFactsSection()
            ThreatListSection()
            ProxySection()
            PageDefensesSection()
            SensitiveLockSection()
            ClearOnQuitSection()
            PageMemorySection()
            SearchableCopySection()
            BrowsingDataSection()
        case .websites:
            SitePermissionsSection()
            SavedSignInsSection()
            PasswordsInfoSection()
            PermissionActivitySection()
            SiteZoomSection()
            GlobalStyleSection()
            WebsiteDataSection()
        case .profiles:
            ProfileSettingsSection()
        case .performance:
            MemorySettingsSection()
            NeverSleepSection()
            ResourceMonitorSection()
        case .extensions:
            ExtensionsSettingsSection()
            RemoteExtensionsSection()
            UserScriptsSection()
        case .shortcuts:
            ShortcutsSettingsSection()
        case .advanced:
            AdvancedSettingsSection()
            GesturesSection()
            HealthCheckSection()
            #if DIRECT_BUILD
            UpdatesSettingsSection()
            #endif
            MediaCompatibilitySection()
            LinkCleaningSection()
            SiteIconsSection()
            BookmarkTransferSection()
            ImportExportSection()
            BackupSection()
            RecoverySection()
            AboutSection()
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
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
