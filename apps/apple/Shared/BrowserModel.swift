#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import SetuPrivacyCore
import SwiftUI

/// Where Bookmarks, History and Downloads open.
enum PanelMode: String, CaseIterable, Identifiable {
    case dock, tab, float
    var id: String { rawValue }
    var title: String { switch self { case .dock: "Beside the page"; case .tab: "As a tab"; case .float: "As a floating card" } }
}

enum Sheet: String, Identifiable {
    case bookmarks, history, downloads, pdfEditor, settings, layout, research, sitePrivacy, workbench, findAll, sessions, timeline, dashboard, readingList, note, qr, style, pageTools, selection, shareTabs, shopping, repair, devices, pageSearch, resources
    var id: String { rawValue }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case tabs, bookmarks, history
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .tabs: "square.on.square"
        case .bookmarks: "book"
        case .history: "clock"
        }
    }
}

struct ClosedTab: Equatable {
    let url: URL
    let title: String
    let group: String
    var workspace = ""
}

struct RecoveryState: Equatable {
    let profile: String
    let detail: String
}

/// Application coordinator: owns the core, tab controllers and shell state.
@MainActor
final class BrowserModel: ObservableObject {
    @Published var tabs: [TabController] = []
    @Published var activeID: UInt64?
    @Published private(set) var profileName: String
    @Published private(set) var profiles: [String] = []
    @Published var sheet: Sheet? {
        didSet {
            // Bookmarks, History and Downloads open beside the page on the Mac and the iPad when the person chose to dock them.
            if let opened = sheet, Self.dockable.contains(opened), Self.supportsDock {
                sheet = nil
                #if os(iOS)
                let mode = PanelMode.dock   // the iPad has the dock only; tab and card modes are the Mac's
                #else
                let mode = panelMode
                #endif
                switch mode {
                case .dock: dockedPanel = (dockedPanel == opened) ? nil : opened
                case .tab: showPanelTab(opened)
                case .float: floatingPanel = (floatingPanel == opened) ? nil : opened
                }
            }
        }
    }
    static var supportsDock: Bool {
        #if os(macOS)
        true
        #else
        UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }
    static let dockable: [Sheet] = [.bookmarks, .history, .downloads]
    /// The library panel showing beside the page, if any.
    @Published var dockedPanel: Sheet?
    /// The same panels as a card over the page, when they are not docked.
    @Published var floatingPanel: Sheet?
    @Published var panelMode: PanelMode = .dock { didSet { saveSetting("panel_mode", panelMode.rawValue) } }
    var panelsDocked: Bool { get { panelMode == .dock } set { panelMode = newValue ? .dock : .float } }
    @Published var dockWidth: Double = 380 { didSet { saveSetting("dock_width", String(Int(dockWidth))) } }
    @Published var mediaReport: MediaCapabilityReport?
    @Published var mediaFindings: [MediaPageFinding]?
    @Published var mediaChecking = false
    @Published var pageExtract: PageExtract?
    @Published var rememberReadingPosition = false { didSet { saveSetting("remember_reading", rememberReadingPosition ? "1" : "0") } }
    @Published var keepFormDrafts = false { didSet { saveSetting("keep_form_drafts", keepFormDrafts ? "1" : "0") } }
    @Published var readingPositions: [String: ReadingPosition] = [:] { didSet { saveSetting("reading_positions", encodedMap(readingPositions)) } }
    @Published var formDrafts: [String: FormDraft] = [:] { didSet { saveSetting("form_drafts", encodedMap(formDrafts)) } }
    var pageMemoryTask: Task<Void, Never>?
    @Published var gestureBackForward = true { didSet { saveSetting("gesture_back", gestureBackForward ? "1" : "0"); applyGestures() } }
    @Published var gesturePinchZoom = true { didSet { saveSetting("gesture_pinch", gesturePinchZoom ? "1" : "0"); applyGestures() } }
    @Published var gesturePullRefresh = true { didSet { saveSetting("gesture_pull", gesturePullRefresh ? "1" : "0"); applyGestures() } }
    var gestureOptions: GestureOptions { GestureOptions(backForward: gestureBackForward, pinchZoom: gesturePinchZoom, pullToRefresh: gesturePullRefresh) }
    func applyGestures() { for tab in tabs { tab.engine.setGestures(gestureOptions) } }
    /// Where the active tab's address field sits in the One Row toolbar, so the suggestions open right under it.
    @Published var inlineField = InlineFieldSpan(x: 0, width: 320)
    /// Off until the person turns it on: a searchable copy of the pages read, on this device only.
    @Published var indexPages = false { didSet { saveSetting("index_pages", indexPages ? "1" : "0"); if !indexPages { indexGeneration += 1 } } }
    @Published var indexRetentionDays = 90 { didSet { saveSetting("index_days", String(indexRetentionDays)); pageIndex?.prune(olderThan: indexRetentionDays, maxPages: PageIndexRules.maxPages) } }
    @Published var indexCount = 0
    var indexExcludedHosts = Set<String>() { didSet { indexGeneration += 1 } }
    /// Bumped whenever indexing is switched off, a site is excluded or the copy is erased; a page being read when it changes is not saved.
    var indexGeneration = 0
    var pageIndexStore: PageIndex?
    @Published var spotlightBookmarks = false { didSet { saveSetting("spotlight_bookmarks", spotlightBookmarks ? "1" : "0"); syncSpotlight() } }
    /// Pages opened from a saved session, and how far down each one was.
    var sessionScroll: [UInt64: Double] = [:]
    /// A passage to find on a page as soon as it has loaded (from "Go to passage").
    var pendingPassage: [UInt64: String] = [:]
    var researchBacking: ResearchStore?
    var saveLoginsEnabled = true
    var neverSaveOrigins: Set<String> = []
    var askingAboutLogin = false
    var declinedFill: Set<String> = []
    /// Hold the middle button and drag (Mac): back, forward, close tab and more.
    @Published var mouseGestures = false { didSet { saveSetting("mouse_gestures", mouseGestures ? "1" : "0") } }
    @Published var mouseGestureMap: [String: VimAction] = MouseGesture.defaults
    @Published var gestureHint: String?
    var hintTask: Task<Void, Never>?
    var workbenchBacking: Workbench?
    @Published var pdfEditorURL: URL?
    @Published var previewURL: URL?
    var pendingPDFEdits = Set<String>()
    var spotlightTask: Task<Void, Never>?
    @Published var pageSnapshots: [String: [PageSnapshot]] = [:] { didSet { saveSetting("page_snapshots", encodedMap(pageSnapshots)) } }
    @Published var comparedProducts: [ComparedProduct] = [] { didSet { saveSetting("compared_products", encodedList(comparedProducts)) } }
    @Published var coupons: [SavedCoupon] = [] { didSet { saveSetting("saved_coupons", encodedList(coupons)) } }
    @Published var subscriptions: [Subscription] = [] { didSet { saveSetting("subscriptions", encodedList(subscriptions)) } }
    @Published var pauseInfiniteScroll = false { didSet { saveSetting("pause_infinite", pauseInfiniteScroll ? "1" : "0"); engine.setUserScripts(effectiveUserScripts) } }
    @Published var watchedPages: [String: PageWatch] = [:] { didSet { saveSetting("watched_pages", encodedMap(watchedPages)) } }
    @Published var extractingPage = false
    @Published var notice: String?
    @Published private(set) var activeBookmarked = false
    /// Set while running from a temporary in-memory profile because the real one could not be opened.
    @Published private(set) var recovery: RecoveryState?
    @Published var omniboxFocusTick = 0
    /// A new blank tab asks for the search field in the middle of its page (Mac).
    @Published var startFocusTick = 0
    @Published var privacySheet: PrivacySheet?
    #if DEBUG
    @Published var privacyPopoverRequested = false
    #endif

    // Interface state
    @Published var sidebarVisible = false
    /// When the sidebar is not pinned open, touching the window edge reveals it (it floats over the page).
    /// The user's explicit choice for the sidebar: true keeps it open and docked, false lets it auto-hide to the window edge, nil means
    /// they have not chosen and the layout decides. Saved, so reopening the app restores it.
    @Published private(set) var sidebarPinChoice: Bool?
    @Published var sidebarAutoHide = false { didSet { saveSetting("sidebar_autohide", sidebarAutoHide ? "1" : "0") } }
    @Published var windowFullScreen = false
    /// Custom layout only: put the address bar in the sidebar and drop the top bar.
    @Published var singleToolbarCustom = false { didSet { saveSetting("single_toolbar", singleToolbarCustom ? "1" : "0"); applyLayoutIfNeeded() } }
    /// The centred address bar shown by ⌘L when the sidebar (and so the in-sidebar address bar) is not on screen.
    @Published var floatingAddressVisible = false
    /// Text to put in the search field when it opens (">" starts the command center).
    var pendingAddressPrefill: String?
    @Published var floatingFocusTick = 0
    @Published var sidebarSection: SidebarSection = .tabs
    @Published var overviewVisible = false
    /// Settings as a page inside this window (true) or in their own window; and whether that page is showing now.
    @Published var settingsInTab = false { didSet { saveSetting("settings_in_tab", settingsInTab ? "1" : "0") } }
    @Published var settingsPageVisible = false
    /// iOS shows normal and private tabs as separate sets; macOS mixes them in one strip.
    @Published var privateMode = false
    @Published var activeGroup = ""
    @Published private(set) var groupNames: [String] = []
    let addressBar = AddressBarController()

    // Persisted interface settings (per profile)
    /// The look websites are asked for. Separate from the browser's own theme: the browser can be dark while a site shows its light design.
    @Published var websiteAppearance: AppearanceMode = .system {
        didSet {
            saveSetting("website_appearance", websiteAppearance.rawValue)
            for tab in tabs { tab.applyWebsiteAppearance() }
        }
    }
    /// Sites with their own look for websites, apart from the Settings choice: "light" or "dark", by site.
    @Published private(set) var siteAppearance: [String: String] = [:]
    /// The look of the whole browser (Themes.swift): "midnight" is the default.
    @Published var userThemes: [UserTheme] = []
    @Published var startTile: StartTile = .regular { didSet { saveSetting("start_tile", startTile.rawValue) } }
    /// The side panel on the start page is open.
    @Published var startDrawerOpen = false
    /// The card shown for a download that has just finished.
    @Published var downloadBanner: DownloadBanner?
    var bannerTask: Task<Void, Never>?
    @Published var themeID = "midnight" { didSet { saveSetting("theme", themeID); applyTheme() } }
    @Published var customTheme = CustomTheme()
    @Published var appearance: AppearanceMode = .system { didSet { saveSetting("appearance", appearance.rawValue); applySystemAppearance() } }
    @Published var tabLayout: TabLayout = .separate { didSet { saveSetting("tab_layout", tabLayout.rawValue); applyLayoutIfNeeded() } }
    @Published var layoutPreset: LayoutPreset = .classic { didSet { saveSetting("layout_preset", layoutPreset.rawValue); applyLayoutIfNeeded() } }
    @Published var sidebarPosition: SidebarPosition = .left { didSet { saveSetting("sidebar_position", sidebarPosition.rawValue) } }
    @Published var sidebarWidth: Double = 260 { didSet { saveSetting("sidebar_width", String(Int(sidebarWidth))) } }
    @Published var sidebarRail = false { didSet { saveSetting("sidebar_rail", sidebarRail ? "1" : "0") } }
    @Published var density: InterfaceDensity = .comfortable { didSet { saveSetting("density", density.rawValue) } }
    @Published var paletteVisible = false
    @Published var accent: AccentChoice = .teal { didSet { applyWorkspaceTheme(); saveSetting("accent", accent.rawValue) } }
    @Published var startBackground: StartBackground = .gradient { didSet { saveSetting("start_background", startBackground.rawValue) } }
    @Published var showGreeting = true { didSet { saveSetting("show_greeting", showGreeting ? "1" : "0") } }
    @Published var showRecentlyClosed = true { didSet { saveSetting("show_recently_closed", showRecentlyClosed ? "1" : "0") } }
    @Published var tabPreviews = true { didSet { saveSetting("tab_previews", tabPreviews ? "1" : "0") } }
    /// "restore" reopens last session's tabs; "blank" starts with one empty tab.
    @Published var startup = "restore" { didSet { saveSetting("startup", startup) } }
    @Published private(set) var workspaces: [Workspace] = []
    @Published var activeWorkspace = ""
    // Find in page
    @Published var findVisible = false
    @Published var findText = ""
    /// Text for the "find in every tab" sheet to start with (set by /find).
    var findAllPrefill: String?
    @Published var findFailed = false
    // Focus mode and split view
    @Published var focusMode = false
    @Published var closedTabs: [ClosedTab] = []
    /// What the user wrote down about each tab (see TabOrganizer.swift), the containers they made, their saved split layouts, and whether tabs are drawn as a tree.
    @Published var tabMeta: [UInt64: TabMeta] = [:]
    @Published var containers: [String] = []
    @Published var splitTemplates: [SplitTemplate] = []
    /// Each workspace remembers its own layout (on by default).
    @Published var rememberLayoutPerWorkspace = true { didSet { saveSetting("layout_per_workspace", rememberLayoutPerWorkspace ? "1" : "0") } }
    /// The width of the window the layout is drawn in, kept for the layout diagnostics.
    var windowWidth: Double = 1100
    /// Per-site browser identity, automatic deletion rules, saved decisions that end on their own, and the WebRTC switch (see SitePrivacy.swift).
    @Published var siteUserAgents: [String: String] = [:]
    @Published var siteDeleteRules: [SiteDeleteRule] = []
    var tempPermissions: [String: Double] = [:]
    @Published var blockWebRTC = false { didSet { saveSetting("block_webrtc", blockWebRTC ? "1" : "0"); pushWebPolicy() } }
    var webRTCExceptions = Set<String>()
    /// Sites with scripts switched off, sites whose tabs never go to sleep, and the page switches (see PageDefenses.swift).
    @Published var jsOffSites = Set<String>()
    @Published var neverSleepSites = Set<String>()
    @Published var fingerprintExceptions = Set<String>()
    @Published var randomizeFingerprint = false { didSet { saveSetting("fingerprint_noise", randomizeFingerprint ? "1" : "0"); pushWebPolicy() } }
    @Published var deAMP = true { didSet { saveSetting("de_amp", deAMP ? "1" : "0"); pushWebPolicy() } }
    /// Videos and sound start only after a tap or a key press (on by default); sites that need to play by themselves can be let off.
    @Published var blockAutoplay = true { didSet { saveSetting("block_autoplay", blockAutoplay ? "1" : "0"); pushWebPolicy() } }
    @Published var autoplayExceptions = Set<String>()
    @Published var youtubeRules = YouTubeAdRules.builtIn { didSet { saveJSON("youtube_rules", youtubeRules); pushWebPolicy() } }
    @Published var keepYouTubeRulesFresh = true { didSet { saveSetting("youtube_rules_auto", keepYouTubeRulesFresh ? "1" : "0") } }
    @Published var youtubeRulesChecked: Date?
    @Published var blockVideoAds = true { didSet { saveSetting("video_ads", blockVideoAds ? "1" : "0"); pushWebPolicy() } }
    // Break mode, address bar sources, hover previews, theme schedule, chains, panels, menus (BrowserExtras.swift)
    @Published var addressSources: [AddressSource] = AddressSource.defaults { didSet { saveSetting("address_sources", addressSources.map(\.rawValue).joined(separator: ",")) } }
    @Published var breakActive = false
    @Published var hoverPreviews = true { didSet { saveSetting("hover_previews", hoverPreviews ? "1" : "0") } }
    @Published var hoverDelay = 0.6 { didSet { saveSetting("hover_delay", String(hoverDelay)) } }
    @Published var themeSchedule = ThemeSchedule() { didSet { saveJSON("theme_schedule", themeSchedule); startThemeSchedule() } }
    var themeTimer: Timer?
    @Published var chains: [CommandChain] = [] { didSet { saveJSON("command_chains", chains) } }
    @Published var webPanels: [WebPanel] = [] { didSet { saveJSON("web_panels", webPanels) } }
    @Published var openPanelID: String?
    /// The buttons inside the address bar, in order (Settings › Search › Address Bar Buttons, or right-click the bar).
    @Published var addressBarItems: [AddressBarItem] = AddressBarItem.defaults { didSet { saveSetting("address_bar_items", addressBarItems.map(\.rawValue).joined(separator: ",")) } }
    /// The buttons along the foot of the sidebar, in order (Settings › Tabs › Sidebar Buttons, or right-click the row).
    @Published var sidebarFooter: [SidebarFooterItem] = SidebarFooterItem.defaults { didSet { saveSetting("sidebar_footer", sidebarFooter.map(\.rawValue).joined(separator: ",")) } }
    /// Whether saved passwords are kept in iCloud Keychain (end to end encrypted by Apple) so they appear on the person's other Apple devices.
    @Published var passwordsInICloudKeychain = false { didSet { saveSetting("passwords_icloud_keychain", passwordsInICloudKeychain ? "1" : "0") } }
    /// How many passwords the last restored backup brought back.
    @Published var lastRestoredPasswords = 0
    /// The first-run questions (SetupAssistant.swift) are on screen.
    @Published var showSetup = false
    /// Pop-ups: whether pages are stopped from opening windows without a click, and the sites that may.
    @Published var blockPopups = true { didSet { saveSetting("block_popups", blockPopups ? "1" : "0") } }
    @Published var popupAllowedHosts: Set<String> = [] { didSet { saveSetting("popup_allowed_hosts", popupAllowedHosts.sorted().joined(separator: ",")) } }
    var panelTabID: UInt64?
    @Published var collapsedStacks: Set<String> = []
    @Published var hiddenMenuItems: Set<String> = [] { didSet { saveSetting("hidden_menu_items", hiddenMenuItems.sorted().joined(separator: ",")) } }
    @Published var tabStacks = false { didSet { saveSetting("tab_stacks", tabStacks ? "1" : "0") } }
    /// Tabs whose branch is folded in the sidebar when the tab tree is on.
    @Published var collapsedTreeTabs: Set<UInt64> = []
    @Published var tabTree = false { didSet { saveSetting("tab_tree", tabTree ? "1" : "0"); if tabTree { arrangeAsTree() } } }
    @Published var splitTabID: UInt64? { didSet { if splitTabID == nil { thirdSplitTabID = nil } } }
    /// A third and a fourth panel; each is only ever set while the one before it is.
    @Published var thirdSplitTabID: UInt64? { didSet { if thirdSplitTabID == nil { fourthSplitTabID = nil } } }
    @Published var fourthSplitTabID: UInt64?
    @Published var splitOrientation: SplitOrientation = .sideBySide { didSet { saveSetting("split_orientation", splitOrientation.rawValue) } }
    /// A phone keeps the bar under the thumb; an iPad is held wide, so the bar goes where the eye is, at the top.
    static var defaultAddressBarPosition: AddressBarPosition {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .top : .bottom
        #else
        .bottom
        #endif
    }
    @Published var addressBarPosition: AddressBarPosition = BrowserModel.defaultAddressBarPosition { didSet { saveSetting("address_bar", addressBarPosition.rawValue) } }
    @Published var showContinue = true { didSet { saveSetting("show_continue", showContinue ? "1" : "0") } }
    @Published var showFavorites = true { didSet { saveSetting("show_favorites", showFavorites ? "1" : "0") } }
    @Published var showFrequent = true { didSet { saveSetting("show_frequent", showFrequent ? "1" : "0") } }
    @Published var toolbarItems: [ToolbarItemID] = ToolbarItemID.defaults {
        didSet { saveSetting("toolbar_items", toolbarItems.map(\.rawValue).joined(separator: ",")) }
    }
    private var applyingSettings = false

    let engine: BrowserEngine
    let privacy: PrivacyController
    var downloads: DownloadCoordinator { engine.downloads }
    private(set) var core: BrowserCore
    private let root: String
    /// This profile's folder on disk (the reading list keeps its articles here).
    var profileFolder: URL { URL(fileURLWithPath: root) }
    private var saveTask: Task<Void, Never>?

    private let persistsProfileChoice: Bool

    #if DEBUG
    /// Every model made in this process, so a test run can close their pages when each test ends: pages a test left open would keep their web processes alive for the
    /// rest of the run, and a long run would end with hundreds of them.
    static let liveModels = NSHashTable<BrowserModel>.weakObjects()

    func closeAllPagesForTests() {
        for tab in tabs { tab.shutdown() }
    }
    #endif

    /// `root` and `profile` are overridable so tests can run against isolated storage.
    init(engine: BrowserEngine, root rootOverride: String? = nil, profile profileOverride: String? = nil,
         listFetcher: ListFetching = URLSessionListFetcher()) {
        self.engine = engine
        extensionCenter = ExtensionCenter()
        persistsProfileChoice = rootOverride == nil
        let base: String
        if let rootOverride {
            base = rootOverride
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BrowserSetu", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            base = support.path
        }
        root = base
        let wanted = profileOverride ?? UserDefaults.standard.string(forKey: "profile") ?? "default"
        profileName = wanted
        if let opened = try? BrowserCore.open(root: base, profile: wanted) {
            core = opened
        } else {
            // Profile data unreadable: run from memory rather than touching a damaged database.
            // The original files are never modified; only an explicit reset moves them aside.
            let detail = "Your saved data for “\(wanted)” could not be opened. This is a temporary session; nothing is saved and your original data is untouched."
            if let memory = try? BrowserCore.inMemory() {
                core = memory
            } else if let scratch = try? BrowserCore.open(root: NSTemporaryDirectory() + "browsersetu-recovery-\(UUID().uuidString)", profile: "recovery") {
                // Even a memory database would not open: use a throwaway folder that is never the person's own data.
                core = scratch
            } else {
                // The storage engine itself cannot start, so there is nothing to run on. Stop with a message that says why, instead of an unexplained trap.
                fatalError("Browser Setu could not start its storage engine: the profile “\(wanted)”, a memory database and a scratch folder all failed to open.")
            }
            recovery = RecoveryState(profile: wanted, detail: detail)
        }
        privacy = PrivacyController(engine: engine, cacheDirectory: URL(fileURLWithPath: base).appendingPathComponent("privacy/lists", isDirectory: true),
                                   fetcher: listFetcher)
        privacy.load(from: core)
        profiles = listProfiles(root: base)
        loadUISettings()
        engine.downloads.onFinished = { [weak self] source, filename in
            try? self?.core.recordDownload(url: source?.absoluteString ?? "", filename: filename)
            self?.openFinishedPDFIfWanted(source: source, filename: filename)
            // A card at the foot of the window says it is done; a kind of file that can run code carries its warning in the same card instead of a box to dismiss.
            self?.showDownloadBanner(filename: filename, fileURL: self?.engine.downloads.completed.first, warning: DownloadSafety.warning(forFilename: filename, from: source))
            #if os(iOS)
            // Wallet passes, contact cards and calendar events open in the system sheet that adds them.
            if let file = DownloadCoordinator.locate(filename: filename) { Task { @MainActor in DownloadedFiles.open(file) } }
            #endif
        }
        extensionObserver = extensionCenter.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        attachExtensions()
        windows.add(self)
        #if DEBUG
        Self.liveModels.add(self)
        #endif
    }

    /// Another window of the same browser: it shares everything with `primary` except what a window owns (its tabs, layout, workspace and sheets).
    init(sharing primary: BrowserModel) {
        engine = primary.engine
        extensionCenter = primary.extensionCenter
        persistsProfileChoice = primary.persistsProfileChoice
        root = primary.root
        profileName = primary.profileName
        core = primary.core
        privacy = primary.privacy
        profiles = primary.profiles
        windows = primary.windows
        isSecondary = true
        loadUISettings()
        extensionObserver = extensionCenter.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        windows.add(self)
        #if DEBUG
        Self.liveModels.add(self)
        #endif
    }

    private func attachExtensions() {
        engine.attachExtensions(center: extensionCenter, profile: profileName,
                                directory: URL(fileURLWithPath: root).appendingPathComponent("extensions", isDirectory: true), host: self)
    }

    var active: TabController? { tabs.first { $0.id == activeID } }
    /// The layout actually shown, after applying the preset.
    var resolvedLayout: ResolvedLayout {
        resolveLayout(preset: layoutPreset, customTabLayout: tabLayout, customSidebarVisible: sidebarVisible, customSingleToolbar: singleToolbarCustom)
    }

    var effectiveTabLayout: TabLayout { resolvedLayout.tabLayout }
    var singleToolbar: Bool { resolvedLayout.singleToolbar }
    /// The Floating layout has no top bar and no tab strip at all: a pill and a search button float over the page instead.
    /// One Row layout: tabs and the address field share the toolbar, so the separate tab row is not drawn.
    var singleRow: Bool {
        #if os(macOS)
        return layoutPreset == .inline && !focusMode
        #else
        return false
        #endif
    }
    var topBarHidden: Bool {
        #if os(iOS)
        // The iPhone has no bars at all: a pill at the bottom and a search button at the top right. The iPad keeps its sidebar.
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return layoutPreset == .floating
        #endif
    }
    /// Full screen hides the toolbar until the pointer reaches the top edge (the sidebar layout has none to hide).
    var autoHidesToolbar: Bool {
        (layoutPreset == .custom && toolbarAutoHide) || (windowFullScreen && !singleToolbar)
    }
    /// What a double-click on an empty part of the top bar does.
    @Published var doubleClickAction: DoubleClickAction = .cycleLayout { didSet { saveSetting("double_click", doubleClickAction.rawValue) } }

    /// The layouts a double-click steps through, in order. "Custom" is left out: it is one you build yourself.
    static let layoutCycle: [LayoutPreset] = [.classic, .sidebar, .minimal, .floating, .inline]

    func nextLayout(after preset: LayoutPreset) -> LayoutPreset {
        guard let index = Self.layoutCycle.firstIndex(of: preset) else { return Self.layoutCycle[0] }
        return Self.layoutCycle[(index + 1) % Self.layoutCycle.count]
    }

    func cycleLayout() { layoutPreset = nextLayout(after: layoutPreset) }

    /// Called for a double-click on the window's top area. Returns whether the layout handled it (otherwise the window zooms).
    func handleTopBarDoubleClick() -> Bool {
        guard doubleClickAction == .cycleLayout else { return false }
        cycleLayout()
        return true
    }

    @Published var tintToolbar = true { didSet { saveSetting("tint_toolbar", tintToolbar ? "1" : "0") } }
    /// While a page is read the toolbar and tabs fold into a small pill; scrolling back brings them out again.
    @Published var collapseOnScroll = true {
        didSet { saveSetting("collapse_on_scroll", collapseOnScroll ? "1" : "0"); if !collapseOnScroll { expandChrome() } }
    }
    @Published private(set) var chromeCollapsed = false
    private var scrollChrome = ScrollChrome()
    /// Folding or unfolding resizes the page, and the page shifting under the user's finger must not count as scrolling.
    private var lastChromeChange = Date.distantPast
    static let chromeSettleTime: TimeInterval = 0.6

    /// Only a top toolbar can fold away: the sidebar layout keeps everything in the sidebar.
    var canCollapseChrome: Bool {
        #if os(iOS)
        // The iPad's sidebar holds only the tabs, so the address bar and toolbar can still fold away over the page.
        collapseOnScroll && !focusMode && !singleToolbar && !topBarHidden && !autoHidesToolbar
        #else
        collapseOnScroll && !focusMode && !singleToolbar && !topBarHidden && effectiveTabLayout != .sidebar && !autoHidesToolbar
        #endif
    }

    /// On the iPhone the bottom dock shrinks into a small pill while a page is read, and opens again when scrolling back.
    var canCollapseDock: Bool {
        #if os(iOS)
        collapseOnScroll && topBarHidden && !focusMode
        #else
        false
        #endif
    }

    /// On the Mac in the Floating layout, the pill slides away while a page is read, and comes back when scrolling back. The Search pill
    /// and the speed readout stay.
    var canFoldPill: Bool {
        #if os(macOS)
        collapseOnScroll && topBarHidden && !focusMode
        #else
        false
        #endif
    }

    func pageScrolled(deltaY: Double) {
        guard canCollapseChrome || canCollapseDock || canFoldPill, !addressBar.isEditing, !findVisible, !overviewVisible, !paletteVisible else { return }
        // Only a clear "I am at the top" signal may cut through the settling time.
        guard deltaY >= 100 || Date().timeIntervalSince(lastChromeChange) > Self.chromeSettleTime else { return }
        if scrollChrome.scrolled(by: deltaY) {
            lastChromeChange = Date()
            chromeCollapsed = scrollChrome.collapsed
        }
    }

    func expandChrome() {
        scrollChrome.expand()
        if chromeCollapsed { lastChromeChange = Date(); chromeCollapsed = false }
    }

    // Privacy and memory (per profile)
    @Published var stripTrackingParameters = true { didSet { saveSetting("strip_tracking", stripTrackingParameters ? "1" : "0") } }
    @Published private(set) var strippedLinkCount = 0
    @Published var memoryMode: MemoryMode = .balanced { didSet { saveSetting("memory_mode", memoryMode.rawValue) } }
    @Published var keepPinnedTabs = true { didSet { saveSetting("keep_pinned", keepPinnedTabs ? "1" : "0") } }
    @Published private(set) var threatList = ThreatList.empty
    /// Set when the last launches ended before they finished starting: tabs come back, but none is loaded for you.
    var safeStart = false
    private var sessionAllowedHosts = Set<String>()
    private var recentStrips: [Date] = []
    var lifecycle: TabLifecycle?
    /// Installed web extensions and their toolbar buttons. Its changes republish through the model.
    let extensionCenter: ExtensionCenter
    /// All windows of this browser (this one included). Every window has its own model; they share the database, engine, privacy rules and extensions.
    var windows = WindowRegistry()
    var isSecondary = false
    /// A guest window: every tab is private, nothing is remembered, and the person's bookmarks and passwords are not offered. Mac only.
    @Published var isGuest = false
    /// A secondary window asks its screen to close when its last tab leaves or closes.
    var onWindowShouldClose: (() -> Void)?
    /// An extension fetched from the Chrome Web Store, waiting for the user to approve what it asks for.
    @Published var storeOffer: ExtensionInfo?
    /// The sidebar's list of extensions, opened from the puzzle-piece icon in its footer.
    @Published var sidebarShowsExtensions = false
    @Published var storeBusy = false
    @Published var storeFailure: String?

    /// The Chrome Web Store extension the front tab is showing, if any.
    var storePageExtensionID: String? {
        guard extensionCenter.canInstall, let tab = active, !tab.isPrivate, let url = tab.url, url.scheme == "https",
              ["chromewebstore.google.com", "chrome.google.com"].contains(url.host ?? "") else { return nil }
        return ChromeWebStore.extensionID(from: url.absoluteString)
    }

    /// Downloads an extension from the Chrome Web Store, then offers it for review. Nothing runs until the user approves.
    func addFromChromeWebStore(id: String) {
        guard extensionCenter.canInstall, !storeBusy else { return }
        storeBusy = true
        Task {
            defer { storeBusy = false }
            guard await requireAuthentication("Add an extension") else { return }
            do {
                let package = try await ChromeWebStore.download(id: id)
                defer { try? FileManager.default.removeItem(at: package) }
                let folder = try await ExtensionPackage.unpackAsync(file: package)
                storeOffer = try await extensionCenter.inspect(folder, chromeID: id)
            } catch { storeFailure = error.localizedDescription }
        }
    }
    private var extensionObserver: AnyCancellable?
    @Published var toolbarAutoHide = false { didSet { saveSetting("toolbar_autohide", toolbarAutoHide ? "1" : "0") } }

    /// True when the in-sidebar address bar is actually on screen (pinned, expanded, not in the icon rail).
    var sidebarAddressBarShown: Bool { singleToolbar && sidebarVisible && !sidebarRail && !focusMode }

    /// The one way to open search: the Search button, the site pill and ⌘L all arrive here, so they can never behave differently.
    func openSearch() { focusAddressBar() }

    /// Opens the search panel at the top of the screen whatever the layout (the iPhone's Search button): the address field and its
    /// suggestions come down from the top, never up from a bottom bar.
    /// Ends a search and puts everything back as it was: the page, the tab, nothing typed kept.
    func cancelSearch() {
        addressBar.isEditing = false
        addressBar.clear()
        addressBar.text = ""
        floatingAddressVisible = false
    }

    func openSearchPanel(prefill: String? = nil) {
        floatingAddressVisible = true
        if let prefill { pendingAddressPrefill = prefill }
        DispatchQueue.main.async { [self] in floatingFocusTick += 1 }
    }

    /// Focuses the address bar wherever it currently lives. With no top bar and the sidebar hidden, that is a floating bar.
    func focusAddressBar() {
        #if os(macOS)
        // On a new tab the field in the middle of the page is the one to type in; on a loaded page it is the address bar in the toolbar.
        if let tab = active, tab.isBlank, !floatingAddressVisible { startFocusTick += 1; return }
        #endif
        expandChrome()
        // ⌘L with the pill folded away opens the pill first: it is the same pill, expanded.
        if topBarHidden && pillCollapsed { pillCollapsed = false }
        if focusMode || autoHidesToolbar || topBarHidden || (singleToolbar && !sidebarAddressBarShown) {
            floatingAddressVisible = true
            DispatchQueue.main.async { [self] in floatingFocusTick += 1 }
        } else {
            omniboxFocusTick += 1
        }
    }

    private func applyLayoutIfNeeded() {
        guard !applyingSettings else { return }
        let resolved = resolvedLayout
        if layoutPreset != .custom {
            switch sidebarPinChoice {
            case true?: sidebarVisible = true
            case false?: sidebarVisible = false
            case nil: sidebarVisible = resolved.sidebarVisible
            }
        }
        else if tabLayout == .sidebar { sidebarVisible = true; sidebarSection = .tabs }
    }

    var activeIsPrivate: Bool { active?.isPrivate ?? false }

    var separatesPrivate: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// Tabs shown in the strip, sidebar and overview: current group (and privacy set on iOS), pinned first.
    var visibleTabs: [TabController] {
        let filtered = tabs.filter { $0.id != panelTabID && $0.workspace == activeWorkspace && $0.group == activeGroup && (!separatesPrivate || $0.isPrivate == privateMode) }
        return filtered.filter(\.pinned) + filtered.filter { !$0.pinned }
    }

    /// The profile's search engine: the one the user chose, or Brave Search until they do.
    var searchTemplate: String {
        if let stored = (try? core.getSetting(key: "search_template")) ?? nil, !stored.isEmpty { return stored }
        return SearchEngines.defaultEngine.template
    }

    /// Ask the search engine for suggestions while typing (never in private tabs). Off by choice in Settings → Search.
    /// Fetch each site's small icon (from the site itself) to show beside its name. Saved on this device; never in private tabs.
    @Published var fetchSiteIcons = true { didSet { saveSetting("site_icons", fetchSiteIcons ? "1" : "0"); if !fetchSiteIcons { FaviconStore.shared.clear() } } }
    /// How far each site is zoomed (by host), and the colours of tab groups. Both are saved with the profile.
    @Published private(set) var siteZoom: [String: Double] = [:]
    @Published private(set) var groupColors: [String: String] = [:]
    @Published var clearOnQuit: ClearOnQuit = .never { didSet { saveSetting("clear_on_quit", clearOnQuit.rawValue) } }
    /// The search field above the tabs in the sidebar.
    @Published var tabSearchVisible = false
    @Published var tabSearchQuery = ""
    /// The user's changes to the menu shortcuts (Settings › Shortcuts).
    @Published var shortcuts = ShortcutMap() { didSet { saveSetting("shortcuts", shortcuts.json) } }
    /// The iPhone's ⋮ card is open.
    // iPhone toolbar, address pill, tab overview and page tools (all saved with the profile).
    @Published var phoneLayout = PhoneToolbarLayout.standard { didSet { saveSetting("phone_toolbar", phoneLayout.stored) } }
    @Published var addressDisplay: AddressDisplay = .domain { didSet { saveSetting("address_display", addressDisplay.rawValue) } }
    @Published var showAddressIcon = true { didSet { saveSetting("address_icon", showAddressIcon ? "1" : "0") } }
    /// One-handed use: the search panel opens at the bottom, within thumb reach, instead of the top.
    /// iPhone search opens above the keyboard by default, where the thumb is.
    @Published var searchPanelAtBottom = true { didSet { saveSetting("search_panel_bottom2", searchPanelAtBottom ? "1" : "0") } }
    /// Swiping the address pill sideways switches tabs; swiping it up opens the tab overview.
    @Published var swipeAddressPill = true { didSet { saveSetting("swipe_address", swipeAddressPill ? "1" : "0") } }
    /// Links to a site that has an iPhone app: ask, always open the app, or always stay here. Sites with their own answer override it.
    @Published var appLinkMode: ExternalApps.Mode = .ask {
        didSet { ExternalApps.mode = appLinkMode; saveSetting("app_links", appLinkMode.rawValue) }
    }
    /// Private tabs are hidden behind a blur in the app switcher.
    @Published var blurPrivateSwitcher = true { didSet { saveSetting("blur_private_switcher", blurPrivateSwitcher ? "1" : "0") } }
    @Published private(set) var appLinkSites: [String: String] = [:]
    // Sync between your own devices (see Sync.swift). Off until switched on.
    @Published var iCloudSync = false {
        didSet {
            saveSetting("sync_icloud", iCloudSync ? "1" : "0")
            if iCloudSync { startCloudSync() } else { stopCloudSync() }
        }
    }
    /// The name of the group of devices this profile syncs with. Devices only ever see each other inside one group, so two profiles (or two people) using
    /// the same passphrase still never mix. It defaults to the profile's name; use the same name on every device that should sync.
    @Published var syncGroupName = ""
    /// Devices seen in this group, and what the user decided about each: only approved devices' snapshots are taken in.
    @Published var syncDevices: [SyncDevice] = []
    /// What happened, newest last: kept so a surprise can be explained.
    @Published var syncHistory: [String] = []
    /// When a setting differs between devices: take the newer one (off), or ask which to keep (on).
    @Published var syncAskOnConflict = false { didSet { saveSetting("sync_ask", syncAskOnConflict ? "1" : "0") } }
    @Published var syncConflicts: [SyncConflict] = []
    /// Saved passwords go with sync only when this is on; they travel inside the passphrase-sealed snapshot, never as plain data.
    @Published var syncPasswords = false { didSet { saveSetting("sync_passwords", syncPasswords ? "1" : "0") } }
    /// What every synced item looked like, with its stamp, the last time this device synced; and the clock that stamps this device's changes.
    var syncLedger = SyncState()
    var syncClock = SyncClock()
    var syncSeq = 0
    var syncSeen: [String: Int] = [:]
    @Published var remoteExtensions: [String: [SyncExtension]] = [:]
    @Published var syncSettingsToo = false { didSet { saveSetting("sync_settings", syncSettingsToo ? "1" : "0") } }
    @Published var remoteTabs: [RemoteTabs] = []
    @Published var lastSync: Date?
    /// Which kinds of thing sync carries (settings and passwords keep their own switches), tabs sent between devices, and when sync last worked.
    @Published var syncCategorySet: Set<SyncCategory> = SyncCategory.defaultOn
    @Published var outbox: [SentTab] = []
    @Published var inbox: [SentTab] = []
    var sentSeen = Set<String>()
    @Published var lastPush: Date?
    @Published var lastPull: Date?
    @Published var syncError: String?
    @Published var isSyncing = false
    @Published var syncStatus = ""
    /// iPhone: how much of the page's foot the floating toolbar covers; set by the screen, applied to every tab's scroll view.
    var phoneBottomInset: CGFloat = 0 { didSet { if oldValue != phoneBottomInset { for tab in tabs { tab.applyBottomInset() } } } }
    /// The status-bar strip the page must stay clear of when it runs to the top edge of the screen.
    /// Whether the page in front has its own bar fixed to the top or bottom edge (iPhone layout only).
    @Published private(set) var activeFixedTop = false
    @Published private(set) var activeFixedBottom = false
    func pageFixedBarsChanged(_ tab: TabController) {
        guard tab.id == activeID else { return }
        activeFixedTop = tab.fixedTop; activeFixedBottom = tab.fixedBottom
    }
    var phoneTopInset: CGFloat = 0 { didSet { if oldValue != phoneTopInset { for tab in tabs { tab.applyBottomInset() } } } }
    /// iPhone: the island opens by itself when the network speed changes a lot. Off until switched on.
    @Published var speedPopups = false { didSet { saveSetting("speed_popups", speedPopups ? "1" : "0") } }
    var showSpeedHandler: (() -> Void)?
    func showNetworkSpeed() {
        guard showSpeedPill else { notice = "Turn on “Show device network speed” in Settings first."; return }
        showSpeedHandler?()
    }
    /// Why the Dynamic Island readout is or is not running (iPhone).
    @Published var speedActivityStatus = ""
    var lastSyncedSettings = Date.distantPast
    var cloudSync: CloudSync?
    var cloudPushTask: Task<Void, Never>?
    var syncDeviceID: String {
        if let id = (try? core.getSetting(key: "sync_device_id")) ?? nil, !id.isEmpty { return id }
        let id = UUID().uuidString
        try? core.setSetting(key: "sync_device_id", value: id)
        return id
    }
    /// Saved camera, microphone and location access lapses after this long, so a site has to ask again.
    @Published var permissionExpiry: PermissionExpiry = .month { didSet { saveSetting("permission_expiry", permissionExpiry.rawValue); expirePermissions() } }
    private(set) var permissionDates: [String: Double] = [:]
    func setPermissionDates(_ map: [String: Double]) { permissionDates = map; saveSetting("permission_dates", encodedMap(map)) }
    func setAppLinkSite(_ host: String, to answer: String?) {
        if let answer { appLinkSites[host] = answer } else { appLinkSites.removeValue(forKey: host) }
        ExternalApps.sites = appLinkSites
        saveSetting("app_link_sites", encodedMap(appLinkSites))
    }
    /// Which way the page slides while a swipe switches tabs: 1 from the right (next tab), -1 from the left, 0 for a plain change.
    @Published var tabSlide = 0
    @Published var overviewStyle: OverviewStyle = .grid { didSet { saveSetting("overview_style", overviewStyle.rawValue) } }
    @Published var overviewGrouped = false { didSet { saveSetting("overview_grouped", overviewGrouped ? "1" : "0") } }
    @Published var overviewSort: OverviewSort = .manual { didSet { saveSetting("overview_sort", overviewSort.rawValue) } }
    @Published var darkPages: DarkPages = .off { didSet { saveSetting("dark_pages", darkPages.rawValue) } }
    @Published private(set) var darkSites: Set<String> = []
    /// In Low Power Mode, tabs that are not in use are released sooner.
    @Published var lowPowerSavesMemory = true { didSet { saveSetting("low_power_memory", lowPowerSavesMemory ? "1" : "0") } }
    /// Tabs that cannot be closed by accident, and named sets of tabs saved to open again later.
    /// Downloads are sorted into folders by kind (Images, Documents…) inside the downloads folder.
    @Published var maxDownloads = DownloadQueueRules.defaultConcurrent { didSet { saveSetting("download_concurrent", String(maxDownloads)); engine.downloads.maxConcurrent = maxDownloads } }
    @Published var organizeDownloads = false { didSet { saveSetting("organize_downloads", organizeDownloads ? "1" : "0"); engine.downloads.organize = organizeDownloads } }
    @Published var userScripts: [UserScript] = []
    /// Ask for Touch ID, Face ID or the device passcode before sensitive changes (backup, clearing data, scripts, extensions, protection off).
    @Published var lockSensitiveSettings = false { didSet { if !applyingSettings { saveSetting("lock_sensitive", lockSensitiveSettings ? "1" : "0") } } }
    var lastAuthentication = Date.distantPast
    @Published private(set) var readingList: [ReadingItem] = []
    @Published private(set) var siteNotes: [String: String] = [:]
    @Published private(set) var siteStyles: [String: String] = [:]
    @Published private(set) var bookmarkTags: [String: [String]] = [:]
    @Published private(set) var customSearchShortcuts: [String: String] = [:]
    /// Text handed to the system's on-device translation sheet; nil when it is not showing.
    @Published var translationText: String?
    @Published private(set) var permissionLog: [PermissionEvent] = []
    @Published private(set) var lockedTabIDs: Set<UInt64> = []
    @Published private(set) var savedSessions: [SavedSession] = []
    /// The page that opens at launch when Settings says so (http or https only).
    @Published var homepage = "" { didSet { saveSetting("homepage", homepage) } }
    var homepageURL: URL? {
        guard let url = URL(string: homepage.trimmingCharacters(in: .whitespaces)), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    /// The sidebar shows the downloads list in place of the tabs.
    @Published var sidebarShowsDownloads = false

    /// In the Floating layout the pill and the Search button fold into one small handle, clear of the page.
    @Published var pillCollapsed = false { didSet { saveSetting("pill_collapsed", pillCollapsed ? "1" : "0") } }
    // MARK: Proxy
    @Published private(set) var proxy: ProxyConfig?
    @Published var proxyEnabled = false

    /// Saves the proxy the user typed (the password goes to the Keychain, not the settings) and turns it on.
    func saveProxy(_ config: ProxyConfig, password: String) {
        proxy = config
        ProxyConfig.setPassword(password)
        saveSetting("proxy_kind", config.kind.rawValue); saveSetting("proxy_host", config.host)
        saveSetting("proxy_port", String(config.port)); saveSetting("proxy_user", config.username)
        setProxyEnabled(true)
    }

    func setProxyEnabled(_ on: Bool) {
        let usable = on && proxy != nil
        proxyEnabled = usable
        saveSetting("proxy_on", usable ? "1" : "0")
        ProxyState.active = usable
        engine.setProxy(usable ? proxy : nil, password: usable ? ProxyConfig.password : nil)
        if usable { notice = "Pages now load through your proxy. Open tabs keep their connection until you reload them." }
    }

    func forgetProxy() {
        setProxyEnabled(false)
        proxy = nil
        ProxyConfig.setPassword("")
        for key in ["proxy_kind", "proxy_host", "proxy_port", "proxy_user"] { saveSetting(key, "") }
    }

    @Published var showSpeedPill = false { didSet { saveSetting("speed_pill", showSpeedPill ? "1" : "0") } }
    @Published var searchSuggestionsEnabled = false { didSet { saveSetting("search_suggestions", searchSuggestionsEnabled ? "1" : "0") } }

    // MARK: Lifecycle

    var hasStarted = false
    /// While the first tab opens at launch, the address bar is not opened for typing: the window should simply appear.
    private var openingFirstTab = false
    private var pendingIncoming: [URL] = []

    /// A link handed to the browser by another app (when it is the default browser) or by the system. Opens in a new tab; one that
    /// arrives before the browser has finished starting waits for it.
    func openIncoming(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return }
        guard hasStarted else { pendingIncoming.append(url); return }
        _ = openTab(url: url, isPrivate: false)
    }

    func start() async {
        await engine.prepare()
        // The small built-in rules are compiled and attached before any tab exists, so the first request is already filtered. The big
        // downloaded lists take far longer to compile, so they are added in the background and never hold up the window.
        await privacy.apply(includeDownloaded: false)
        await privacy.settle()            // an earlier scheduled change must not leave the state half-applied
        expirePermissions()
        expireTemporaryPermissions(atStart: true)
        IntentInbox.attach { [weak self] in self?.workbench.handle($0) }
        downloads.store = profileFolder.appendingPathComponent("downloads", isDirectory: true)
        pushWebPolicy()
        if persistsProfileChoice {
            safeStart = LaunchGuard.isLoop(unfinishedLaunches: LaunchGuard.begin(root: root))
            let folder = root
            Task { try? await Task.sleep(for: .seconds(15)); LaunchGuard.markHealthy(root: folder) }
        }
        await applyClearOnQuit()
        await runStartupDeleteRules()
        openingFirstTab = true
        restoreOrOpenFirstTab()
        openingFirstTab = false
        if !isSecondary { windows.loadPendingRestores(from: self) }
        closeLeftoverScratchTabs()
        if lifecycle == nil {
            let manager = TabLifecycle(model: self)
            manager.start()
            lifecycle = manager
        }
        Task {
            await privacy.apply()
            await privacy.fetchStandardListsIfMissing()
            await privacy.updateIfDue()
        }
        hasStarted = true
        startCloudSync()
        for url in pendingIncoming { _ = openTab(url: url, isPrivate: false) }
        pendingIncoming = []
        #if DEBUG
        await applyDebugUIState()
        #endif
    }

    #if DEBUG
    /// Debug-only: `-UIState <name>` puts the window into a known state so it can be screenshotted without input.
    private func applyDebugUIState() async {
        // Debug only: `-UIInstallExtension <folder>` installs that unpacked extension at start, for looking at it on a simulator.
        if let path = UserDefaults.standard.string(forKey: "UIInstallExtension") {
            do { _ = try await extensionCenter.inspect(URL(fileURLWithPath: path)); try await extensionCenter.installPending() } catch { notice = "Debug install failed: \(error)" }
        }
        if let theme = UserDefaults.standard.string(forKey: "UITheme") { themeID = theme }
        guard let state = UserDefaults.standard.string(forKey: "UIState") else { return }
        let base = "http://127.0.0.1:18765"
        switch state {
        case "none": break
        case "minimal": layoutPreset = .minimal
        case "many-tabs":
            active?.load(URL(string: base + "/p/Documentation")!)
            for name in ["Inbox", "Calendar", "Project plan", "A rather long page title that will truncate", "News", "Maps", "Music"] {
                openTab(url: URL(string: base + "/p/" + name.replacingOccurrences(of: " ", with: "-")), isPrivate: false, select: false)
            }
            if let first = tabs.first { togglePin(first) }
        case "sidebar-tabs":
            layoutPreset = .sidebar
            active?.load(URL(string: base + "/p/Documentation")!)
            for name in ["Inbox", "Calendar", "Project-plan", "News"] { openTab(url: URL(string: base + "/p/" + name), isPrivate: false, select: false) }
            if let first = tabs.first { togglePin(first) }
            favoritesDemo()
        case "floating": layoutPreset = .floating
        case "sidebar-url":
            layoutPreset = LayoutPreset(rawValue: UserDefaults.standard.string(forKey: "UILayout") ?? "") ?? .sidebar
            if let text = UserDefaults.standard.string(forKey: "UIURL"), let url = URL(string: text) { active?.load(url) }
        case "url", "url-darken":
            // A real page for looking at how websites render. -UIURL <address>; "url-darken" also turns Dark Pages on for every site.
            if state == "url-darken" { darkPages = .always }
            if let text = UserDefaults.standard.string(forKey: "UIURL"), let url = URL(string: text) { active?.load(url) }
        case "inline":
            layoutPreset = .inline
            active?.load(URL(string: base + "/p/Documentation")!)
            for name in ["Inbox", "Calendar", "News", "Maps"] { openTab(url: URL(string: base + "/p/" + name), isPrivate: false, select: false) }
        case "sidebar": layoutPreset = .sidebar
        case "workspaces":
            createWorkspace("Dev", icon: "hammer"); createWorkspace("Research", icon: "book"); setWorkspaceAccent("Research", accent: .purple)
            layoutPreset = .sidebar
        case "sidebar-right-rail": layoutPreset = .sidebar; sidebarPosition = .right; sidebarRail = true
        case "classic-page":
            active?.load(URL(string: base + "/page")!)
        case "split3", "split4":
            active?.load(URL(string: base + "/p/One")!)
            let more = (state == "split4" ? ["Two", "Three", "Four"] : ["Two", "Three"]).map { openTab(url: URL(string: base + "/p/" + $0), isPrivate: false, select: false) }
            openSplit(with: more[0])
            for tab in more.dropFirst() { addThirdPanel(with: tab) }
        case "split":
            let other = openTab(url: nil, isPrivate: false, select: false)
            openSplit(with: other)
        case "focus":
            active?.load(URL(string: base + "/page")!)
            toggleFocusMode()
        case "palette": paletteVisible = true
        case "workbench": sheet = .workbench
        case "extension-popup":
            if let first = extensionCenter.actions.first { try? await Task.sleep(for: .seconds(2)); extensionCenter.perform(actionFor: first.id) }
        case "search": openSearchPanel(prefill: UserDefaults.standard.string(forKey: "UISearchText"))
        case "overview":
            active?.load(URL(string: base + "/page")!)
            newTab()
            try? await Task.sleep(for: .seconds(1.5))
            showOverview()
        case "settings": sheet = .settings
        case "privacy-popover":
            active?.load(URL(string: base + "/page")!)
            addressBar.isEditing = false
            try? await Task.sleep(for: .seconds(1.5))
            privacyPopoverRequested = true
        case "privacy-off": privacy.setAdBlocking(false); privacy.setAntiTracking(false)
        case "workspaces":
            createWorkspace("Work", icon: "briefcase"); createWorkspace("Dev", icon: "hammer")
            layoutPreset = .sidebar
        default: break
        }
        try? await Task.sleep(for: .seconds(6))
        #if os(macOS)
        let line = "state=\(state) preset=\(layoutPreset) effective=\(effectiveTabLayout) sidebarVisible=\(sidebarVisible) autoHide=\(sidebarAutoHide) rail=\(sidebarRail) tabs=\(tabs.count) fullscreen=\(windowFullScreen) windows=\(NSApp.windows.map { "\($0.frame.size) fs=\($0.styleMask.contains(.fullScreen)) vis=\($0.isVisible) space=\($0.isOnActiveSpace) lvl=\($0.level.rawValue)" })"
        try? line.write(toFile: NSTemporaryDirectory() + "uistate.txt", atomically: true, encoding: .utf8)
        // Renders the window's own view tree to a PNG, so layout can be inspected without screen capture.
        if let view = NSApp.windows.filter({ $0.frame.width > 400 }).max(by: { $0.frame.height < $1.frame.height })?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "uishot-\(state).png"))
        }
        #endif
    }
    #endif

    #if DEBUG
    private func favoritesDemo() {}
    #endif

    private func restoreOrOpenFirstTab() {
        if startup == "homepage", let page = homepageURL {
            openTab(url: page, isPrivate: false)
            return
        }
        if startup == "restore", let session = try? core.restoreSession() {
            for info in session.tabs {
                let t = TabController(info: info, model: self, restoredURL: URL(string: info.url))
                tabs.append(t)
                if !t.isPrivate { extensionCenter.tabOpened(t) }
            }
            mergeGroupNamesFromTabs()
            let index = Int(session.activeIndex)
            let target = tabs[min(index, tabs.count - 1)]
            activeGroup = target.group
            activeWorkspace = target.workspace
            if safeStart {
                // The last starts ended abruptly, so nothing is loaded until the user chooses a tab.
                openTab(url: nil, isPrivate: false)
                notice = "Browser Setu closed unexpectedly the last few times it opened. Your tabs are back, but none has been loaded."
            } else {
                select(target.id)
            }
        } else {
            openTab(url: nil, isPrivate: false)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        if windows.count > 1 || isSecondary { windows.saveWindowLayout(in: self) }
        try? core.saveSession(activeTabId: activeID ?? 0)
    }

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
            self?.scheduleCloudPush()
        }
    }

    // MARK: Tabs

    @discardableResult
    /// Opens Settings as a tab, or brings the one already open to the front.
    func showPanelTab(_ sheet: Sheet) {
        guard let url = TabController.panelURL(sheet) else { return }
        if let existing = tabs.first(where: { $0.url == url }) { select(existing.id); return }
        openTab(url: url, isPrivate: false)
    }

    func showSettingsTab() {
        if let existing = tabs.first(where: \.isSettingsPage) { select(existing.id); return }
        openTab(url: TabController.settingsURL, isPrivate: false)
    }

    func openTab(url: URL?, isPrivate requestedPrivate: Bool, select makeActive: Bool = true, opener: TabController? = nil, container: String? = nil, scratch: Bool = false) -> TabController {
        let isPrivate = requestedPrivate || isGuest
        let info = core.createTab(url: "about:blank", private: isPrivate)
        // Written down before the tab exists: its engine reads the container to choose where the page keeps its data.
        var meta = TabMeta()
        if !isPrivate { meta.container = container; meta.scratch = scratch ? true : nil; meta.parent = opener?.id }
        if !meta.isEmpty { tabMeta[info.id] = meta; saveTabMeta() }
        let tab = TabController(info: info, model: self)
        if !activeWorkspace.isEmpty {
            try? core.setTabWorkspace(tabId: tab.id, workspace: activeWorkspace)
            tab.workspace = activeWorkspace
        }
        if !activeGroup.isEmpty, !isPrivate {
            try? core.setTabGroup(tabId: tab.id, group: activeGroup)
            tab.group = activeGroup
        }
        tabs.append(tab)
        placeAfterOpener(tab)
        if !isPrivate { extensionCenter.tabOpened(tab) }
        if separatesPrivate { privateMode = isPrivate }
        if makeActive { select(tab.id) }
        if let url { tab.load(url) }
        else if makeActive && !openingFirstTab {
            #if os(macOS)
            startFocusTick += 1      // the blank tab shows its own search field; the toolbar's keeps its focus for ⌘L
            #else
            focusAddressBar()
            #endif
        }
        saveSoon()
        return tab
    }

    /// New blank tab in the current group (and private set on iOS).
    @discardableResult
    func newTab() -> TabController {
        Haptics.tap()
        return openTab(url: nil, isPrivate: separatesPrivate ? privateMode : false)
    }

    func select(_ id: UInt64) {
        Perf.measure("Select tab") { selectTab(id: id) }
    }

    private func selectTab(id: UInt64) {
        if let previous = active, previous.id != id {
            previous.lastActive = Date()
            Task { await previous.captureSnapshot() }
        }
        let previousTab = active
        expandChrome()
        activeID = id
        if let tab = active { activeFixedTop = tab.fixedTop; activeFixedBottom = tab.fixedBottom }
        active?.ensureLoaded()
        if let current = active, !current.isPrivate { extensionCenter.tabActivated(current, previous: previousTab.flatMap { $0.isPrivate ? nil : $0 }) }
        if let tab = active, tab.workspace != activeWorkspace { activeWorkspace = tab.workspace }
        if let tab = active, tab.group != activeGroup { activeGroup = tab.group }
        if separatesPrivate, let tab = active { privateMode = tab.isPrivate }
        refreshBookmarkState()
        // A navigation/tab update must not replace the user's in-progress address edit.
        // Escape restores the newly selected tab's address; Return submits to that tab.
        saveSoon()
    }

    /// Closes every tab in this view (this workspace and group), pinned ones too, and leaves one fresh tab.
    func closeAllTabs() {
        for id in visibleTabs.map(\.id) { closeTab(id: id) }
        if visibleTabs.isEmpty { newTab() }
    }

    func setSiteStyles(_ map: [String: String]) { siteStyles = map; saveSetting("site_styles", encodedMap(map)) }
    func setSiteNotes(_ map: [String: String]) { siteNotes = map; saveSetting("site_notes", encodedMap(map)) }
    func setBookmarkTags(_ map: [String: [String]]) { bookmarkTags = map.filter { !$0.value.isEmpty }; saveSetting("bookmark_tags", encodedMap(bookmarkTags)) }
    func setSearchShortcuts(_ map: [String: String]) { customSearchShortcuts = map; saveSetting("search_shortcuts", encodedMap(map)) }
    func setReadingList(_ list: [ReadingItem]) { readingList = list; ReadingStore.saveIndex(list, root: profileFolder) }

    func setLockedTabs(_ ids: Set<UInt64>) {
        lockedTabIDs = ids
        saveSetting("locked_tabs", (try? String(data: JSONEncoder().encode(ids.sorted()), encoding: .utf8)) ?? "[]")
    }

    func setSavedSessions(_ list: [SavedSession]) {
        savedSessions = list
        saveSetting("saved_sessions", (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]")
    }

    func closeTab(id: UInt64, force: Bool = false) {
        Haptics.tap()
        guard force || !lockedTabIDs.contains(id) else { notice = "That tab is locked. Unlock it to close it."; return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeID
        adoptChildren(ofClosing: id)
        let closing = tabs.remove(at: index)
        if !closing.isPrivate { extensionCenter.tabClosed(closing) }
        // Private and scratch tabs are never remembered; blank tabs have nothing to reopen.
        if !closing.isPrivate, tabMeta[id]?.scratch != true, !closing.isBlank, let url = closing.url {
            closedTabs.append(ClosedTab(url: url, title: closing.title, group: closing.group, workspace: closing.workspace))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        forgetSplitPanel(id)
        if tabMeta[id] != nil { tabMeta[id] = nil; saveTabMeta() }
        let closedHost = closing.url?.host
        closing.shutdown()
        try? core.closeTab(tabId: id)
        if !closing.isPrivate { siteTabClosed(host: closedHost) }
        if !tabs.contains(where: \.isPrivate), !windows.anotherWindowHasPrivateTabs(besides: self) { engine.privateSessionEnded() }
        if wasActive || active == nil {
            if let next = visibleTabs.first(where: { _ in true }) ?? tabs.first {
                let neighbours = visibleTabs
                select((neighbours.indices.contains(min(index, neighbours.count - 1)) && !neighbours.isEmpty
                        ? neighbours[min(index, neighbours.count - 1)] : next).id)
            } else if isSecondary {
                activeID = nil
                onWindowShouldClose?()       // a window with no tab left closes; the first window always keeps one
            } else {
                newTab()
            }
        }
        saveSoon()
        if isSecondary || windows.count > 1 { windows.saveWindowLayout(in: self) }
    }

    func reopenClosedTab() { reopenClosedTab(at: closedTabs.count - 1) }

    func reopenClosedTab(at index: Int) {
        guard closedTabs.indices.contains(index) else { return }
        let last = closedTabs.remove(at: index)
        if last.workspace != activeWorkspace, workspaces.contains(where: { $0.name == last.workspace }) || last.workspace.isEmpty {
            activeWorkspace = last.workspace
        }
        let tab = openTab(url: last.url, isPrivate: false)
        if !last.group.isEmpty, groupNames.contains(last.group) { moveTab(tab, to: last.group) }
    }

    func closeOtherTabs(except id: UInt64) {
        for tab in visibleTabs where tab.id != id && !tab.pinned { closeTab(id: tab.id) }
    }

    func duplicateTab(_ tab: TabController) {
        guard let url = tab.url, !tab.isBlank else { return }
        openTab(url: url, isPrivate: tab.isPrivate)
    }

    func selectAdjacent(_ offset: Int) {
        let list = visibleTabs
        guard let current = list.firstIndex(where: { $0.id == activeID }), !list.isEmpty else { return }
        select(list[(current + offset + list.count) % list.count].id)
    }

    /// A swipe on the address bar: the next or previous tab, the page sliding in from that side. Swiping forward from the last tab opens
    /// a new one, as in Safari; backward from the first does nothing.
    func swipeToTab(_ offset: Int) {
        let list = visibleTabs
        guard let current = list.firstIndex(where: { $0.id == activeID }) else { return }
        let target = current + offset
        if target >= list.count { tabSlide = 1; _ = newTab() }
        else if target >= 0 { tabSlide = offset; select(list[target].id) }
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.tabSlide = 0 }
    }

    /// ⌘1…⌘8 select by position; ⌘9 selects the last tab, as in Safari.
    func selectTab(number: Int) {
        let list = visibleTabs
        guard !list.isEmpty else { return }
        let index = number == 9 ? list.count - 1 : number - 1
        if list.indices.contains(index) { select(list[index].id) }
    }

    func togglePin(_ tab: TabController) {
        Haptics.tap()
        tab.pinned.toggle()
        try? core.setTabPinned(tabId: tab.id, pinned: tab.pinned)
        objectWillChange.send()
        saveSoon()
    }

    // MARK: Reordering

    /// Moves `tab` so it sits just before `target` (or at the end when `target` is nil).
    func reorder(_ tabID: UInt64, before targetID: UInt64?) {
        guard let from = tabs.firstIndex(where: { $0.id == tabID }), tabID != targetID else { return }
        let moving = tabs.remove(at: from)
        let to = targetID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? tabs.count
        // Pinned tabs stay ahead of unpinned ones within the same view.
        tabs.insert(moving, at: to)
        try? core.moveTab(tabId: tabID, index: UInt32(to))
        saveSoon()
    }

    // MARK: Workspaces

    func createWorkspace(_ name: String, icon: String = "person") {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 30, !workspaces.contains(where: { $0.name == clean }) else { return }
        workspaces.append(Workspace(name: clean, icon: icon, preset: nil))
        saveWorkspaces()
    }

    /// A workspace changed on another device: its name, icon, colour and preset are taken, and this device's own layout for it is kept.
    func upsertWorkspaceFromSync(_ name: String, _ value: SyncWorkspace) {
        if let i = workspaces.firstIndex(where: { $0.name == name }) { workspaces[i].icon = value.icon; workspaces[i].preset = value.preset; workspaces[i].accent = value.accent }
        else if workspaces.count < 30, !name.isEmpty, name.count <= 30 { workspaces.append(Workspace(name: name, icon: value.icon, preset: value.preset, accent: value.accent)) }
    }

    func renameWorkspace(_ old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 30, !workspaces.contains(where: { $0.name == clean }),
              let i = workspaces.firstIndex(where: { $0.name == old }) else { return }
        workspaces[i].name = clean
        for tab in tabs where tab.workspace == old {
            tab.workspace = clean
            try? core.setTabWorkspace(tabId: tab.id, workspace: clean)
        }
        if activeWorkspace == old { activeWorkspace = clean }
        saveWorkspaces()
        saveSoon()
    }

    func setWorkspaceIcon(_ name: String, icon: String) {
        guard let i = workspaces.firstIndex(where: { $0.name == name }) else { return }
        workspaces[i].icon = icon
        saveWorkspaces()
    }

    func setWorkspacePreset(_ name: String, preset: LayoutPreset?) {
        guard let i = workspaces.firstIndex(where: { $0.name == name }) else { return }
        workspaces[i].preset = preset?.rawValue
        saveWorkspaces()
        if name == activeWorkspace, let preset { layoutPreset = preset }
    }

    func moveWorkspace(_ name: String, by offset: Int) {
        guard let i = workspaces.firstIndex(where: { $0.name == name }) else { return }
        let j = i + offset
        guard workspaces.indices.contains(j) else { return }
        workspaces.swapAt(i, j)
        saveWorkspaces()
    }

    /// Deleting a workspace keeps its tabs; they move to the default workspace.
    func deleteWorkspace(_ name: String) {
        for tab in tabs where tab.workspace == name {
            tab.workspace = ""
            try? core.setTabWorkspace(tabId: tab.id, workspace: "")
        }
        workspaces.removeAll { $0.name == name }
        if activeWorkspace == name { switchWorkspace("") }
        saveWorkspaces()
        saveSoon()
    }

    func switchWorkspace(_ name: String) {
        guard name.isEmpty || workspaces.contains(where: { $0.name == name }) else { return }
        // Each workspace keeps its own window arrangement: what it looked like when it was left is what comes back.
        if rememberLayoutPerWorkspace, name != activeWorkspace { rememberLayout(forWorkspace: activeWorkspace) }
        activeWorkspace = name
        activeGroup = ""
        applyWorkspaceTheme()
        if rememberLayoutPerWorkspace, let remembered = layout(forWorkspace: name) {
            apply(remembered)
        } else if let preset = workspaces.first(where: { $0.name == name })?.preset.flatMap(LayoutPreset.init(rawValue:)) {
            layoutPreset = preset
        }
        saveSetting("startup_workspace", name)
        Task { await workbench.applyExtensionProfile(forWorkspace: name) }
        if let first = visibleTabs.first { select(first.id) } else { newTab() }
    }

    func workspaceTabCount(_ name: String) -> Int {
        tabs.filter { $0.workspace == name && !$0.isPrivate }.count
    }

    // MARK: Dark pages and low power

    func shouldDarken(host: String?) -> Bool {
        switch darkPages {
        case .off: false
        case .always: true
        case .chosen: FaviconStore.key(forHost: host).map { darkSites.contains($0) } ?? false
        }
    }

    // MARK: Website appearance

    /// The look asked of a site's pages: its own choice if it has one, otherwise the Settings choice.
    func effectiveWebsiteAppearance(host: String?) -> AppearanceMode {
        FaviconStore.key(forHost: host).flatMap { siteAppearance[$0] }.flatMap(AppearanceMode.init(rawValue:)) ?? websiteAppearance
    }

    func siteHasAppearance(_ host: String?) -> Bool { FaviconStore.key(forHost: host).map { siteAppearance[$0] != nil } ?? false }

    /// Sets (or with nil, clears) one site's look. Cookies, logins and everything else stay as they are.
    func setSiteAppearance(_ host: String?, _ mode: AppearanceMode?) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if let mode, mode != .system { siteAppearance[key] = mode.rawValue } else { siteAppearance.removeValue(forKey: key) }
        saveSetting("site_appearance", encodedMap(siteAppearance))
        for tab in tabs where FaviconStore.key(forHost: tab.url?.host) == key { tab.applyWebsiteAppearance() }
    }

    /// Puts a site back to how it normally looks: no look of its own, and Darken off for it.
    func resetSiteAppearance(_ host: String?) {
        setSiteAppearance(host, nil)
        if isDarkSite(host) { setDarkSite(host, false) }
        for tab in tabs where FaviconStore.key(forHost: tab.url?.host) == FaviconStore.key(forHost: host) { tab.applyDarkPages(); tab.applyWebsiteAppearance() }
        notice = "This site’s appearance was reset."
    }

    func isDarkSite(_ host: String?) -> Bool { FaviconStore.key(forHost: host).map { darkSites.contains($0) } ?? false }

    /// Turns dark pages on or off for one site. Choosing a site while the setting is Off switches it to "only sites I choose".
    func setDarkSite(_ host: String?, _ on: Bool) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        if on && darkPages == .off { darkPages = .chosen }
        if on { darkSites.insert(key) } else { darkSites.remove(key) }
        let map = Dictionary(uniqueKeysWithValues: darkSites.map { ($0, true) })
        saveSetting("dark_sites", encodedMap(map))
    }

    /// The memory mode in force: Memory Saver while Low Power Mode is on, when the user allows it.
    var effectiveMemoryMode: MemoryMode {
        lowPowerSavesMemory && ProcessInfo.processInfo.isLowPowerModeEnabled && memoryMode == .balanced ? .saver : memoryMode
    }

    static func decodeMap<T: Decodable>(_ json: String?, as: T.Type) -> [String: T] {
        guard let data = json?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: T].self, from: data)) ?? [:]
    }

    static func decodeList<T: Decodable>(_ json: String?) -> [T] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private func encodedList<T: Encodable>(_ list: [T]) -> String {
        (try? String(data: JSONEncoder().encode(list), encoding: .utf8)) ?? "[]"
    }

    func encodedMap<T: Encodable>(_ map: [String: T]) -> String {
        (try? String(data: JSONEncoder().encode(map), encoding: .utf8)) ?? "{}"
    }

    func setSiteZoomMap(_ map: [String: Double]) { siteZoom = map; saveSetting("site_zoom", encodedMap(map)) }
    func setGroupColorMap(_ map: [String: String]) { groupColors = map.filter { !$0.value.isEmpty }; saveSetting("group_colors", encodedMap(groupColors)) }

    func setWorkspaceLayout(_ name: String, _ layout: LayoutSnapshot) {
        guard let index = workspaces.firstIndex(where: { $0.name == name }), workspaces[index].layout != layout else { return }
        workspaces[index].layout = layout
        saveWorkspaces()
    }

    func workspaceAccentMutate(_ index: Int, _ value: String?) {
        workspaces[index].accent = value
        saveWorkspaces()
    }

    func saveWorkspaces() {
        if let data = try? JSONEncoder().encode(workspaces), let json = String(data: data, encoding: .utf8) {
            saveSetting("workspaces", json)
        }
    }

    // MARK: Find in page

    func showFind() {
        guard active != nil else { return }
        expandChrome()
        #if os(iOS)
        active?.engine.presentNativeFind()
        #else
        findVisible = true
        #endif
    }

    func hideFind() {
        findVisible = false
        findText = ""
        findFailed = false
        active?.engine.clearFind()
    }

    func findNext(backwards: Bool = false) {
        guard let tab = active else { return }
        let text = findText
        Task {
            let found = await tab.engine.find(text, backwards: backwards)
            findFailed = !text.isEmpty && !found
        }
    }

    // MARK: Focus mode and split view

    func toggleFocusMode() {
        focusMode.toggle()
        if focusMode { overviewVisible = false }
    }

    var splitTab: TabController? { tabs.first { $0.id == splitTabID } }
    var thirdSplitTab: TabController? { splitTabID == nil ? nil : tabs.first { $0.id == thirdSplitTabID } }
    var fourthSplitTab: TabController? { thirdSplitTab == nil ? nil : tabs.first { $0.id == fourthSplitTabID } }

    /// The tabs showing in panels, in order, each once: the active tab, then the second, third and fourth panels.
    var splitPanels: [TabController] {
        guard let active else { return [] }
        var out = [active]
        for tab in [splitTab, thirdSplitTab, fourthSplitTab] { if let tab, !out.contains(where: { $0.id == tab.id }) { out.append(tab) } }
        return out
    }

    /// Shows `tab` next to the active tab. Each panel owns its own live view; a tab can only be in one place.
    func openSplit(with tab: TabController) {
        guard tab.id != activeID, tab.isPrivate == activeIsPrivate else {
            notice = tab.isPrivate != activeIsPrivate ? "Private and normal tabs can’t share a split view." : nil
            return
        }
        tab.ensureLoaded()
        splitTabID = tab.id
    }

    /// New tab in the other panel.
    func openSplitNewTab() {
        let current = activeID
        let tab = openTab(url: nil, isPrivate: activeIsPrivate, select: false)
        if let current { activeID = current }
        splitTabID = tab.id
    }

    /// Adds another panel to an open split: a third, then a fourth (two by two). A fifth replaces the fourth; four pages still leave each one wide enough to read.
    func addThirdPanel(with tab: TabController) {
        guard splitTabID != nil else { openSplit(with: tab); return }
        guard !splitPanels.contains(where: { $0.id == tab.id }), tab.isPrivate == activeIsPrivate else {
            notice = tab.isPrivate != activeIsPrivate ? "Private and normal tabs can’t share a split view." : nil
            return
        }
        tab.ensureLoaded()
        if thirdSplitTabID == nil { thirdSplitTabID = tab.id } else { fourthSplitTabID = tab.id }
    }

    func addThirdPanelNewTab() {
        guard splitTabID != nil else { openSplitNewTab(); return }
        let current = activeID
        let tab = openTab(url: nil, isPrivate: activeIsPrivate, select: false)
        if let current { activeID = current }
        if thirdSplitTabID == nil { thirdSplitTabID = tab.id } else { fourthSplitTabID = tab.id }
    }

    /// Takes away the last panel (the fourth, or else the third).
    func removeThirdPanel() { if fourthSplitTabID != nil { fourthSplitTabID = nil } else { thirdSplitTabID = nil } }

    func closeSplit() { splitTabID = nil }

    /// A tab that was in a panel is gone: the panels after it move up one place.
    func forgetSplitPanel(_ id: UInt64) {
        var rest = [splitTabID, thirdSplitTabID, fourthSplitTabID].compactMap { $0 }
        guard let index = rest.firstIndex(of: id) else { return }
        rest.remove(at: index)
        splitTabID = rest.first
        thirdSplitTabID = rest.count > 1 ? rest[1] : nil
        fourthSplitTabID = rest.count > 2 ? rest[2] : nil
    }

    /// Makes another panel the active one and puts the active tab in its place. With no argument, swaps with the second panel.
    func swapSplit(with other: UInt64? = nil) {
        guard let current = activeID, let target = other ?? splitTabID, target != current else { return }
        if target == fourthSplitTabID {
            fourthSplitTabID = current
            select(target)
            fourthSplitTabID = current
        } else if target == thirdSplitTabID {
            thirdSplitTabID = current
            select(target)
            thirdSplitTabID = current
        } else if target == splitTabID {
            splitTabID = current
            select(target)
            splitTabID = current
        }
    }

    // MARK: Tab groups

    func createGroup(_ name: String, moving tab: TabController? = nil) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, !groupNames.contains(clean) else { return }
        groupNames.append(clean)
        saveGroupNames()
        if let tab { moveTab(tab, to: clean) }
    }

    func renameGroup(_ old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, !groupNames.contains(clean),
              let i = groupNames.firstIndex(of: old) else { return }
        groupNames[i] = clean
        for tab in tabs where tab.group == old {
            tab.group = clean
            try? core.setTabGroup(tabId: tab.id, group: clean)
        }
        if activeGroup == old { activeGroup = clean }
        saveGroupNames()
        saveSoon()
    }

    /// Deleting a group keeps its tabs; they return to the ungrouped set.
    func deleteGroup(_ name: String) {
        for tab in tabs where tab.group == name {
            tab.group = ""
            try? core.setTabGroup(tabId: tab.id, group: "")
        }
        groupNames.removeAll { $0 == name }
        if activeGroup == name { selectGroup("") }
        saveGroupNames()
        saveSoon()
    }

    func moveTab(_ tab: TabController, to group: String) {
        tab.group = group
        try? core.setTabGroup(tabId: tab.id, group: group)
        if tab.id == activeID, group != activeGroup {
            activeGroup = group
        } else if group != activeGroup, tab.id != activeID {
            objectWillChange.send()
        }
        saveSoon()
    }

    func moveTab(_ tab: TabController, toWorkspace name: String) {
        tab.workspace = name
        tab.group = ""
        try? core.setTabWorkspace(tabId: tab.id, workspace: name)
        try? core.setTabGroup(tabId: tab.id, group: "")
        if tab.id == activeID {
            if let next = visibleTabs.first(where: { $0.id != tab.id }) ?? tabs.first(where: { $0.workspace == activeWorkspace && $0.id != tab.id }) {
                select(next.id)
            } else {
                newTab()
            }
        }
        objectWillChange.send()
        saveSoon()
    }

    func selectGroup(_ name: String) {
        activeGroup = name
        if let first = visibleTabs.first { select(first.id) } else { newTab() }
    }

    func tabCount(inGroup name: String) -> Int {
        tabs.filter { $0.workspace == activeWorkspace && $0.group == name && (!separatesPrivate || !$0.isPrivate) }.count
    }

    private func mergeGroupNamesFromTabs() {
        for name in Set(tabs.map(\.group)).subtracting([""]).sorted() where !groupNames.contains(name) {
            groupNames.append(name)
        }
    }

    private func saveGroupNames() {
        if let data = try? JSONSerialization.data(withJSONObject: groupNames),
           let json = String(data: data, encoding: .utf8) {
            saveSetting("tab_groups", json)
        }
    }

    // MARK: Overview

    func showOverview() {
        Task {
            await active?.captureSnapshot()
            overviewVisible = true
        }
    }

    func hideOverview() { overviewVisible = false }

    // MARK: Navigation

    func navigate(input: String) {
        if let hit = SearchShortcuts.resolve(input, custom: customSearchShortcuts), let url = URL(string: hit.url) {
            (active ?? openTab(url: nil, isPrivate: false)).load(url)
            return
        }
        guard let result = resolveInput(input: input, searchTemplate: searchTemplate) else { return }
        let target: String
        switch result {
        case .url(let u), .search(let u): target = u
        }
        guard let url = URL(string: target) else { return }
        (active ?? openTab(url: nil, isPrivate: false)).load(url)
    }

    func open(urlString: String, newTab: Bool = false) {
        guard let url = URL(string: urlString) else { return }
        if newTab || active == nil {
            openTab(url: url, isPrivate: active?.isPrivate ?? false)
        } else {
            active?.load(url)
        }
        sheet = nil
    }

    func accept(_ suggestion: Suggestion) {
        // A command name that is only being completed: the text is filled in and the bar stays open for the rest.
        if suggestion.kind == .command, suggestion.target.hasPrefix("slash:") {
            addressBar.text = String(suggestion.target.dropFirst(6))
            addressBar.refresh(model: self)
            return
        }
        addressBar.isEditing = false
        addressBar.clear()
        if suggestion.kind == .command {
            suggestion.action?()
        } else if suggestion.kind == .openTab, let id = suggestion.tabID {
            select(id)
        } else {
            open(urlString: suggestion.target)
        }
    }

    func confirmExternal(_ url: URL) {
        Task {
            let host = url.scheme ?? "another app"
            let choice = await Dialogs.choose(title: "Open in another app?",
                                              message: "This page wants to open a “\(host)” link.",
                                              buttons: ["Open", "Cancel"])
            if choice == 0 { openExternally(url) }
        }
    }

    // MARK: Core callbacks from tabs

    func tabURLChanged(_ tab: TabController) {
        if tab.id == activeID { refreshBookmarkState() }
        saveSoon()
    }

    func didFinishLoading(_ tab: TabController) {
        guard let url = tab.url else { return }
        // A scratch tab leaves no history and no saved address.
        if tabMeta[tab.id]?.scratch != true { try? core.commitNavigation(tabId: tab.id, url: url.absoluteString, title: tab.title) }
        if tab.id == activeID { refreshBookmarkState() }
        saveSoon()
        pageMemoryDidLoad(tab)
        watchDidLoad(tab)
        indexPageIfAllowed(tab)
    }

    // MARK: Bookmarks

    func refreshBookmarkState() {
        if spotlightBookmarks { scheduleSpotlightSync() }
        guard let url = active?.url?.absoluteString, active?.isBlank == false else {
            activeBookmarked = false
            return
        }
        activeBookmarked = (try? core.isBookmarked(url: url)) ?? false
    }

    private func scheduleSpotlightSync() {
        spotlightTask?.cancel()
        spotlightTask = Task { try? await Task.sleep(for: .seconds(2)); if !Task.isCancelled { syncSpotlight() } }
    }

    func toggleBookmark() {
        guard let tab = active, let url = tab.url?.absoluteString, !tab.isBlank else { return }
        if activeBookmarked {
            try? core.removeBookmark(url: url)
        } else {
            try? core.addBookmark(url: url, title: tab.displayTitle, folder: "")
        }
        refreshBookmarkState()
    }

    // MARK: Bookmark files

    /// All bookmarks as an HTML file other browsers can import.
    func bookmarksHTML() -> String {
        BookmarkHTML.export(((try? core.listBookmarks(query: "")) ?? []).map { BookmarkHTML.Entry(url: $0.url, title: $0.title, folder: $0.folder) })
    }

    /// Adds the web bookmarks in an exported HTML file. Ones already saved are skipped, so importing the same file twice adds nothing.
    @discardableResult
    func importBookmarks(html: String) -> (added: Int, skipped: Int) {
        let existing = Set(((try? core.listBookmarks(query: "")) ?? []).map(\.url))
        var seen = existing
        var added = 0, skipped = 0
        for entry in BookmarkHTML.parse(html).prefix(20_000) {
            guard !seen.contains(entry.url) else { skipped += 1; continue }
            if (try? core.addBookmark(url: entry.url, title: entry.title, folder: entry.folder)) != nil { seen.insert(entry.url); added += 1 } else { skipped += 1 }
        }
        refreshBookmarkState()
        return (added, skipped)
    }

    /// The same import in small batches that let the window breathe between them.
    func importBookmarks(entries: [BookmarkHTML.Entry]) async -> (added: Int, skipped: Int) {
        var seen = Set(((try? core.listBookmarks(query: "")) ?? []).map(\.url))
        var added = 0, skipped = 0
        for (index, entry) in entries.prefix(20_000).enumerated() {
            if index % 200 == 199 { await Task.yield() }
            guard !seen.contains(entry.url) else { skipped += 1; continue }
            if (try? core.addBookmark(url: entry.url, title: entry.title, folder: entry.folder)) != nil { seen.insert(entry.url); added += 1 } else { skipped += 1 }
        }
        refreshBookmarkState()
        return (added, skipped)
    }

    // MARK: Favorites and frequent sites

    static let favoritesFolder = "Favorites"

    var favorites: [BookmarkItem] {
        ((try? core.listBookmarks(query: "")) ?? []).filter { $0.folder == Self.favoritesFolder }
    }

    func frequentSites(limit: Int = 8) -> [HistoryItem] {
        guard !activeIsPrivate else { return [] }
        return Array(((try? core.topSites(limit: UInt32(limit + 6))) ?? []).prefix(limit))
    }

    func isFavorite(_ url: String) -> Bool {
        favorites.contains { $0.url == url }
    }

    /// Favorites in the order the person arranged them (the rest, in name order, after).
    var orderedFavorites: [BookmarkItem] {
        let order = Self.decodeList(((try? core.getSetting(key: "favorites_order")) ?? nil)) as [String]
        let all = favorites
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return all.enumerated().sorted { a, b in
            let ra = rank[a.element.url] ?? (order.count + a.offset), rb = rank[b.element.url] ?? (order.count + b.offset)
            return ra < rb
        }.map(\.element)
    }

    private func saveFavoritesOrder(_ urls: [String]) {
        saveSetting("favorites_order", (try? String(data: JSONEncoder().encode(urls), encoding: .utf8)) ?? "[]")
        objectWillChange.send()
    }

    func moveFavorite(_ url: String, before target: String) {
        var urls = orderedFavorites.map(\.url)
        guard url != target, let from = urls.firstIndex(of: url) else { return }
        urls.remove(at: from)
        urls.insert(url, at: urls.firstIndex(of: target) ?? urls.count)
        saveFavoritesOrder(urls)
    }

    func nudgeFavorite(_ url: String, by step: Int) {
        var urls = orderedFavorites.map(\.url)
        guard let from = urls.firstIndex(of: url) else { return }
        let to = max(0, min(urls.count - 1, from + step))
        urls.insert(urls.remove(at: from), at: to)
        saveFavoritesOrder(urls)
    }

    func removeFavorite(_ url: String) {
        guard isFavorite(url) else { return }
        try? core.addBookmark(url: url, title: favorites.first { $0.url == url }?.title ?? "", folder: "")
        refreshBookmarkState()
        objectWillChange.send()
    }

    /// A website typed in by hand: "example.com" becomes https://example.com.
    func addFavorite(address: String, name: String) {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.contains(".") == true else {
            notice = "That does not look like a website address."
            return
        }
        try? core.addBookmark(url: url.absoluteString, title: name.isEmpty ? (url.host ?? text) : name, folder: Self.favoritesFolder)
        refreshBookmarkState()
        objectWillChange.send()
    }

    /// The last real page worth going back to: another tab in this view that has a page in it, most recently used first. Never the blank tab on screen.
    var continueTab: TabController? {
        guard !activeIsPrivate else { return nil }
        return visibleTabs.filter { $0.id != activeID && !$0.isBlank && !$0.isPrivate && $0.url != nil }.max { $0.lastActive < $1.lastActive }
    }

    func toggleFavorite(url: String, title: String) {
        if isFavorite(url) {
            try? core.addBookmark(url: url, title: title, folder: "")
        } else {
            try? core.addBookmark(url: url, title: title, folder: Self.favoritesFolder)
        }
        refreshBookmarkState()
        objectWillChange.send()
    }

    // MARK: Permissions

    func resolvePermission(origin: String, kinds: [PermissionType], isPrivate: Bool) async -> Bool {
        let result = await decidePermission(origin: origin, kinds: kinds, isPrivate: isPrivate)
        // A record of what sites asked for and what was decided (never for private tabs). Only what the browser itself saw.
        if !isPrivate { logPermission(origin: origin, kinds: kinds.map { "\($0)".lowercased() }, allowed: result.allowed, how: result.how) }
        return result.allowed
    }

    private func decidePermission(origin: String, kinds: [PermissionType], isPrivate: Bool) async -> (allowed: Bool, how: String) {
        expireTemporaryPermissions()
        var needsPrompt: [PermissionType] = []
        for kind in kinds {
            guard let verdict = try? core.decidePermission(origin: origin, kind: kind, private: isPrivate) else {
                return (false, "error")
            }
            switch verdict.decision {
            case .deny: return (false, "saved")
            case .prompt: needsPrompt.append(kind)
            case .allow: break
            }
        }
        if needsPrompt.isEmpty { return (true, "saved") }
        let what = needsPrompt.map { "\($0)".lowercased() }.joined(separator: " and ")
        let buttons = isPrivate ? ["Allow", "Don’t Allow"] : ["Allow", "Allow for an Hour", "Allow for This Session", "Always Allow", "Don’t Allow"]
        let choice = await Dialogs.choose(title: "“\(origin)” wants to use your \(what)",
                                          message: "Only allow sites you trust.", buttons: buttons)
        let allowed = choice < buttons.count - 1
        // 1 = an hour, 2 = until the app next starts, 3 = always. The first two are saved like "always" but end on their own.
        if allowed && !isPrivate && choice >= 1 {
            for kind in needsPrompt { try? core.rememberPermission(origin: origin, kind: kind, decision: .allow) }
            if choice == 3 { notePermissionGranted(origin: origin, kinds: needsPrompt) }
            else { noteTemporaryPermission(origin: origin, kinds: needsPrompt, until: choice == 1 ? Date().timeIntervalSince1970 + 3600 : -1) }
        }
        return (allowed, allowed && !isPrivate ? (choice == 3 ? "always" : (choice == 1 ? "hour" : (choice == 2 ? "session" : "asked"))) : "asked")
    }

    private func logPermission(origin: String, kinds: [String], allowed: Bool, how: String) {
        var list = permissionLog
        list.insert(PermissionEvent(origin: origin, kinds: kinds, allowed: allowed, how: how), at: 0)
        permissionLog = Array(list.prefix(200))
        saveSetting("permission_log", (try? String(data: JSONEncoder().encode(permissionLog), encoding: .utf8)) ?? "[]")
    }

    func clearPermissionLog() {
        permissionLog = []
        saveSetting("permission_log", "[]")
    }

    // MARK: Configuration and settings

    func saveSetting(_ key: String, _ value: String) {
        guard !applyingSettings else { return }
        try? core.setSetting(key: key, value: value)
        windows.settingChanged(key, in: self)
    }

    /// Reads the profile's interface settings without writing them back.
    func loadUISettings() {
        applyingSettings = true
        defer { applyingSettings = false }
        func get(_ key: String) -> String? { (try? core.getSetting(key: key)) ?? nil }
        appearance = AppearanceMode(rawValue: get("appearance") ?? "") ?? .system
        tabLayout = TabLayout(rawValue: get("tab_layout") ?? "") ?? .separate
        layoutPreset = LayoutPreset(rawValue: get("layout_preset") ?? "") ?? .classic
        sidebarPosition = SidebarPosition(rawValue: get("sidebar_position") ?? "") ?? .left
        sidebarWidth = clampedSidebarWidth(Double(get("sidebar_width") ?? "") ?? 260)
        sidebarRail = get("sidebar_rail") == "1"
        sidebarAutoHide = get("sidebar_autohide") == "1"
        density = InterfaceDensity(rawValue: get("density") ?? "") ?? .comfortable
        singleToolbarCustom = get("single_toolbar") == "1"
        toolbarAutoHide = get("toolbar_autohide") == "1"
        tintToolbar = get("tint_toolbar") != "0"
        collapseOnScroll = get("collapse_on_scroll") != "0"
        doubleClickAction = DoubleClickAction(rawValue: get("double_click") ?? "") ?? .cycleLayout
        // Off until the person turns it on: what is typed is not sent to a search engine as it is typed unless they choose that.
        searchSuggestionsEnabled = get("search_suggestions") == "1"
        showSpeedPill = get("speed_pill") == "1"
        if let host = get("proxy_host"), !host.isEmpty, let port = Int(get("proxy_port") ?? "") {
            proxy = ProxyConfig(kind: ProxyConfig.Kind(rawValue: get("proxy_kind") ?? "") ?? .http, host: host, port: port, username: get("proxy_user") ?? "")
            if get("proxy_on") == "1" { setProxyEnabled(true); notice = nil }
        }
        pillCollapsed = get("pill_collapsed") == "1"
        fetchSiteIcons = get("site_icons") != "0"
        shortcuts = ShortcutMap(json: get("shortcuts"))
        homepage = get("homepage") ?? ""
        userScripts = ((get("user_scripts")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([UserScript].self, from: $0) }) ?? []
        engine.setUserScripts(effectiveUserScripts)
        lockSensitiveSettings = get("lock_sensitive") == "1"
        siteNotes = Self.decodeMap(get("site_notes"), as: String.self)
        siteStyles = Self.decodeMap(get("site_styles"), as: String.self)
        customSearchShortcuts = Self.decodeMap(get("search_shortcuts"), as: String.self)
        bookmarkTags = Self.decodeMap(get("bookmark_tags"), as: [String].self)
        readingList = ReadingStore.loadIndex(root: profileFolder)
        organizeDownloads = get("organize_downloads") == "1"
        maxDownloads = DownloadQueueRules.maxConcurrentChoices.contains(Int(get("download_concurrent") ?? "") ?? 0) ? Int(get("download_concurrent") ?? "")! : DownloadQueueRules.defaultConcurrent
        permissionLog = ((get("permission_log")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([PermissionEvent].self, from: $0) }) ?? []
        lockedTabIDs = Set(((get("locked_tabs")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([UInt64].self, from: $0) }) ?? [])
        savedSessions = ((get("saved_sessions")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([SavedSession].self, from: $0) }) ?? []
        phoneLayout = PhoneToolbarLayout(stored: get("phone_toolbar"))
        addressDisplay = AddressDisplay(rawValue: get("address_display") ?? "") ?? .domain
        showAddressIcon = get("address_icon") != "0"
        searchPanelAtBottom = get("search_panel_bottom2") != "0"
        swipeAddressPill = get("swipe_address") != "0"
        appLinkMode = get("app_links").flatMap(ExternalApps.Mode.init(rawValue:)) ?? .ask
        blurPrivateSwitcher = get("blur_private_switcher") != "0"
        syncSettingsToo = get("sync_settings") == "1"
        speedPopups = get("speed_popups") == "1"
        lastSyncedSettings = get("sync_settings_date").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
        lastSync = get("sync_last").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        remoteTabs = Self.decodeMap(get("sync_remote_tabs"), as: [RemoteTabs].self)["list"] ?? []
        tabMeta = Dictionary(uniqueKeysWithValues: Self.decodeMap(get("tab_meta"), as: TabMeta.self).compactMap { key, value in UInt64(key).map { ($0, value) } })
        containers = Self.decodeMap(get("containers"), as: [String].self)["list"] ?? []
        splitTemplates = Self.decodeMap(get("split_templates"), as: [SplitTemplate].self)["list"] ?? []
        tabTree = get("tab_tree") == "1"
        loadLoginSettings(get)
        spotlightBookmarks = get("spotlight_bookmarks") == "1"
        mouseGestures = get("mouse_gestures") == "1"
        mouseGestureMap = MouseGesture.decode(get("mouse_gesture_map"))
        syncPasswords = get("sync_passwords") == "1"
        syncLedger = Self.decodeMap(get("sync_ledger"), as: SyncState.self)["state"] ?? SyncState()
        syncClock = Self.decodeMap(get("sync_clock"), as: SyncClock.self)["clock"] ?? SyncClock()
        syncSeq = Int(get("sync_seq") ?? "") ?? 0
        syncSeen = Self.decodeMap(get("sync_seen"), as: Int.self)
        siteUserAgents = Self.decodeMap(get("site_user_agents"), as: String.self)
        siteDeleteRules = Self.decodeMap(get("site_delete_rules"), as: [SiteDeleteRule].self)["list"] ?? []
        tempPermissions = Self.decodeMap(get("temp_permissions"), as: Double.self)
        webRTCExceptions = Set(Self.decodeMap(get("webrtc_exceptions"), as: [String].self)["list"] ?? [])
        blockWebRTC = get("block_webrtc") == "1"
        loadPageDefenseSettings(get)
        rememberLayoutPerWorkspace = get("layout_per_workspace") != "0"
        syncGroupName = get("sync_group") ?? profileName
        syncDevices = Self.decodeMap(get("sync_devices"), as: [SyncDevice].self)["list"] ?? []
        syncHistory = Self.decodeMap(get("sync_history"), as: [String].self)["list"] ?? []
        syncAskOnConflict = get("sync_ask") == "1"
        loadSyncAdvanced(get)
        iCloudSync = get("sync_icloud") == "1"
        permissionDates = Self.decodeMap(get("permission_dates"), as: Double.self)
        permissionExpiry = get("permission_expiry").flatMap(PermissionExpiry.init(rawValue:)) ?? .month
        appLinkSites = Self.decodeMap(get("app_link_sites"), as: String.self)
        ExternalApps.sites = appLinkSites
        ExternalApps.remember = { [weak self] host, answer in self?.setAppLinkSite(host, to: answer) }
        overviewStyle = OverviewStyle(rawValue: get("overview_style") ?? "") ?? .grid
        settingsInTab = get("settings_in_tab") == "1"
        panelMode = PanelMode(rawValue: get("panel_mode") ?? "") ?? (get("panels_docked") == "0" ? .float : .dock)
        dockWidth = min(560, max(300, Double(get("dock_width") ?? "") ?? 380))
        loadExtraSettings(get)
        overviewGrouped = get("overview_grouped") == "1"
        overviewSort = OverviewSort(rawValue: get("overview_sort") ?? "") ?? .manual
        darkPages = DarkPages(rawValue: get("dark_pages") ?? "") ?? .off
        websiteAppearance = AppearanceMode(rawValue: get("website_appearance") ?? "") ?? .system
        loadThemeSettings()
        themeID = get("theme") ?? "midnight"
        applyTheme()
        siteAppearance = Self.decodeMap(get("site_appearance"), as: String.self)
        darkSites = Set(Self.decodeMap(get("dark_sites"), as: Bool.self).filter(\.value).keys)
        lowPowerSavesMemory = get("low_power_memory") != "0"
        clearOnQuit = ClearOnQuit(rawValue: get("clear_on_quit") ?? "") ?? .never
        // Off unless you turn it on: the page scrolling by itself a moment after it opens surprised people.
        rememberReadingPosition = get("remember_reading") == "1"
        keepFormDrafts = get("keep_form_drafts") == "1"
        readingPositions = Self.decodeMap(get("reading_positions"), as: ReadingPosition.self)
        formDrafts = Self.decodeMap(get("form_drafts"), as: FormDraft.self)
        pageSnapshots = Self.decodeMap(get("page_snapshots"), as: [PageSnapshot].self)
        watchedPages = Self.decodeMap(get("watched_pages"), as: PageWatch.self)
        comparedProducts = Self.decodeList(get("compared_products"))
        coupons = Self.decodeList(get("saved_coupons"))
        subscriptions = Self.decodeList(get("subscriptions"))
        pauseInfiniteScroll = get("pause_infinite") == "1"
        indexPages = get("index_pages") == "1"
        indexRetentionDays = Int(get("index_days") ?? "") ?? 90
        gestureBackForward = get("gesture_back") != "0"
        gesturePinchZoom = get("gesture_pinch") != "0"
        gesturePullRefresh = get("gesture_pull") != "0"
        startPageMemory()
        siteZoom = Self.decodeMap(get("site_zoom"), as: Double.self)
        groupColors = Self.decodeMap(get("group_colors"), as: String.self)
        stripTrackingParameters = get("strip_tracking") != "0"
        memoryMode = MemoryMode(rawValue: get("memory_mode") ?? "") ?? .balanced
        keepPinnedTabs = get("keep_pinned") != "0"
        threatList = ThreatListStore.load(root: root)
        sidebarVisible = !sidebarAutoHide && resolveLayout(preset: layoutPreset, customTabLayout: tabLayout, customSidebarVisible: false, customSingleToolbar: singleToolbarCustom).sidebarVisible
        // An explicit pin choice wins over what the layout would do, and over auto-hide.
        switch get("sidebar_pinned") {
        case "1": sidebarPinChoice = true; sidebarAutoHide = false; sidebarVisible = true
        case "0": sidebarPinChoice = false; sidebarAutoHide = true; sidebarVisible = false
        default: sidebarPinChoice = nil
        }
        addressBarPosition = AddressBarPosition(rawValue: get("address_bar") ?? "") ?? Self.defaultAddressBarPosition
        showFavorites = get("show_favorites") != "0"
        showContinue = get("show_continue") != "0"
        showFrequent = get("show_frequent") != "0"
        if let raw = get("toolbar_items") {
            var chosen = raw.split(separator: ",").compactMap { ToolbarItemID(rawValue: String($0)) }
            // The workspace and split-view buttons came later; a toolbar chosen before them gets them once, and can switch them off.
            #if os(macOS)
            if get("toolbar_items_version") == nil {
                for item in [ToolbarItemID.workspaces, .splitView] where !chosen.contains(item) { chosen.append(item) }
                try? core.setSetting(key: "toolbar_items_version", value: "2")
            }
            #endif
            toolbarItems = ToolbarItemID.allCases.filter { chosen.contains($0) }
        } else {
            toolbarItems = ToolbarItemID.defaults
        }
        if let json = get("tab_groups"), let data = json.data(using: .utf8),
           let names = try? JSONSerialization.jsonObject(with: data) as? [String] {
            groupNames = names
        } else {
            groupNames = []
        }
        accent = AccentChoice(rawValue: get("accent") ?? "") ?? .teal
        Theme.accent = accent.color
        startBackground = StartBackground(rawValue: get("start_background") ?? "") ?? .gradient
        showGreeting = get("show_greeting") != "0"
        showRecentlyClosed = get("show_recently_closed") != "0"
        tabPreviews = get("tab_previews") != "0"
        startup = ["blank", "homepage"].contains(get("startup") ?? "") ? (get("startup") ?? "restore") : "restore"
        splitOrientation = SplitOrientation(rawValue: get("split_orientation") ?? "") ?? .sideBySide
        if let json = get("workspaces"), let data = json.data(using: .utf8),
           let list = try? JSONDecoder().decode([Workspace].self, from: data) {
            workspaces = list
        } else {
            workspaces = []
        }
        let wanted = get("startup_workspace") ?? ""
        activeWorkspace = workspaces.contains { $0.name == wanted } ? wanted : ""
        applyWorkspaceTheme()
        activeGroup = ""
        closedTabs = []
        splitTabID = nil
        focusMode = false
    }

    /// Unpins the sidebar. It stays reachable by touching the window edge.
    func pinSidebar() {
        sidebarPinChoice = true
        saveSetting("sidebar_pinned", "1")
        sidebarAutoHide = false
        sidebarVisible = true
    }

    func hideSidebarToEdge() {
        sidebarPinChoice = false
        saveSetting("sidebar_pinned", "0")
        sidebarAutoHide = true
        sidebarVisible = false
    }

    /// The pin button: pinned means open and docked; otherwise the sidebar comes out at the window edge.
    func toggleSidebarPin() {
        if sidebarVisible && !sidebarAutoHide { hideSidebarToEdge() } else { sidebarRail = false; pinSidebar() }
    }

    var sidebarIsPinned: Bool { sidebarVisible && !sidebarRail }

    func shows(_ item: ToolbarItemID) -> Bool { toolbarItems.contains(item) }
    /// How many of the added toolbar buttons are switched on, so the bar can leave room for them.
    var toolbarExtrasCount: Int { [ToolbarItemID.workspaces, .profile, .splitView, .history, .library, .find, .palette].filter(shows).count }

    /// Saves a search address if it is valid (https, with `{}` exactly once). Returns whether it was saved.
    @discardableResult
    func setSearchTemplate(_ template: String) -> Bool {
        guard let valid = SearchEngines.validated(template) else { return false }
        try? core.setSetting(key: "search_template", value: valid)
        objectWillChange.send()
        return true
    }

    // MARK: Profiles

    func createProfile(_ name: String) -> Bool {
        guard (try? BrowserCore.open(root: root, profile: name)) != nil else { return false }
        profiles = listProfiles(root: root)
        return true
    }

    /// Explicit user action: moves the unreadable profile aside (never deletes it) and starts fresh.
    @discardableResult
    func resetUnreadableProfile() -> Bool {
        guard let recovery else { return false }
        let fm = FileManager.default
        let source = URL(fileURLWithPath: root).appendingPathComponent("profiles/\(recovery.profile)")
        let backups = URL(fileURLWithPath: root).appendingPathComponent("recovered", isDirectory: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = backups.appendingPathComponent("\(recovery.profile)-\(stamp)")
        do {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            if fm.fileExists(atPath: source.path) { try fm.moveItem(at: source, to: destination) }
            let fresh = try BrowserCore.open(root: root, profile: recovery.profile)
            tabs.forEach { $0.shutdown() }
            tabs.removeAll()
            activeID = nil
            core = fresh
            self.recovery = nil
            loadUISettings()
            privacy.load(from: fresh)
            Task { [self] in
                await privacy.apply()
                restoreOrOpenFirstTab()
            }
            notice = "Started a new profile. Your old data was kept in “recovered”."
            return true
        } catch {
            notice = "Could not reset the profile: \(error.localizedDescription)"
            return false
        }
    }

    func switchProfile(_ name: String) {
        guard name != profileName, let newCore = try? BrowserCore.open(root: root, profile: name) else { return }
        saveNow()
        tabs.forEach { $0.shutdown() }
        tabs.removeAll()
        activeID = nil
        engine.privateSessionEnded()
        core = newCore
        profileName = name
        if persistsProfileChoice { UserDefaults.standard.set(name, forKey: "profile") }
        loadUISettings()
        privacy.load(from: core)
        attachExtensions()
        Task { [self] in
            await privacy.apply()
            restoreOrOpenFirstTab()
        }
    }

    func removeProfile(_ name: String) async {
        guard name != profileName, name != "default" else { return }
        try? deleteProfile(root: root, name: name)
        SignInVault.removeAll(profile: name)
        await engine.removeProfileData(profile: name)
        profiles = listProfiles(root: root)
    }

    // MARK: Print, save, reader, backup

    func printActive() {
        guard let tab = active, !tab.isBlank else { return }
        tab.engine.printPage()
    }

    /// Saves the page and its images and styles as one file in Downloads, to open later without a connection.
    func savePageForLater() async {
        guard let tab = active, !tab.isBlank else { return }
        guard !tab.isPrivate else { notice = "Pages from private tabs are not saved to disk."; return }
        guard let data = await tab.engine.webArchive(), !data.isEmpty else { notice = "This page could not be saved."; return }
        let folder = DownloadCoordinator.directory.appendingPathComponent("Saved Pages", isDirectory: true)
        let cleaned = tab.displayTitle.replacingOccurrences(of: "[/\\:\\n\\r]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-")))
        let name = String(cleaned.prefix(80)).isEmpty ? "Saved page" : String(cleaned.prefix(80))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = DownloadCoordinator.uniqueURL(in: folder, name: name + ".webarchive")
            try data.write(to: target, options: .atomic)
            notice = "Saved to Downloads › Saved Pages › \(target.lastPathComponent)."
        } catch {
            notice = "This page could not be saved. \(error.localizedDescription)"
        }
    }

    /// Settings a backup carries. Anything else in a backup file is ignored on restore.
    static let backupSettingKeys: Set<String> = [
        "accent", "address_bar", "address_bar_items", "appearance", "density", "keep_pinned", "layout_preset", "memory_mode", "show_favorites", "show_continue",
        "show_frequent", "show_greeting", "show_recently_closed", "sidebar_autohide", "sidebar_position", "sidebar_rail",
        "sidebar_width", "single_toolbar", "split_orientation", "start_background", "startup", "startup_workspace",
        "strip_tracking", "tab_groups", "tab_layout", "tab_previews", "tint_toolbar", "toolbar_autohide", "toolbar_items",
        "workspaces", "double_click", "collapse_on_scroll", "search_template", "search_suggestions", "speed_pill", "pill_collapsed", "site_icons", "shortcuts", "homepage", "saved_sessions", "organize_downloads", "site_notes", "search_shortcuts", "bookmark_tags", "site_styles", "phone_toolbar", "address_display", "address_icon", "search_panel_bottom", "search_panel_bottom2", "swipe_address", "app_links", "app_link_sites", "blur_private_switcher", "permission_expiry", "favorites_order", "overview_style", "overview_grouped", "overview_sort", "dark_pages", "dark_sites", "website_appearance", "site_appearance", "theme", "theme_custom", "low_power_memory", "clear_on_quit", "remember_reading", "keep_form_drafts", "site_zoom", "group_colors",
        "save_logins", "mouse_gestures", "mouse_gesture_map", "site_open_rules", "download_concurrent", "spotlight_bookmarks", "vim_on", "vim_keymap", "workflows", "download_rules", "extension_profiles", "site_delete_rules", "site_user_agents", "containers", "split_templates", "tab_tree", "block_webrtc", "webrtc_exceptions",
        "site_js_off", "never_sleep_sites", "fingerprint_noise", "fingerprint_exceptions", "de_amp", "video_ads", "user_themes", "start_tile", "block_autoplay", "autoplay_exceptions",
        "block_popups", "popup_allowed_hosts", "youtube_rules_auto", "command_chains", "web_panels", "theme_schedule", "hidden_menu_items", "hover_previews", "hover_delay", "tab_stacks", "address_sources", "tab_tree", "sidebar_footer",
    ]

    /// The same, with the slow key derivation and encryption on a background thread so the window never stalls.
    func makeBackupAsync(passphrase: String, includePasswords: Bool = false) async throws -> Data {
        let payload = backupPayload(includePasswords: includePasswords)
        return try await Task.detached(priority: .userInitiated) { try BackupFile.seal(payload, passphrase: passphrase) }.value
    }

    /// Opens the backup off the main thread (the key derivation is slow on purpose), then applies it here.
    @discardableResult
    func restoreBackupAsync(_ data: Data, passphrase: String) async throws -> (bookmarks: Int, settings: Int) {
        let payload = try await Task.detached(priority: .userInitiated) { try BackupFile.open(data, passphrase: passphrase) }.value
        return applyBackup(payload)
    }

    func makeBackup(passphrase: String, iterations: UInt32 = BackupFile.defaultIterations) throws -> Data {
        try BackupFile.seal(backupPayload(), passphrase: passphrase, iterations: iterations)
    }

    private func backupPayload(includePasswords: Bool = false) -> BackupPayload {
        let bookmarks = ((try? core.listBookmarks(query: "")) ?? []).map { BackupPayload.Bookmark(url: $0.url, title: $0.title, folder: $0.folder) }
        var settings: [String: String] = [:]
        for key in Self.backupSettingKeys.sorted() {
            if let value = (try? core.getSetting(key: key)) ?? nil { settings[key] = value }
        }
        var payload = BackupPayload(created: Date(), bookmarks: bookmarks, settings: settings)
        payload.research = research.collections.isEmpty ? nil : research.collections
        if includePasswords { payload.passwords = WebLoginVault.list(profile: profileName) }
        return payload
    }

    /// Adds the backup's bookmarks (existing ones are kept) and applies its settings.
    @discardableResult
    func restoreBackup(_ data: Data, passphrase: String) throws -> (bookmarks: Int, settings: Int) {
        return applyBackup(try BackupFile.open(data, passphrase: passphrase))
    }

    private func applyBackup(_ payload: BackupPayload) -> (bookmarks: Int, settings: Int) {
        var added = 0
        for bookmark in payload.bookmarks where ["http", "https"].contains(URL(string: bookmark.url)?.scheme?.lowercased() ?? "") {
            if (try? core.addBookmark(url: bookmark.url, title: bookmark.title, folder: bookmark.folder)) != nil { added += 1 }
        }
        var applied = 0
        for (key, value) in payload.settings where Self.backupSettingKeys.contains(key) {
            if (try? core.setSetting(key: key, value: value)) != nil { applied += 1 }
        }
        if let collections = payload.research { research.merge(collections) }
        lastRestoredPasswords = payload.passwords.map { restorePasswords($0) } ?? 0
        loadUISettings()
        refreshBookmarkState()
        return (added, applied)
    }

    // MARK: Link cleaning, threat list, website data

    /// The link without tracking parameters, or nil. Stops cleaning if a site keeps adding them back, so a
    /// redirect that re-adds a parameter can never loop.
    func cleanedLink(_ url: URL) -> URL? {
        guard stripTrackingParameters else { return nil }
        let now = Date()
        recentStrips.removeAll { now.timeIntervalSince($0) > 5 }
        guard recentStrips.count < 3, let cleaned = TrackingParameters.clean(url) else { return nil }
        recentStrips.append(now)
        strippedLinkCount += 1
        return cleaned
    }

    func shouldWarnAboutThreat(host: String) -> Bool {
        !threatList.isEmpty && !sessionAllowedHosts.contains(host.lowercased()) && threatList.contains(host: host)
    }

    func presentThreatWarning(for url: URL, in tab: TabController) {
        guard let host = url.host?.lowercased() else { return }
        Task { @MainActor [self] in
            let choice = await Dialogs.choose(
                title: "Deceptive website blocked",
                message: "“\(host)” is on the threat list you imported. It may try to steal passwords or install harmful software.",
                buttons: ["Go Back", "Continue Anyway"])
            if choice == 1 {
                sessionAllowedHosts.insert(host)
                tab.load(url)
            }
        }
    }

    func importThreatList(from file: URL) {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: file)
            threatList = try ThreatListStore.save(data, root: root)
            sessionAllowedHosts = []
            notice = "Loaded \(threatList.count) hosts into your threat list."
        } catch {
            notice = "Could not load that list. \(error.localizedDescription)"
        }
    }

    func clearThreatList() {
        ThreatListStore.remove(root: root)
        threatList = .empty
        sessionAllowedHosts = []
    }

    func siteData() async -> [SiteDataInfo] { await engine.siteData(profile: profileName) }
    func removeSiteData(host: String) async { await engine.removeSiteData(host: host, profile: profileName) }

    func clearBrowsingData() async {
        guard recovery == nil else { return }
        try? core.clearHistory()
        eraseSearchableCopy()
        try? core.clearDownloads()
        FaviconStore.shared.clear()
        await engine.clearData(profile: profileName)
        notice = "Browsing data cleared."
    }
}


// MARK: - Command palette

struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let run: @MainActor () -> Void
}

extension BrowserModel {
    /// Every palette entry reuses an existing model command; there is no separate logic here.
    func allPaletteItems(query: String = "", full: Bool = false) -> [PaletteItem] {
        var all: [PaletteItem] = [
            .init(id: "new-tab", title: "New Tab", subtitle: "", symbol: "plus", shortcut: "⌘T") { [self] in newTab() },
            .init(id: "new-private", title: "New Private Tab", subtitle: "", symbol: "eye.slash", shortcut: "⇧⌘N") { [self] in openTab(url: nil, isPrivate: true) },
            .init(id: "reopen", title: "Reopen Closed Tab", subtitle: closedTabs.last?.title ?? "", symbol: "arrow.uturn.backward", shortcut: "⇧⌘T") { [self] in reopenClosedTab() },
            .init(id: "sidebar", title: "Toggle Sidebar", subtitle: "", symbol: "sidebar.left", shortcut: "⇧⌘L") { [self] in sidebarVisible.toggle() },
            .init(id: "overview", title: "Show Tab Overview", subtitle: "", symbol: "square.on.square", shortcut: "⇧⌘\\") { [self] in showOverview() },
            .init(id: "bookmark", title: "Bookmark This Page", subtitle: "", symbol: "star", shortcut: "⌘D") { [self] in toggleBookmark() },
            .init(id: "bookmarks", title: "Open Bookmarks", subtitle: "", symbol: "book", shortcut: "⇧⌘B") { [self] in sheet = .bookmarks },
            .init(id: "history", title: "Open History", subtitle: "", symbol: "clock", shortcut: "⌘Y") { [self] in sheet = .history },
            .init(id: "downloads", title: "Open Downloads", subtitle: "", symbol: "arrow.down.circle", shortcut: "⇧⌘J") { [self] in sheet = .downloads },
            .init(id: "settings", title: "Open Settings", subtitle: "", symbol: "gearshape", shortcut: "⌘,") {
                #if os(macOS)
                SettingsRouter.open()
                #else
                self.sheet = .settings
                #endif
            },
            .init(id: "workbench", title: "Workbench: Search Everything, Automate, Developer Tools, Health", subtitle: "", symbol: "wrench.and.screwdriver", shortcut: "") { [self] in sheet = .workbench },
            .init(id: "capture-view", title: "Save a Picture of This Page", subtitle: "What is on screen, to Downloads", symbol: "camera.viewfinder", shortcut: "") { [self] in Task { await workbench.capturePage(fullPage: false) } },
            .init(id: "capture-full", title: "Save a Picture of the Whole Page", subtitle: "Top to bottom, to Downloads", symbol: "camera", shortcut: "") { [self] in Task { await workbench.capturePage(fullPage: true) } },
            .init(id: "save-archive", title: "Save This Page as a Web Archive", subtitle: "One file with the page and its pictures, to Downloads", symbol: "archivebox", shortcut: "") { [self] in Task { await workbench.exportWebArchive() } },
            .init(id: "fill-login", title: "Fill Saved Sign-in", subtitle: "Asks for Touch ID first", symbol: "key.viewfinder", shortcut: "") { [self] in if let tab = active { offerToFillLogin(in: tab, force: true) } },
            .init(id: "search-selection-default", title: "Search the Selected Words", subtitle: "With your search engine, in a new tab", symbol: "magnifyingglass", shortcut: "") { [self] in
                searchSelection(with: SelectionSearch.Engine(name: "default", template: searchTemplate))
            },
            .init(id: "edit-pdf", title: "Edit or Sign This PDF", subtitle: "Mark up, fill in, sign, redact, reorder pages; saved as a copy", symbol: "pencil.and.signature", shortcut: "") { [self] in editCurrentPDF() },
            .init(id: "open-document", title: "Open a Document…", subtitle: "A PDF to edit, or Word, Excel, Pages and more to preview", symbol: "doc.badge.plus", shortcut: "") { [self] in sheet = .workbench; workbench.openDocumentRequested = true },
            .init(id: "pick-element", title: "Pick an Element on This Page", subtitle: "Its selector, size, styles and HTML", symbol: "scope", shortcut: "") { [self] in Task { await workbench.pickElement() } },
            .init(id: "size-hud", title: workbench.showSizeHUD ? "Hide the Page Size" : "Show the Page Size", subtitle: "Live width and height in the corner", symbol: "ruler", shortcut: "") { [self] in workbench.showSizeHUD.toggle() },
            .init(id: "vim-mode", title: workbench.vimEnabled ? "Turn Off Vim Keys" : "Turn On Vim Keys", subtitle: "j k gg G H L and more, when no text field has the keyboard", symbol: "keyboard", shortcut: "") { [self] in workbench.vimEnabled.toggle() },
            .init(id: "site-privacy", title: "Site Privacy: What This Site Stores, Safety Check, Forget", subtitle: "", symbol: "lock.shield", shortcut: "") { [self] in sheet = .sitePrivacy },
            .init(id: "forget-site", title: "Forget This Site Completely", subtitle: "Data, history, permissions, sign-ins", symbol: "trash.slash", shortcut: "") { [self] in Task { await forgetActiveSiteCompletely() } },
            .init(id: "sync-now", title: "Sync Now", subtitle: syncHealth.title, symbol: "arrow.triangle.2.circlepath.icloud", shortcut: "") { [self] in Task { await syncNowCloud() } },
            .init(id: "never-sleep", title: neverSleeps(host: active?.url?.host) ? "Allow This Site to Sleep" : "Never Put This Site to Sleep", subtitle: "Its tabs stay loaded when memory is short", symbol: "moon.zzz", shortcut: "") { [self] in setNeverSleeps(host: active?.url?.host, !neverSleeps(host: active?.url?.host)) },
            .init(id: "site-js", title: scriptsAllowed(forHost: active?.url?.host) ? "Turn JavaScript Off for This Site" : "Turn JavaScript On for This Site", subtitle: "The page reloads", symbol: "curlybraces", shortcut: "") { [self] in setScripts(host: active?.url?.host, allowed: !scriptsAllowed(forHost: active?.url?.host)) },
            .init(id: "webrtc", title: blockWebRTC ? "Allow WebRTC" : "Switch WebRTC Off", subtitle: "Pages cannot learn this device's network address", symbol: "network.slash", shortcut: "") { [self] in blockWebRTC.toggle() },
            .init(id: "research", title: "Research Collections", subtitle: "Pages, highlights, notes and citations", symbol: "books.vertical.fill", shortcut: "") { [self] in sheet = .research },
            .init(id: "research-add-page", title: "Add This Page to Research", subtitle: "", symbol: "plus.rectangle.on.folder", shortcut: "") { [self] in Task { await addPageToResearch() } },
            .init(id: "research-offline", title: "Save an Offline Copy to Research", subtitle: "The page as a PDF that opens without a connection", symbol: "arrow.down.doc", shortcut: "") { [self] in Task { await saveOfflineCopyToResearch() } },
            .init(id: "research-note", title: "Add a Note on the Selected Words", subtitle: "Saved with the passage; takes you back to it", symbol: "text.bubble", shortcut: "") { [self] in
                Task { @MainActor in if let text = await Dialogs.promptText(title: "Note on the Selection", message: "Select the words on the page first, then write your note.", placeholder: "") { await addAnchoredNote(text) } }
            },
            .init(id: "research-add-selection", title: "Add Selection to Research", subtitle: "A highlight with its citation", symbol: "highlighter", shortcut: "") { [self] in Task { await addSelectionToResearch() } },
            .init(id: "copy-citation", title: "Copy Citation for This Page", subtitle: "", symbol: "quote.opening", shortcut: "") { [self] in Task { await copyCitationForActivePage() } },
            .init(id: "restore-layout", title: "Restore Standard Layout", subtitle: "The way back from any layout", symbol: "arrow.counterclockwise", shortcut: "⌥⇧⌘0") { [self] in restoreStandardLayout() },
            .init(id: "layout-diagnostics", title: "Layout Diagnostics", subtitle: "What the window is showing, and why", symbol: "square.dashed.inset.filled", shortcut: "") { [self] in sheet = .layout },
            .init(id: "layout-research", title: "Window Layout: Research", subtitle: WindowPreset.research.summary, symbol: "sidebar.left", shortcut: "") { [self] in applyWindowPreset(.research) },
            .init(id: "layout-writing", title: "Window Layout: Writing", subtitle: WindowPreset.writing.summary, symbol: "pencil.and.outline", shortcut: "") { [self] in applyWindowPreset(.writing) },
            .init(id: "layout-media", title: "Window Layout: Media", subtitle: WindowPreset.media.summary, symbol: "play.rectangle", shortcut: "") { [self] in applyWindowPreset(.media) },
            .init(id: "layout-minimal", title: "Window Layout: Minimal", subtitle: WindowPreset.minimal.summary, symbol: "minus.rectangle", shortcut: "") { [self] in applyWindowPreset(.minimal) },
            .init(id: "group-by-site", title: "Group Tabs by Website", subtitle: "One group per site that has two or more tabs", symbol: "rectangle.3.group", shortcut: "") { [self] in groupTabsByWebsite() },
            .init(id: "sleep-others", title: "Put All Other Tabs to Sleep", subtitle: "Keeps this tab, pinned and locked tabs", symbol: "moon.zzz", shortcut: "") { [self] in Task { await suspendAll() } },
            .init(id: "scratch-tab", title: "New Scratch Tab", subtitle: "No history, nothing saved, gone when closed", symbol: "sparkles", shortcut: "") { [self] in openScratchTab() },
            .init(id: "tab-tree", title: tabTree ? "Turn Off Tab Tree" : "Turn On Tab Tree", subtitle: "Show tabs under the tab they were opened from", symbol: "list.bullet.indent", shortcut: "") { [self] in tabTree.toggle() },
            .init(id: "save-split", title: "Save This Split Layout…", subtitle: "", symbol: "rectangle.split.2x1", shortcut: "") { [self] in
                Task { @MainActor in if let name = await Dialogs.promptText(title: "Save Split Layout", message: "Name this pair of pages.", placeholder: "") { saveSplitTemplate(named: name) } }
            },
            .init(id: "group", title: "New Tab Group…", subtitle: "", symbol: "folder.badge.plus", shortcut: "") { [self] in promptNewGroup(model: self) },
            .init(id: "reading-list", title: "Reading List", subtitle: "Articles saved to read offline", symbol: "books.vertical", shortcut: "") { [self] in sheet = .readingList },
            .init(id: "add-reading", title: "Add to Reading List", subtitle: "", symbol: "text.badge.plus", shortcut: "") { [self] in Task { await addToReadingList() } },
            .init(id: "highlight", title: "Highlight Selection", subtitle: "In a saved article", symbol: "highlighter", shortcut: "") { [self] in Task { await highlightSelection() } },
            .init(id: "page-note", title: "Note for This Page", subtitle: "", symbol: "note.text", shortcut: "") { [self] in sheet = .note },
            .init(id: "restore-text", title: "Restore Typed Text", subtitle: "", symbol: "text.badge.checkmark", shortcut: "") { [self] in Task { await restoreTypedText() } },
            .init(id: "smart-selection", title: "Selection Actions: Search, Define, Convert, Remind", subtitle: "", symbol: "text.cursor", shortcut: "") { [self] in sheet = .selection },
            .init(id: "share-tabs", title: "Share Tabs or Video Time", subtitle: "", symbol: "rectangle.on.rectangle", shortcut: "") { [self] in sheet = .shareTabs },
            .init(id: "watch-page", title: "Watch This Page for Changes", subtitle: "", symbol: "eye", shortcut: "") { [self] in Task { await toggleWatch() } },
            .init(id: "shopping", title: "Compare Prices, Coupons, Subscriptions", subtitle: "", symbol: "cart", shortcut: "") { [self] in sheet = .shopping },
            .init(id: "repair", title: "Repair This Page", subtitle: "", symbol: "wrench.and.screwdriver", shortcut: "") { [self] in sheet = .repair },
            .init(id: "devices", title: "Send to Another Device", subtitle: "", symbol: "laptopcomputer.and.iphone", shortcut: "") { [self] in sheet = .devices },
            .init(id: "search-pages", title: "Search My Pages", subtitle: "", symbol: "doc.text.magnifyingglass", shortcut: "") { [self] in sheet = .pageSearch },
            .init(id: "sync", title: "Sync: iCloud and Wi-Fi", subtitle: "Bookmarks and tabs across your devices", symbol: "arrow.triangle.2.circlepath", shortcut: "") {
                #if os(macOS)
                SettingsRouter.open(.general)
                #else
                self.sheet = .settings
                #endif
            },
            .init(id: "site-light", title: "Website Appearance: Light for This Site", subtitle: "", symbol: "sun.max", shortcut: "") { [self] in setSiteAppearance(active?.url?.host, .light) },
            .init(id: "site-dark", title: "Website Appearance: Dark for This Site", subtitle: "", symbol: "moon", shortcut: "") { [self] in setSiteAppearance(active?.url?.host, .dark) },
            .init(id: "site-reset", title: "Reset Appearance for This Site", subtitle: "Back to how the site normally looks", symbol: "arrow.uturn.backward", shortcut: "") { [self] in resetSiteAppearance(active?.url?.host) },
            .init(id: "resources", title: "Resource Dashboard: Memory and Sleeping Tabs", subtitle: "", symbol: "gauge.with.dots.needle.50percent", shortcut: "") { [self] in sheet = .resources },
            .init(id: "page-tools", title: "Page Tools: Images, Tables, Documents, Listen", subtitle: "", symbol: "wand.and.sparkles", shortcut: "") { [self] in sheet = .pageTools },
            .init(id: "qr", title: "QR Code for This Page", subtitle: "", symbol: "qrcode", shortcut: "") { [self] in sheet = .qr },
            .init(id: "copy-clean", title: "Copy Clean Link", subtitle: "Without tracking parameters", symbol: "link.badge.plus", shortcut: "") { [self] in copyCleanLink() },
            .init(id: "translate", title: "Translate Page", subtitle: "On this device", symbol: "character.bubble", shortcut: "") { [self] in Task { await translateOnDevice() } },
            .init(id: "save-pdf", title: "Save Page as PDF", subtitle: "", symbol: "doc.richtext", shortcut: "") { [self] in Task { await savePageAsPDF() } },
            .init(id: "screenshot", title: "Take Screenshot", subtitle: "", symbol: "camera.viewfinder", shortcut: "") { [self] in Task { await takeScreenshot(fullPage: false) } },
            .init(id: "screenshot-full", title: "Take Full-Page Screenshot", subtitle: "", symbol: "rectangle.expand.vertical", shortcut: "") { [self] in Task { await takeScreenshot(fullPage: true) } },
            .init(id: "reader", title: "Reader", subtitle: "", symbol: "doc.plaintext", shortcut: "⇧⌘R") { [self] in Task { await active?.toggleReader() } },
            .init(id: "dashboard", title: "Privacy Dashboard", subtitle: "What protects you, and what connects out", symbol: "hand.raised", shortcut: "") { [self] in sheet = .dashboard },
            .init(id: "sessions", title: "Saved Sessions", subtitle: "Save or reopen sets of tabs", symbol: "tray.full", shortcut: "") { [self] in sheet = .sessions },
            .init(id: "timeline", title: "Tab Activity", subtitle: "Which tabs you used, and when", symbol: "clock.arrow.circlepath", shortcut: "") { [self] in sheet = .timeline },
            .init(id: "close-duplicates", title: "Close Duplicate Tabs", subtitle: "", symbol: "square.on.square.dashed", shortcut: "") { [self] in closeDuplicateTabs() },
        ]
        for device in sendTargets where active?.isBlank == false && active?.isPrivate == false {
            all.append(.init(id: "send-\(device.id)", title: "Send This Tab to \(device.name)", subtitle: "", symbol: "paperplane", shortcut: "") { [self] in if let tab = active { sendTab(tab, to: device) } })
        }
        all.append(.init(id: "find", title: "Find in Page", subtitle: "", symbol: "magnifyingglass", shortcut: "⌘F") { [self] in showFind() })
        all.append(.init(id: "focus", title: focusMode ? "Exit Focus Mode" : "Enter Focus Mode", subtitle: "", symbol: "rectangle.compress.vertical", shortcut: "⌥⌘F") { [self] in toggleFocusMode() })
        all.append(.init(id: "split-new", title: "Split View: New Tab on the Side", subtitle: "", symbol: "rectangle.split.2x1", shortcut: "") { [self] in openSplitNewTab() })
        if splitTabID != nil {
            all.append(.init(id: "split-close", title: "Close Split View", subtitle: "", symbol: "rectangle", shortcut: "") { [self] in closeSplit() })
            if fourthSplitTabID == nil { all.append(.init(id: "split-third", title: "Split View: Add a Panel", subtitle: "A new tab, up to four in a grid", symbol: "rectangle.split.3x1", shortcut: "") { [self] in addThirdPanelNewTab() }) }
            if thirdSplitTabID != nil { all.append(.init(id: "split-third-close", title: "Split View: Remove the Last Panel", subtitle: "", symbol: "rectangle.split.2x1", shortcut: "") { [self] in removeThirdPanel() }) }
            all.append(.init(id: "split-swap", title: "Swap Split Panels", subtitle: "", symbol: "arrow.left.arrow.right", shortcut: "") { [self] in swapSplit() })
        }
        for ws in workspaces where ws.name != activeWorkspace {
            all.append(.init(id: "ws-\(ws.name)", title: "Switch Workspace: \(ws.name)", subtitle: "", symbol: ws.icon, shortcut: "") { [self] in switchWorkspace(ws.name) })
        }
        if !activeWorkspace.isEmpty {
            all.append(.init(id: "ws-default", title: "Switch Workspace: Personal", subtitle: "", symbol: "person", shortcut: "") { [self] in switchWorkspace("") })
        }
        for preset in LayoutPreset.allCases {
            all.append(.init(id: "layout-\(preset.rawValue)", title: "Layout: \(preset.title)", subtitle: preset.summary,
                             symbol: "rectangle.split.3x1", shortcut: "") { [self] in layoutPreset = preset })
        }
        for name in profiles where name != profileName {
            all.append(.init(id: "profile-\(name)", title: "Switch Profile: \(name)", subtitle: "", symbol: "person.crop.circle", shortcut: "") { [self] in switchProfile(name) })
        }
        for tab in tabs where tab.id != activeID && !tab.isBlank {
            all.append(.init(id: "tab-\(tab.id)", title: tab.displayTitle, subtitle: displayHost(tab.url), symbol: "square.on.square", shortcut: "") { [self] in select(tab.id) })
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return full ? all : Array(all.prefix(12)) }
        for b in ((try? core.listBookmarks(query: query)) ?? []).prefix(5) {
            all.append(.init(id: "bm-\(b.url)", title: b.title.isEmpty ? b.url : b.title, subtitle: b.url, symbol: "star.fill", shortcut: "") { [self] in open(urlString: b.url) })
        }
        if !activeIsPrivate {
            for h in ((try? core.searchHistory(query: query, limit: 4)) ?? []) {
                all.append(.init(id: "hist-\(h.url)", title: h.title.isEmpty ? h.url : h.title, subtitle: h.url, symbol: "clock", shortcut: "") { [self] in open(urlString: h.url) })
            }
        }
        for article in readingList.filter({ $0.title.localizedCaseInsensitiveContains(query) }).prefix(3) {
            all.append(.init(id: "read-\(article.id)", title: article.title, subtitle: "Reading list · " + article.site, symbol: "books.vertical", shortcut: "") { [self] in openReadingItem(article) })
        }
        #if os(macOS)
        for preset in ViewportPreset.all {
            all.append(.init(id: "window-size-\(preset.id)", title: "Window Size: \(preset.title) (\(preset.summary))", subtitle: "Resize this window to look at the page at that size", symbol: "macwindow", shortcut: "") { [self] in resizeWindow(to: preset) })
        }
        #endif
        for engine in SelectionSearch.engines(custom: customSearchShortcuts) {
            all.append(.init(id: "search-selection-\(engine.id)", title: "Search Selected Words with \(engine.name)", subtitle: "In a new tab", symbol: "text.magnifyingglass", shortcut: "") { [self] in searchSelection(with: engine) })
        }
        #if os(macOS)
        all.append(contentsOf: extraPaletteItems)
        for panel in SettingsPanel.allCases {
            all.append(.init(id: "settings-\(panel.rawValue)", title: "Settings: \(panel.title)", subtitle: "", symbol: panel.symbol, shortcut: "") { SettingsRouter.open(panel) })
        }
        #endif
        return all
    }

    func paletteItems(query: String) -> [PaletteItem] {
        let all = allPaletteItems(query: query)
        return all.compactMap { item -> (Int, PaletteItem)? in
            guard let score = fuzzyScore(query: query, in: item.title) ?? fuzzyScore(query: query, in: item.subtitle).map({ $0 - 20 }) else { return nil }
            return (score, item)
        }
        .sorted { $0.0 > $1.0 }
        .prefix(12)
        .map(\.1)
    }
}


// MARK: - What web extensions see of the browser

extension BrowserModel: ExtensionHost {
    /// Private tabs are never shown to extensions.
    var extensionTabs: [TabController] { tabs.filter { !$0.isPrivate } }
    var extensionActiveTab: TabController? { active.flatMap { $0.isPrivate ? nil : $0 } }
    func extensionOpenTab(url: URL?) -> TabController { openTab(url: url, isPrivate: false) }
    func extensionClose(_ tab: TabController) { closeTab(id: tab.id) }
    func extensionSelect(_ tab: TabController) { select(tab.id) }

    func extensionAsk(title: String, message: String, allow: String) async -> Bool {
        await Dialogs.choose(title: title, message: message, buttons: [allow, "Don’t Allow"]) == 0
    }
}
