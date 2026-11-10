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
    case saveToResearch, screenshot, picturesToPDF, tools, webApps, bookmarks, history, downloads, bookmarkTools, compare, timeMachine, toolkit, digest, pdfEditor, summary, settings, layout, research, sitePrivacy, workbench, findAll, sessions, timeline, dashboard, readingList, note, qr, style, pageTools, selection, shareTabs, shopping, repair, devices, pageSearch, resources
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
    @Published var tabs: [TabController] = [] {
        didSet {
            // A private collection belongs to its private session: when the last private tab is gone, so is the collection.
            if linkStoreCache != nil, !tabs.contains(where: { $0.leavesNoTrace }) { linkStoreCache?.privateStore.clear() }
            if mediaStoreCache != nil, !tabs.contains(where: { $0.leavesNoTrace }) { mediaStoreCache?.privateStore.clear() }
        }
    }
    @Published var activeID: UInt64?
    @Published private(set) var profileName: String
    @Published private(set) var profiles: [String] = []
    @Published var profileStyles: [String: ProfileStyle] = ProfileRegistry.styles()
    @Published var siteProfiles: [String: String] = ProfileRegistry.sites()
    var sitePromptDeclined = Set<String>()
    var pendingProfileURL: URL?
    @Published var downloadsByProfile = ProfileRegistry.downloadsByProfile() { didSet { ProfileRegistry.saveDownloadsByProfile(downloadsByProfile); updateDownloadFolder() } }
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
                #if os(macOS)
                // The Mac's Downloads is a table and needs width, so it opens as the card even when the other panels are docked.
                case .dock where opened == .downloads: floatingPanel = (floatingPanel == opened) ? nil : opened
                #endif
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
    // Reading the saved choice while a model starts must not touch the system's index when the choice is "off": a second window, a test, or a profile that never
    // used it would otherwise delete the Spotlight entries that another profile or window put there. Turning it off by hand still removes them.
    @Published var spotlightBookmarks = false { didSet { saveSetting("spotlight_bookmarks", spotlightBookmarks ? "1" : "0"); if !applyingSettings || spotlightBookmarks { syncSpotlight() } } }
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
    @Published var notice: String? {
        // A different message (or none) ends the offer that went with the earlier one.
        didSet { if notice != oldValue { noticeUndo = nil } }
    }
    /// An action offered beside the message in front (an Undo). Set right after `notice`; gone when the message changes or leaves.
    @Published var noticeUndo: NoticeAction?
    /// Clear Tabs: whether tabs that are asleep are closed too, and whether a large clear asks first.
    @Published var clearIncludesSleeping = true { didSet { saveSetting("clear_includes_sleeping", clearIncludesSleeping ? "1" : "0") } }
    @Published var clearTabsAsks = true { didSet { saveSetting("clear_tabs_asks", clearTabsAsks ? "1" : "0") } }
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
    @Published var sidebarVisible = false {
        didSet { if layoutPreset == .custom && !applyingSettings { saveSetting("custom_sidebar", sidebarVisible ? "1" : "0") } }
    }
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
    /// Pages waiting to open: snoozed tabs and schedules.
    @Published var tabSchedules: [TabSchedule] = []
    /// What has played in tabs, newest first. Private tabs are never recorded.
    @Published var mediaHistory: [MediaHistoryEntry] = []
    @Published var readerStyle = ReaderStyle()
    @Published var keepMediaHistory = true { didSet { saveSetting("media_history_on", keepMediaHistory ? "1" : "0") } }
    /// When playing media in every tab is paused by the sleep timer.
    @Published var mediaSleepAt: Date?
    /// Groups folded shut in the sidebar's group list.
    @Published var collapsedGroups: Set<String> = []
    @Published var protectPinned = true { didSet { saveSetting("protect_pinned", protectPinned ? "1" : "0") } }
    var watchTask: Task<Void, Never>?
    /// The tab groups of each workspace, keyed by the workspace's name (Personal is ""). A group is a path such as "Work/Project A", and belongs to one workspace:
    /// the same name in two workspaces is two groups.
    @Published var groupLists: [String: [String]] = [:]
    /// Groups saved before groups belonged to workspaces: placed in the workspaces whose tabs use them once the tabs are known (see `mergeGroupNamesFromTabs`).
    private var legacyGroupNames: [String] = []
    /// The groups of the workspace in front: what the sidebars, menus and overview list, and what new groups are added to.
    var groupNames: [String] {
        get { groupLists[activeWorkspace] ?? [] }
        set {
            var all = groupLists
            all[activeWorkspace] = newValue.isEmpty ? nil : newValue
            groupLists = all
        }
    }
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
    /// The Settings section a search result asked to see; the open pane scrolls to it and clears this.
    @Published var settingsReveal: SettingsReveal?
    /// The width the standard top bar gives its address field, so the suggestions drop down at exactly that width in every layout (0 until the bar has been drawn).
    @Published var topBarFieldWidth: CGFloat = 0
    /// The card shown for a download that has just finished.
    @Published var downloadBanner: DownloadBanner?
    var bannerTask: Task<Void, Never>?
    @Published var themeID = "midnight" { didSet { saveSetting("theme", themeID); applyTheme() } }
    @Published var customTheme = CustomTheme()
    @Published var appearance: AppearanceMode = .system { didSet { saveSetting("appearance", appearance.rawValue); applySystemAppearance() } }
    @Published var tabLayout: TabLayout = .separate { didSet { saveSetting("tab_layout", tabLayout.rawValue); applyLayoutIfNeeded() } }
    /// iPhone: which of the layouts is in use (see `PhonePreset`). Ignored on the iPad and the Mac.
    @Published var phonePreset: PhonePreset = .bottomBar {
        didSet { saveSetting("phone_preset", phonePreset.rawValue); phoneLayoutChanged() }
    }
    /// The layout whose first-time steps are on screen.
    @Published var layoutTip: PhonePreset?
    /// iPhone: what the tabs button opens: the grid of pages (Safari's) or the vertical list that slides in from the left. Immersive always uses the list.
    @Published var phoneTabsView: PhoneTabsView = .grid { didSet { saveSetting("phone_tabs_view", phoneTabsView.rawValue) } }
    /// The Enhanced Player panel (see `EnhancedPlayer.swift`): shown only when asked for, over a page that keeps its own player and its own controls.
    @Published var playerPanelVisible = false
    /// The floating player (see `FloatingPlayer.swift`) is on the page: it opens when a video starts playing, can be moved anywhere in the window and is closed with its cross.
    @Published var floatingPlayerOpen = false
    /// Open the floating player by itself when a video starts playing.
    @Published var autoShowPlayer = true { didSet { saveSetting("player_auto_show", autoShowPlayer ? "1" : "0") } }
    /// Where the person left it (kept, so it is there again next time).
    @Published var floatingPlayerLayout = FloatingPlayerLayout.standard { didSet { if floatingPlayerLayout != oldValue { saveSetting("player_position", floatingPlayerLayout.stored) } } }
    let player = PlayerState()
    var playerPollTask: Task<Void, Never>?
    /// Optional: offer to carry on where a long video was left (normal tabs only; nothing is kept for a private, scratch, Glance or guest tab).
    @Published var resumeMedia = false { didSet { saveSetting("player_resume", resumeMedia ? "1" : "0") } }
    @Published var mediaResumeList: [MediaResumeEntry] = []
    @Published var playerSiteSteps: [String: Double] = [:]
    var lastResumeSave = Date.distantPast
    /// The subtitle chosen for a site, chosen again the next time.
    @Published var playerSiteSubtitles: [String: String] = [:]
    /// When another tab starts playing sound, pause the rest (a call is never paused).
    @Published var audioFocus = false { didSet { saveSetting("audio_focus", audioFocus ? "1" : "0") } }
    /// Pause sound that has played in a background tab for this many minutes (0: never).
    @Published var mediaBackgroundMinutes = 0 { didSet { saveSetting("media_background_minutes", String(mediaBackgroundMinutes)) } }
    var elsewhereSince: [UInt64: Date] = [:]
    /// How far the panel's skip buttons move, in seconds.
    @Published var playerSeekStep: Double = 10 { didSet { saveSetting("player_seek_step", String(Int(playerSeekStep))) } }
    /// A small pill offering the way back to the top of a long page (see `BackToTopRules`).
    /// The extra choices in the page's right-click menu (see `PageMenuChoices`).
    @Published var pageMenuExtras = true { didSet { saveSetting("page_menu_extras", pageMenuExtras ? "1" : "0") } }
    /// How fast Auto Scroll moves the page, in points a second.
    @Published var autoScrollSpeed = 90.0 { didSet { saveSetting("auto_scroll_speed", String(autoScrollSpeed)) } }
    @Published var backToTopPill = true { didSet { saveSetting("back_to_top_pill", backToTopPill ? "1" : "0"); if !backToTopPill { resetBackToTop() } } }
    @Published var backToTopVisible = false
    var backToTopRules = BackToTopRules()
    var backToTopExpiry: Task<Void, Never>?
    /// Counted up each time something asks for the vertical list; the phone's screen opens it.
    @Published var phoneTabsListRequest = 0
    var phoneUsesVerticalTabs: Bool { phoneSpec.fanOut || phoneTabsView == .vertical }
    /// Real vertical tabs: a column of tab tiles beside the page (not with Immersive, which has its own list).
    var phoneUsesTabRail: Bool { !phoneSpec.fanOut && phoneTabsView == .sidebar }
    /// Whether that column is folded out into a list with titles.
    @Published var tabRailExpanded = false
    /// What the tabs buttons of the phone layouts do.
    func openTabsView() {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone, phoneUsesTabRail { withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) { tabRailExpanded.toggle() }; return }
        if UIDevice.current.userInterfaceIdiom == .phone, phoneUsesVerticalTabs { phoneTabsListRequest += 1; return }
        #endif
        showOverview()
    }
    /// The layout the person built for Custom.
    @Published var phoneCustomSpec: PhoneLayoutSpec = .bottomBar {
        didSet {
            if let data = try? JSONEncoder().encode(phoneCustomSpec), let text = String(data: data, encoding: .utf8) { saveSetting("phone_custom_layout", text) }
            if phonePreset == .custom { phoneLayoutChanged() }
        }
    }
    /// The layout in force: the preset's own, or the one built for Custom.
    var phoneSpec: PhoneLayoutSpec { phonePreset.spec ?? phoneCustomSpec }

    /// A new layout: the controls open or fold to match it. (The Mac and the iPad have their own layouts and ignore this.)
    private func phoneLayoutChanged() {
        #if os(iOS)
        if phoneSpec.staysFolded { foldChrome() } else { expandChrome(userRequested: true) }
        #endif
    }
    @Published var layoutPreset: LayoutPreset = .classic { didSet { saveSetting("layout_preset", layoutPreset.rawValue); applyLayoutIfNeeded() } }
    @Published var sidebarPosition: SidebarPosition = .left { didSet { saveSetting("sidebar_position", sidebarPosition.rawValue) } }
    @Published var sidebarWidth: Double = 260 { didSet { saveSetting("sidebar_width", String(Int(sidebarWidth))) } }
    @Published var sidebarRail = false { didSet { saveSetting("sidebar_rail", sidebarRail ? "1" : "0") } }
    @Published var density: InterfaceDensity = .comfortable { didSet { saveSetting("density", density.rawValue) } }
    @Published var paletteVisible = false
    @Published var accent: AccentChoice = .teal { didSet { applyWorkspaceTheme(); saveSetting("accent", accent.rawValue) } }
    /// True once the user has picked an accent themselves; from then on a theme no longer repaints it.
    @Published var accentChosen = false { didSet { applyWorkspaceTheme(); saveSetting("accent_chosen", accentChosen ? "1" : "0") } }
    /// The picture chosen for the start page background, already shrunk. Kept in this profile's folder; never sent anywhere.
    @Published var startImageData: Data?
    /// How that picture sits and is treated (position, fit, saturation, brightness, the effects over it), kept as one setting.
    @Published var startLook = StartLook() { didSet { if startLook != startLook.clamped() { startLook = startLook.clamped() } else { saveSetting("start_look", startLook.encoded) } } }
    /// What the picture looks like, worked out once when it is loaded (see `WallpaperAnalyzer`).
    @Published var startAnalysis: WallpaperAnalysis?
    /// The collection of pictures, their light/dark tags and how they rotate (see `WallpaperLibrary.swift`).
    @Published var wallpaperLibrary = WallpaperLibraryState() { didSet { saveSetting("wallpaper_library", wallpaperLibrary.encoded) } }
    /// Whether the saved collection was read at start (so leftovers in its folder may be cleaned up).
    var wallpaperLibraryWasRead = false
    /// The collection picture on the page now.
    @Published var currentWallpaperID: UUID?
    /// The gradient preset, and whether it drifts.
    @Published var startPreset = StartPreset.defaultID { didSet { saveSetting("start_preset", startPreset) } }
    @Published var startAnimatedGradient = false { didSet { saveSetting("start_animated_gradient", startAnimatedGradient ? "1" : "0") } }
    /// An animated wallpaper (a short loop from this device) is kept, and is switched on.
    @Published var startHasVideo = false
    /// Changes whenever the loop is replaced or removed, so a player that is running is rebuilt for the new file.
    @Published var startVideoVersion = 0
    @Published var startVideoOn = false { didSet { saveSetting("start_video_on", startVideoOn ? "1" : "0") } }
    /// Checkpoints of the open pages, newest first (the Session Time Machine).
    @Published var checkpoints: [SessionCheckpoint] = []
    var unresponsiveStreak = 0
    var splitDisplay: [UInt64] = []
    var connectionNoteTask: Task<Void, Never>?
    var lastConnectionNote = Date.distantPast
    var unresponsiveReported = false
    /// Days of browsing history to keep; 0 keeps it all.
    @Published var historyRetentionDays = 0 { didSet { saveSetting("history_retention_days", String(historyRetentionDays)) } }
    @Published var startTitle = "" { didSet { saveSetting("start_title", startTitle) } }
    @Published var startFont: StartFont = .rounded { didSet { saveSetting("start_font", startFont.rawValue) } }
    @Published var startSearchStyle: StartSearchStyle = .pill { didSet { saveSetting("start_search_style", startSearchStyle.rawValue) } }
    @Published var startWidth: StartWidth = .standard { didSet { saveSetting("start_width", startWidth.rawValue) } }
    /// How much the start page's picture is darkened (0 to 0.7) and blurred (0 to 30 points).
    @Published var startImageDim = 0.3 { didSet { saveSetting("start_image_dim", String(startImageDim)) } }
    @Published var startImageBlur = 0.0 { didSet { saveSetting("start_image_blur", String(startImageBlur)) } }
    @Published var newTabMode: NewTabMode = .home { didSet { saveSetting("new_tab_mode", newTabMode.rawValue) } }
    @Published var newTabURL = "" { didSet { saveSetting("new_tab_url", newTabURL) } }
    @Published var startColorA = StartColor.defaultA { didSet { saveSetting("start_color_a", startColorA) } }
    @Published var startColorB = StartColor.defaultB { didSet { saveSetting("start_color_b", startColorB) } }
    @Published var startBackground: StartBackground = .gradient { didSet { saveSetting("start_background", startBackground.rawValue) } }
    @Published var showGreeting = true { didSet { saveSetting("show_greeting", showGreeting ? "1" : "0") } }
    @Published var showRecentlyClosed = true { didSet { saveSetting("show_recently_closed", showRecentlyClosed ? "1" : "0") } }
    @Published var tabPreviews = true { didSet { saveSetting("tab_previews", tabPreviews ? "1" : "0") } }
    /// "restore" reopens last session's tabs; "blank" starts with one empty tab.
    @Published var startup = "restore" { didSet { saveSetting("startup", startup) } }
    @Published private(set) var workspaces: [Workspace] = []
    @Published var activeWorkspace = "" {
        // Pinned tabs set to start over when their workspace is left are marked here and sent back to their pinned address when they are next shown.
        // Not while the first tab is being restored: landing in the workspace used last is not leaving another one.
        didSet { if oldValue != activeWorkspace, !applyingSettings, !openingFirstTab { workspaceLeft(oldValue) } }
    }
    /// Glance: a link opens in a floating preview over the page. On by default; the trigger and the kind of session are choices in Settings.
    @Published var glanceEnabled = true { didSet { saveSetting("glance_enabled", glanceEnabled ? "1" : "0"); pushWebPolicy() } }
    @Published var glanceTrigger: GlanceTrigger = .option { didSet { saveSetting("glance_trigger", glanceTrigger.rawValue); pushWebPolicy() } }
    /// The preview gets storage of its own that is gone when it closes (no sign-ins), instead of the page's own session.
    @Published var glanceTemporarySession = false { didSet { saveSetting("glance_temporary", glanceTemporarySession ? "1" : "0") } }
    lazy var glance: GlanceCoordinator = GlanceCoordinator(model: self)
    /// The address bar learns from what you open and choose (on this device only). Never in private tabs or guest windows.
    @Published var learnSuggestions = true { didSet { saveSetting("learn_suggestions", learnSuggestions ? "1" : "0") } }
    /// Sites the address bar must never learn from (a name such as example.com covers its subdomains).
    @Published var suggestionExcludedHosts: [String] = [] { didSet { saveSetting("suggestion_excluded", encodedMap(["list": suggestionExcludedHosts])) } }
    private var learningStore: (profile: String, store: SuggestionLearning)?
    /// This profile's memory of what the address bar learned; made when first needed, and again if the profile changes.
    var suggestionLearning: SuggestionLearning {
        if let learningStore, learningStore.profile == profileName { return learningStore.store }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("profiles/\(profileName)", isDirectory: true)
        let store = SuggestionLearning.shared(folder: folder)
        learningStore = (profileName, store)
        return store
    }
    /// A workspace asked for from outside (`--space`, a `browsersetu://space` link, Shortcuts) opens in a new window rather than in this one (Mac).
    @Published var spaceRequestsOpenNewWindow = false { didSet { saveSetting("space_request_new_window", spaceRequestsOpenNewWindow ? "1" : "0") } }
    /// The sites kept in every workspace (see Essentials.swift), in order.
    @Published var essentials: [EssentialTab] = []
    /// The address each pinned page returns to, by the address it was pinned at (see PinnedAddresses.swift). Synced with the site rules.
    @Published var pinnedAddresses: [String: PinnedTabMetadata] = [:]
    /// Pinned tabs waiting to go back to their pinned address the next time they are shown.
    var pendingPinnedResets = Set<UInt64>()
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
    @Published var videoSpeeds: [String: Double] = [:] { didSet { saveSetting("video_speeds", encodedMap(videoSpeeds)); pushWebPolicy() } }
    /// Developer capture of the console and WebSocket activity. Off by default; the page can see it, so it is a choice. Takes effect on the next page load.
    @Published var devCapture = false { didSet { saveSetting("dev_capture", devCapture ? "1" : "0"); pushWebPolicy() } }
    @Published var referrerMode: ReferrerMode = .standard { didSet { saveSetting("referrer_mode", referrerMode.rawValue); pushWebPolicy() } }
    /// True while a group of privacy switches is being changed together (see `changingPrivacySwitches`).
    var policyPushSuspended = false
    /// Sends the Global Privacy Control signal. On unless the person turned it off.
    @Published var globalPrivacyControl = true { didSet { saveSetting("gpc", globalPrivacyControl ? "1" : "0"); pushWebPolicy() } }
    /// Links lose their click-reporting `ping` attribute. On unless the person turned it off.
    @Published var blockLinkPings = true { didSet { saveSetting("block_link_pings", blockLinkPings ? "1" : "0"); pushWebPolicy() } }
    /// Sites that always load in Lockdown Mode.
    @Published var lockdownHosts = Set<String>() { didSet { if lockdownHosts != oldValue { pushWebPolicy() } } }
    /// Links through a tracker's redirect page go straight to their destination. On unless the person turned it off.
    @Published var debounceLinks = true { didSet { saveSetting("debounce_links", debounceLinks ? "1" : "0") } }
    /// A website cannot reach this device or the home network (localhost, 192.168.x.x and the like); sites the person named are left alone. Off until chosen.
    @Published var blockLocalNetwork = false { didSet { saveSetting("block_local_network", blockLocalNetwork ? "1" : "0"); pushWebPolicy() } }
    @Published var localNetworkAllowed = Set<String>() { didSet { if localNetworkAllowed != oldValue { pushWebPolicy() } } }
    /// Google's analytics, ad and font servers are refused on every site. Off until chosen, because pages then show their fallback fonts.
    @Published var blockGoogleServices = false { didSet { saveSetting("block_google_services", blockGoogleServices ? "1" : "0"); pushWebPolicy() } }
    /// Embedded social buttons, share counters and feeds are refused on other sites. Off until chosen.
    @Published var blockSocialWidgets = false { didSet { saveSetting("block_social_widgets", blockSocialWidgets ? "1" : "0"); pushWebPolicy() } }
    @Published var hideCookieBanners = true { didSet { saveSetting("cookie_banners", hideCookieBanners ? "1" : "0"); pushWebPolicy() } }
    /// Whether a banner that cannot be refused is hidden. It is reported as hidden, never as refused.
    @Published var hideUnrefusableBanners = true { didSet { saveSetting("cookie_banners_hide", hideUnrefusableBanners ? "1" : "0"); pushWebPolicy() } }
    /// Sites where banners are left alone, and the local record of what happened to banners (host, tool, outcome; no page content).
    @Published var consentOffSites = Set<String>()
    /// SponsorBlock: off until the person turns it on and agrees to what it sends (the date they agreed). The segments are kept in memory only.
    @Published var sponsorBlockEnabled = false { didSet { saveSetting("sponsor_on", sponsorBlockEnabled ? "1" : "0"); pushWebPolicy() } }
    @Published var sponsorConsentDate: Date? { didSet { saveSetting("sponsor_consent", sponsorConsentDate.map { String($0.timeIntervalSince1970) } ?? "") } }
    @Published var sponsorActions: [String: String] = [:]
    @Published var sponsorOffSites = Set<String>()
    @Published var sponsorServer = SponsorBlockService.defaultServer { didSet { saveSetting("sponsor_server", sponsorServer); sponsorCache.clear() } }
    let sponsorCache = SponsorCache()
    @Published var consentLog: [ConsentRecord] = []
    @Published var blockAutoplay = true { didSet { saveSetting("block_autoplay", blockAutoplay ? "1" : "0"); pushWebPolicy() } }
    @Published var autoplayExceptions = Set<String>()
    @Published var youtubeRules = YouTubeAdRules.builtIn { didSet { saveJSON("youtube_rules", youtubeRules); pushWebPolicy() } }
    @Published var keepYouTubeRulesFresh = true { didSet { saveSetting("youtube_rules_auto", keepYouTubeRulesFresh ? "1" : "0") } }
    @Published var youtubeRulesChecked: Date?
    @Published var blockVideoAds = true { didSet { saveSetting("video_ads", blockVideoAds ? "1" : "0"); pushWebPolicy() } }
    // Break mode, address bar sources, hover previews, theme schedule, chains, panels, menus (BrowserExtras.swift)
    @Published var addressSources: [AddressSource] = AddressSource.defaults { didSet { saveSetting("address_sources", addressSources.map(\.rawValue).joined(separator: ",")) } }
    @Published var breakActive = false
    /// Hide the tab strip while only one tab is open (the Mac's separate strip only; it comes back with the second tab).
    @Published var hideSingleTabStrip = false { didSet { saveSetting("hide_single_tab_strip", hideSingleTabStrip ? "1" : "0") } }
    /// Resizing the sidebar settles on its standard width when it comes close to it.
    @Published var snapSidebarWidth = true { didSet { saveSetting("snap_sidebar_width", snapSidebarWidth ? "1" : "0") } }
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
    /// The first-launch film (Shared/Intro) is on screen, covering the whole window; setup follows it. Only a brand-new install sees it.
    @Published var showIntro = false
    func finishIntro() { saveSetting("intro_done", "1"); showIntro = false }
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
    @Published var splitTabID: UInt64? {
        willSet { if newValue == nil, splitTabID != nil { rememberSplit() } }
        didSet { if splitTabID == nil { thirdSplitTabID = nil } }
    }
    /// Scrolling one panel moves the others with it.
    @Published var linkedPanes = false
    var linkTask: Task<Void, Never>?
    /// The two pages of the split that was closed last.
    @Published var lastSplit: SplitTemplate?
    @Published var comparison: PageComparison?
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
    /// The one list model the Downloads window and the toolbar popover share, so they show the same rows. Rebuilt only if the coordinator itself is replaced.
    var downloadList: DownloadsViewModel {
        if let existing = sharedDownloadList, existing.serves(downloads) { return existing }
        // The older history lives in the core; it is read through the same call the older list uses, and never written.
        let core = self.core
        let made = DownloadsViewModel(coordinator: downloads, legacy: { limit in try core.listDownloads(limit: limit).map { (url: $0.url, filename: $0.filename, created: $0.created) } })
        made.diagnostics = downloadDiagnostics
        // In a private window the list shows that window's own private downloads, and in an ordinary window none of any private window's.
        made.viewerPrivateSession = { [weak self] in self?.isPrivateWindow == true ? self?.privateSessionID : nil }
        sharedDownloadList = made
        return made
    }
    private var sharedDownloadList: DownloadsViewModel?
    private(set) var core: BrowserCore
    let root: String
    /// This profile's folder on disk (the reading list keeps its articles here).
    var profileFolder: URL { URL(fileURLWithPath: root) }
    private var saveTask: Task<Void, Never>?

    private let persistsProfileChoice: Bool

    /// The windows' models, for the Dock menu and the Services menu to act on the right one. Weak, so a closed window is not kept alive.
    static let activeModels = NSHashTable<BrowserModel>.weakObjects()
    /// Told of every Copy command in the app, for the clipboard history (which is off unless the person turns it on).
    nonisolated(unsafe) static var copyObserver: ((String) -> Void)?

    #if DEBUG
    /// Every model made in this process, so a test run can close their pages when each test ends: pages a test left open would keep their web processes alive for the
    /// rest of the run, and a long run would end with hundreds of them.
    static let liveModels = NSHashTable<BrowserModel>.weakObjects()

    func closeAllPagesForTests() {
        for tab in tabs { tab.shutdown() }
    }
    #endif

    /// `root` and `profile` are overridable so tests can run against isolated storage.
    private var iconBlocklistObserver: AnyCancellable?

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
        FaviconStore.shared.activate(directory: Self.faviconDirectory(root: base, profile: wanted), importLegacy: wanted == "default")
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
        privacy.onSecurityEvent = { [weak self] kind, site, detail in self?.recordSecurity(kind: kind, site: site, detail: detail) }
        // The browser's own protection applies to the icons it fetches too: what its lists block outright (by domain) is read back from the compiled rules whenever they are rebuilt.
        iconBlocklistObserver = privacy.$snapshot.removeDuplicates().sink { snapshot in
            let lists = [snapshot?.rulesJSON].compactMap { $0 } + (snapshot?.additionalRulesJSON ?? [])
            Task.detached(priority: .utility) { await FaviconStore.shared.setBlocklist(IconBlocklist.build(from: lists)) }
        }
        privacy.load(from: core)
        profiles = listProfiles(root: base)
        loadUISettings()
        engine.downloads.onLowDisk = { [weak self] name, needed, free in
            self?.notice = "Not enough disk space for \(name): it needs \(DownloadStats.bytes(needed)) and \(DownloadStats.bytes(free)) is free."
        }
        engine.downloads.onFinished = { [weak self] source, filename, isPrivate in
            // From a private tab nothing is written down: not the downloads list, not the security log, and the notification does not name the file.
            // A .torrent file the person just downloaded is offered in the torrent preview (looking at it contacts no one; starting it still needs their approval).
            if !isPrivate, filename.lowercased().hasSuffix(".torrent"), let self, let file = self.engine.downloads.completed.first, file.lastPathComponent == filename,
               self.pendingTorrentFile == nil, self.sheet == nil || self.sheet == .downloads {      // never replaces something the person is in the middle of
                self.pendingTorrentFile = file; self.sheet = .downloads
            }
            if !isPrivate { try? self?.core.recordDownload(url: source?.absoluteString ?? "", filename: filename) }
            self?.openFinishedPDFIfWanted(source: source, filename: filename)
            // A card at the foot of the window says it is done; a kind of file that can run code carries its warning in the same card instead of a box to dismiss.
            if !isPrivate, let warning = DownloadSafety.warning(forFilename: filename, from: source) {
                self?.recordSecurity(kind: "download", site: source?.host ?? "", detail: "\(filename): \(warning)")
            }
            self?.showDownloadBanner(filename: filename, fileURL: self?.engine.downloads.completed.first, warning: DownloadSafety.warning(forFilename: filename, from: source))
            // A downloaded file is never opened for you: a pass, a contact card or a calendar event waits in the list, with a button that adds it.
        }
        extensionObserver = extensionCenter.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        attachExtensions()
        startTabWatch()
        observeNetwork()
        windows.add(self)
        Self.activeModels.add(self)
        if !isSecondary { Self.copyObserver = { [weak self] text in Task { @MainActor in self?.recordCopy(text) } } }
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
        startTabWatch()
        observeNetwork()
        windows.add(self)
        Self.activeModels.add(self)
        #if DEBUG
        Self.liveModels.add(self)
        #endif
    }

    private func attachExtensions() {
        if ExtensionSafeMode.launchRequested {
            extensionCenter.enterSafeMode()
            return
        }
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
        // The iPhone's floating dock (the default, and Reading) replaces the bars: a pill at the bottom. Bottom Bar and Top Bar bring the bars back. The iPad keeps its sidebar.
        return UIDevice.current.userInterfaceIdiom == .phone && phoneSpec.usesDock
        #else
        return layoutPreset == .floating
        #endif
    }
    /// Full screen hides the toolbar until the pointer reaches the top edge (the sidebar layout has none to hide).
    var autoHidesToolbar: Bool {
        // A single toolbar has no top bar to hide, so a stored auto-hide choice must not bring a second one back (it left two address bars on screen).
        LayoutRules.autoHidesToolbar(preset: layoutPreset, singleToolbar: singleToolbar, toolbarAutoHide: toolbarAutoHide, fullScreen: windowFullScreen)
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
        guard doubleClickAction == .cycleLayout, !focusMode else { return false }      // in focus mode the change would be invisible
        cycleLayout()
        return true
    }

    /// Mac: a double-click on a tab closes it.
    @Published var doubleClickClosesTab = false { didSet { saveSetting("double_click_closes_tab", doubleClickClosesTab ? "1" : "0") } }
    /// Mac: tabs show no close cross; middle-click, the tab menu and ⌘W still close them.
    @Published var hideTabCloseButtons = false { didSet { saveSetting("hide_tab_close", hideTabCloseButtons ? "1" : "0") } }
    private var bulkClosingDepth = 0
    /// Mac: closing the last tab closes the window (a blank tab is kept for the next time).
    @Published var closeWindowWithLastTab = false { didSet { saveSetting("close_window_last_tab", closeWindowWithLastTab ? "1" : "0") } }

    private func closeFrontWindow() {
        #if os(macOS)
        NSApp.keyWindow?.performClose(nil)
        #endif
    }

    @Published var tintToolbar = true { didSet { saveSetting("tint_toolbar", tintToolbar ? "1" : "0") } }
    /// While a page is read the toolbar and tabs fold into a small pill; scrolling back brings them out again.
    @Published var collapseOnScroll = true {
        didSet { saveSetting("collapse_on_scroll", collapseOnScroll ? "1" : "0"); if !collapseOnScroll { expandChrome() } }
    }
    @Published private(set) var chromeCollapsed = false
    /// True while a page is being scrolled, and for a moment after: the extra pills (new tab, reload) beside the folded ones appear only once the screen has been still.
    @Published private(set) var pageIsScrolling = false
    private var scrollIdleTask: Task<Void, Never>?
    static let scrollIdleDelay: Duration = .milliseconds(600)
    private func noteScrolling() {
        if !pageIsScrolling { pageIsScrolling = true }
        scrollIdleTask?.cancel()
        scrollIdleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.scrollIdleDelay)
            if !Task.isCancelled { self?.pageIsScrolling = false }
        }
    }
    private var scrollChrome = ScrollChrome()
    /// Folding or unfolding resizes the page, and the page shifting under the user's finger must not count as scrolling.
    private var lastChromeChange = Date.distantPast
    static let chromeSettleTime: TimeInterval = 0.6

    /// Whether scrolling folds the controls. On the iPhone the layout says so (always shown never folds; the others do); on the iPad the "collapse while reading" switch.
    var phoneFoldsOnScroll: Bool {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return phoneSpec.folds }   // the layout alone decides on the phone; the old switch no longer has a say
        #endif
        return collapseOnScroll
    }

    /// Only a top toolbar can fold away: the sidebar layout keeps everything in the sidebar.
    var canCollapseChrome: Bool {
        #if os(iOS)
        // The iPad's sidebar holds only the tabs, so the address bar and toolbar can still fold away over the page. On the phone the layout decides.
        phoneFoldsOnScroll && !focusMode && !singleToolbar && !topBarHidden && !autoHidesToolbar
        #else
        collapseOnScroll && !focusMode && !singleToolbar && !topBarHidden && effectiveTabLayout != .sidebar && !autoHidesToolbar
        #endif
    }

    /// On the iPhone the bottom dock shrinks into a small pill while a page is read, and opens again when scrolling back.
    var canCollapseDock: Bool {
        #if os(iOS)
        phoneFoldsOnScroll && topBarHidden && !focusMode
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
        if abs(deltaY) >= 1 { noteScrolling() }
        guard canCollapseChrome || canCollapseDock || canFoldPill, !addressBar.isEditing, !findVisible, !overviewVisible, !paletteVisible else { return }
        #if os(iOS)
        // On the iPhone the folded dock stays folded however the page is scrolled afterwards, down or back up: only a tap on its pill (or a new page or tab) opens it again.
        if ChromeFoldPolicy.ignoresScroll(isPhone: UIDevice.current.userInterfaceIdiom == .phone, collapsed: chromeCollapsed, sticky: phoneSpec.sticky) { return }
        #endif
        // Only a clear "I am at the top" signal may cut through the settling time.
        guard deltaY >= 100 || Date().timeIntervalSince(lastChromeChange) > Self.chromeSettleTime else { return }
        if scrollChrome.scrolled(by: deltaY) {
            lastChromeChange = Date()
            chromeCollapsed = scrollChrome.collapsed
        }
    }

    /// Opens the toolbar. On the iPhone, once the dock has folded into its pills only a person's own request opens it again (a tap on a pill, Show Toolbar, a
    /// layout change): a page finishing, a tab being chosen from the list or the address bar taking focus must not unfold it behind their back.
    func expandChrome(userRequested: Bool = false) {
        #if os(iOS)
        if !userRequested && ChromeFoldPolicy.ignoresAutomaticExpand(isPhone: UIDevice.current.userInterfaceIdiom == .phone, sticky: phoneSpec.sticky) { return }
        #endif
        scrollChrome.expand()
        if chromeCollapsed { lastChromeChange = Date(); chromeCollapsed = false }
    }

    /// Folds the toolbar into its pills at once.
    func foldChrome() {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        #endif
        scrollChrome.collapse()
        if !chromeCollapsed { lastChromeChange = Date(); chromeCollapsed = true }
    }

    // Privacy and memory (per profile)
    @Published var stripTrackingParameters = true { didSet { saveSetting("strip_tracking", stripTrackingParameters ? "1" : "0") } }
    @Published var strippedLinkCount = 0
    /// How many requests the content rules refused, an hour at a time (an estimate: WebKit does not say). Kept per profile, on this device.
    @Published var blockedStats = BlockedStats()
    var completionCache: (date: Date, sites: [String])?
    private var blockedStatsURL: URL { URL(fileURLWithPath: root).appendingPathComponent("blocked-\(profileName).json") }

    func loadBlockedStats() { blockedStats = BlockedStats.load(from: blockedStatsURL) }

    /// Adds what a page just had refused. Private tabs are never recorded.
    func recordBlocked(_ count: Int, host: String? = nil, privateTab: Bool) {
        guard count > 0, !privateTab else { return }
        blockedStats.add(count, host: host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 })
        blockedStats.save(to: blockedStatsURL)
    }

    func resetBlockedStats() {
        blockedStats = BlockedStats()
        blockedStats.save(to: blockedStatsURL)
    }
    @Published var memoryMode: MemoryMode = .balanced { didSet { saveSetting("memory_mode", memoryMode.rawValue) } }
    /// Limits for the Custom profile.
    @Published var customMemory = CustomMemoryPolicy() { didSet { saveSetting("custom_keep", String(customMemory.keepRecent)); saveSetting("custom_idle", String(customMemory.idleMinutes)) } }
    /// Switch a Balanced profile to Battery Saver on a low battery or a hot device.
    @Published var batteryAware = true { didSet { saveSetting("battery_aware", batteryAware ? "1" : "0") } }
    @Published private(set) var perfLog: [PerfRecord] = []
    private(set) lazy var governor = ResourceGovernor(model: self)
    let launchedAt = Date()
    private var recordedStartup = false
    @Published var keepPinnedTabs = true { didSet { saveSetting("keep_pinned", keepPinnedTabs ? "1" : "0") } }
    @Published private(set) var threatList = ThreatList.empty
    /// Set when the last launches ended before they finished starting: tabs come back, but none is loaded for you.
    var safeStart = false
    private var sessionAllowedHosts = Set<String>()
    var recentStrips: [Date] = []
    /// Sites where a tracker's redirect page is never skipped, what has been skipped or left alone this session, and the unfamiliar links already described.
    @Published var redirectSkipOff = Set<String>()
    var redirectsSkipped = 0
    var redirectsKept = 0
    var describedRedirects = Set<String>()
    var lifecycle: TabLifecycle?
    /// Installed web extensions and their toolbar buttons. Its changes republish through the model.
    let extensionCenter: ExtensionCenter
    /// All windows of this browser (this one included). Every window has its own model; they share the database, engine, privacy rules and extensions.
    var windows = WindowRegistry()
    var isSecondary = false
    /// For a tab opened from a page and not left since: the tab to come back to when it closes. Cleared as soon as the person selects any other tab.
    var closeReturn: [UInt64: UInt64] = [:]
    /// This window appeared without the app asking for it (see WindowRegistry.requestWindow). It is hidden and closed again unless it is all there is.
    var isUnrequestedWindow = false
    /// A guest window: every tab is private, nothing is remembered, and the person's bookmarks and passwords are not offered. Mac only.
    @Published var isGuest = false
    /// The sheet on screen holds something typed or drawn that is not saved yet (an editor registered through `guardsUnsavedChanges`): Done and Escape then ask before closing it.
    @Published var sheetGuardActive = false
    /// Counts the times Done or Escape was pressed on such a sheet; the editor answers each one (see `SheetChrome`).
    @Published var sheetDismissRequest = 0
    /// A private window: every tab is private and uses storage that belongs to this window alone, bookmarks and saved passwords stay available, nothing is restored. Mac only.
    @Published var isPrivateWindow = false
    /// Names this window's temporary storage in the engine (made fresh with the window, never saved).
    let privateSessionID = UUID()
    /// ⇧⌘N: what it does. A private window unless the person chose otherwise.
    @Published var privateOpenMode: PrivateOpenMode = .window { didSet { saveSetting("private_open_mode", privateOpenMode.rawValue) } }
    /// The "private window or private tab?" question is showing.
    @Published var privateChoicePending = false
    /// What the Save to Research sheet is showing: the page, the selection and a note, until it is saved or closed.
    @Published var researchDraft: ResearchDraft?
    /// A screenshot being looked at or marked up. Kept in memory only, and gone when the editor closes.
    @Published var screenshotDraft: ScreenshotDocument?
    /// The tool the Tools panel opens on (set by the command palette). Never holds anything typed into a tool.
    var toolSelection: String?
    /// Whether a file sent from another device waits for a yes, and a file chosen elsewhere (a finished download) waiting to be sent.
    @Published var linkAskBeforeReceiving = true { didSet { saveSetting("link_ask", linkAskBeforeReceiving ? "1" : "0") } }
    @Published var transferFile: URL?
    /// The web apps the person installed, and (in the window of one) the app this window is.
    @Published var webApps: [WebAppRecord] = []
    var webApp: WebAppRecord?
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
        FrameMonitor.mark("Opening address bar")
        #if os(iOS)
        // The bar layouts have no separate search panel: the bar's own field is the one to type in, so the bars come back if folded and that field takes the focus.
        if UIDevice.current.userInterfaceIdiom == .phone, !topBarHidden {
            if let prefill { pendingAddressPrefill = prefill }
            let wasFolded = chromeCollapsed
            expandChrome(userRequested: true)
            // Folded bars are not on screen yet: the field has to exist before it can take the focus, so the request is made again once they have slid in.
            DispatchQueue.main.async { [self] in omniboxFocusTick += 1 }
            if wasFolded { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in omniboxFocusTick += 1 } }
            return
        }
        #endif
        if topBarHidden && pillCollapsed { pillCollapsed = false }      // a folded pill would otherwise leave the bar "open" with nothing on screen to show it
        floatingAddressVisible = true
        if let prefill { pendingAddressPrefill = prefill }
        DispatchQueue.main.async { [self] in floatingFocusTick += 1 }
    }

    /// Focuses the address bar wherever it currently lives. With no top bar and the sidebar hidden, that is a floating bar.
    func focusAddressBar() {
        #if os(macOS)
        // On a new tab the field in the middle of the page is the one to type in; on a loaded page it is the address bar in the toolbar.
        if let tab = active, tab.isBlank, !floatingAddressVisible, !(newTabMode == .blank && !tab.isPrivate) { startFocusTick += 1; return }
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
            // The pin choice belongs to the Sidebar layout. Applied to the others it put a docked sidebar into Minimal and Classic ("no sidebar") and into
            // Floating (a sidebar that slides in), whatever the person had pinned somewhere else.
            if layoutPreset == .sidebar {
                switch sidebarPinChoice {
                case true?: sidebarVisible = true
                case false?: sidebarVisible = false
                case nil: sidebarVisible = resolved.sidebarVisible
                }
            } else {
                sidebarVisible = resolved.sidebarVisible
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
        let filtered = listedTabs(inWorkspace: activeWorkspace).filter { inActiveGroup($0.group) && (!separatesPrivate || $0.isPrivate == privateMode) }
        return filtered.filter(\.pinned) + filtered.filter { !$0.pinned }
    }

    /// The profile's search engine: the one the user chose, or Google until they do.
    var searchTemplate: String {
        if let stored = (try? core.getSetting(key: "search_template")) ?? nil, !stored.isEmpty { return stored }
        return SearchEngines.defaultEngine.template
    }

    /// A different search engine for private tabs, by preset id; empty means the same as everywhere else.
    @Published var privateSearchID = "" { didSet { saveSetting("private_search", privateSearchID) } }

    /// The search address a typed search uses now: the private-tab engine inside a private tab when one is chosen, otherwise the profile's engine.
    var activeSearchTemplate: String {
        if activeIsPrivate, let preset = SearchEngines.presets.first(where: { $0.id == privateSearchID }) { return preset.template }
        return searchTemplate
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
    /// Where the search panel opens now: where the person asked for it in the dock layouts; on the bar's own side in the bar layouts (a panel at the bottom under a bar at
    /// the top was a second address field on the screen).
    var searchPanelAtBottomNow: Bool { topBarHidden ? searchPanelAtBottom : phoneBarAtBottom }
    /// Whether the bar layouts' bar is at the bottom: the layout says so on the phone; on the iPad the old setting does.
    var phoneBarAtBottom: Bool {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone { return phoneSpec.barAddress == .bottom }
        #endif
        return addressBarPosition == .bottom
    }
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
    /// The keys that tie a Wi-Fi sync to the device the person approved: in the Keychain, one set per profile. Tests run with memory-only keys so they never touch the real Keychain.
    var wifiKeysOverride: WiFiKeyStore?
    private lazy var memoryWiFiKeys = MemoryWiFiKeys()
    var wifiKeys: WiFiKeyStore {
        get { wifiKeysOverride ?? (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ? memoryWiFiKeys : KeychainWiFiKeys(profile: profileName)) }
        set { wifiKeysOverride = newValue }
    }
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
    @Published var darkPages: DarkPages = .off {
        didSet {
            saveSetting("dark_pages", darkPages.rawValue)
            pushWebPolicy()
            for tab in tabs { tab.applyDarkPages(live: true) }
        }
    }
    @Published private(set) var darkSites: Set<String> = []
    /// Sites that are never darkened, whatever the setting says.
    @Published private(set) var darkSitesOff: Set<String> = []
    /// In Low Power Mode, tabs that are not in use are released sooner.
    @Published var lowPowerSavesMemory = true { didSet { saveSetting("low_power_memory", lowPowerSavesMemory ? "1" : "0") } }
    /// Tabs that cannot be closed by accident, and named sets of tabs saved to open again later.
    /// Downloads are sorted into folders by kind (Images, Documents…) inside the downloads folder.
    @Published var maxDownloads = DownloadQueueRules.defaultConcurrent { didSet { saveSetting("download_concurrent", String(maxDownloads)); engine.downloads.maxConcurrent = maxDownloads } }
    /// Speed, connections, proxy and network-condition choices for the app's own downloader, saved per profile (the proxy password is in the Keychain, not here).
    @Published var downloadNetwork = DownloadNetworkSettings() { didSet { saveSetting("download_network", downloadNetwork.encoded() ?? ""); engine.downloads.networkSettings = downloadNetwork } }
    /// Peer-to-peer choices, saved per profile. Off until the person turns it on.
    @Published var torrentSettings = TorrentSettings() { didSet { saveSetting("download_torrent", torrentSettings.encoded() ?? ""); engine.downloads.torrentSettings = torrentSettings } }
    /// The download extensions of the current profile (made when first asked for, and again if the profile changes). A temporary profile keeps nothing on disk.
    private var downloadExtensionsCache: DownloadExtensionManager?
    var downloadExtensions: DownloadExtensionManager {
        if let existing = downloadExtensionsCache, existing.profile == profileName { return existing }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("download-extensions", isDirectory: true).appendingPathComponent(profileName, isDirectory: true)
        let made = DownloadExtensionManager(root: folder, profile: profileName, persistent: !isTemporaryProfile(profileName))
        downloadExtensionsCache = made
        return made
    }
    /// Local automation of downloads. Off until the person turns it on; never in a temporary profile.
    @Published var automationEnabled = false { didSet { saveSetting("download_automation", automationEnabled ? "1" : "0"); automation.setEnabled(automationEnabled) } }
    private var automationCache: AutomationController?
    var automation: AutomationController {
        if let existing = automationCache, existing.profile == profileName { return existing }
        automationCache?.setEnabled(false)
        let made = AutomationController(root: URL(fileURLWithPath: root), profile: profileName, persistent: !isTemporaryProfile(profileName),
                                        coordinators: { [weak self] in self.map { [$0.engine.downloads] } ?? [] }, feed: downloadFeed)
        automationCache = made
        return made
    }
    /// Website accounts for downloads, one list per profile. Created on first use; secrets are in the Keychain (in memory under test and in temporary profiles).
    private var accountStoreCache: AccountStore?
    var accountStore: AccountStore {
        if let existing = accountStoreCache, existing.profile == profileName { return existing }
        let persistent = !isTemporaryProfile(profileName)
        let folder = URL(fileURLWithPath: root).appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(profileName, isDirectory: true)
        let secrets: AccountSecretStore = (persistent && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) ? KeychainAccountSecretStore(profile: profileName) : MemoryAccountSecretStore()
        let made = AccountStore(profile: profileName, file: persistent ? folder.appendingPathComponent("accounts.json") : nil, secrets: secrets)
        accountStoreCache = made
        engine.downloads.accountStore = made
        return made
    }
    // MARK: LinkGrabber and link detection

    /// A click on a magnet or eD2k link opens the matching preview here instead of failing or going to another application. On by default; nothing is contacted by the click.
    @Published var interceptP2PLinks = true { didSet { saveSetting("link_p2p_intercept", interceptP2PLinks ? "1" : "0") } }
    /// Off until the person turns it on: the pasteboard is not read at all while it is off.
    @Published var watchClipboardForLinks = false { didSet { saveSetting("link_clipboard_watch", watchClipboardForLinks ? "1" : "0"); clipboardWatcher.setEnabled(watchClipboardForLinks) } }
    /// Text for the Add Download form to open with (a magnet or eD2k link that was clicked or chosen), and a downloaded .torrent file to preview.
    @Published var addDownloadPrefill: String?
    /// Where the prefilled address came from. An address the person typed is theirs; one a page or a collection supplied keeps the page-derived limits unless they change it.
    @Published var addDownloadPrefillOrigin: DownloadRequestOrigin = .user
    @Published var pendingTorrentFile: URL?
    @Published var linkGrabberRequested = false
    @Published private(set) var linkNotice: String?
    private var navigationGate = LinkNavigationGate()
    private var linkStoreCache: (profile: String, normal: LinkGrabberStore, privateStore: LinkGrabberStore)?
    private var linkStores: (normal: LinkGrabberStore, privateStore: LinkGrabberStore) {
        if let c = linkStoreCache, c.profile == profileName { return (c.normal, c.privateStore) }
        let made = (LinkGrabberStore(profile: profileName, isPrivate: false), LinkGrabberStore(profile: profileName, isPrivate: true))
        linkStoreCache = (profileName, made.0, made.1)
        return made
    }
    /// The collection for what is on screen: a private tab has a collection of its own, in memory only.
    var linkGrabber: LinkGrabberStore { active?.leavesNoTrace == true ? linkStores.privateStore : linkStores.normal }
    private(set) lazy var linkChecker = LinkMetadataChecker { [weak self] url in
        guard let self else { throw CancellationError() }
        let source = try await self.engine.downloads.http.engine.resolve(DownloadSourceRequest(url: url, profile: self.profileName, isPrivate: false, origin: .page))
        return LinkMetadata(filename: source.suggestedFilename, size: source.totalBytes, acceptsRanges: source.acceptsRanges)
    }
    private(set) lazy var clipboardWatcher = ClipboardLinkWatcher(
        pasteboard: SystemPasteboardSource(), isPrivateContext: { [weak self] in self?.active?.leavesNoTrace == true },
        onLinks: { [weak self] links in
            guard let self else { return }
            let r = self.linkStores.normal.add(candidates: links, provenance: .clipboard)
            if r.added > 0 { self.linkNotice = "\(r.added) link\(r.added == 1 ? "" : "s") from the clipboard added to the LinkGrabber." }
        })

    /// A magnet or eD2k link was clicked. Opens the existing preview, once per click; a link a page navigates to by itself does nothing. Returns whether the browser took it.
    func handleCustomLink(_ url: URL, linkActivated: Bool, fromPrivate: Bool = false) -> Bool {
        // A link to an FTP, FTPS, SFTP or WebDAV address: a click opens Remote Files with the address filled in (and not connected: a page never makes the browser contact a server by itself).
        // A page that navigates there on its own does nothing.
        if RemoteScheme(urlScheme: url.scheme) != nil {
            if linkActivated { openRemote(address: url.absoluteString, origin: .page, fromPrivate: fromPrivate) }
            return true
        }
        // A link to a Metalink file opens its description here instead of saving the file.
        if MetalinkLink.isMetalink(url) {
            if linkActivated { openMetalink(url: url, origin: .page) }
            return true
        }
        guard interceptP2PLinks else { return false }
        // Peer-to-peer downloads are not available from a private tab: they would be kept in the ordinary profile's list, and a private tab's content never goes there.
        if fromPrivate {
            if linkActivated { linkNotice = "Peer-to-peer links cannot be opened from a private tab. Open the link in an ordinary tab to preview it." }
            return true
        }
        switch navigationGate.decide(url: url, linkActivated: linkActivated, now: ProcessInfo.processInfo.systemUptime) {
        case .notOurs: return false
        case .ignore: return true
        case .open(let text):
            let kind = LinkClassifier.classify(text).kind
            guard kind == .magnet || kind == .ed2kFile else { linkNotice = "That link cannot be opened here: \(LinkClassifier.classify(text).display)"; return true }
            openLinkPreview(.preview(text: text))
            return true
        }
    }

    func openLinkPreview(_ route: LinkRoute) {
        switch route {
        // Downloads is brought up only if it is not already showing: setting the sheet toggles it, so a request made from inside Downloads (the media picker lives there) used to close it.
        case .preview(let text): addDownloadPrefill = text; addDownloadPrefillOrigin = .page; ensureDownloadsShown()
        case .previewLocalTorrent(let url): pendingTorrentFile = url; ensureDownloadsShown()
        case .mediaPreview(let url): addDownloadPrefill = url.absoluteString; addDownloadPrefillOrigin = .page; ensureDownloadsShown()
        case .download, .refused: break
        }
    }

    /// Brings Downloads up for a request that opens one of its sheets. Setting `sheet` to Downloads is a toggle (a second time it closes the panel), so it is only set when the panel is not
    /// already showing: a request made while Downloads is open must not close it.
    func ensureDownloadsShown() {
        if floatingPanel != .downloads && dockedPanel != .downloads { sheet = .downloads }
    }

    func openLinkGrabber() { ensureDownloadsShown(); linkGrabberRequested = true }

    // MARK: Feeds and podcasts

    @Published var remoteRequested = false
    private var remoteBrowserCache: (profile: String, model: RemoteBrowserModel)?
    /// This window's Remote Files browser (a server, a folder, a selection; in memory — saved servers are in the profile's folder, their secrets in the Keychain).
    var remoteBrowser: RemoteBrowserModel {
        if let c = remoteBrowserCache, c.profile == profileName { return c.model }
        let made = RemoteBrowserModel(coordinator: engine.downloads)
        remoteBrowserCache = (profileName, made)
        return made
    }
    /// Opens Remote Files, optionally at an address. A typed address connects; an address a page supplied only fills the form.
    func openRemote(address: String? = nil, origin: DownloadRequestOrigin = .user, fromPrivate: Bool = false) {
        remoteBrowser.isPrivate = fromPrivate || (active?.leavesNoTrace ?? false)
        if let address { remoteBrowser.open(address: address, origin: origin) }
        ensureDownloadsShown(); remoteRequested = true
    }
    @Published var providersRequested = false
    private var providerSheetCache: (profile: String, model: ProviderSheetModel)?
    /// This window's Repositories & Models sheet (in memory; nothing about it is saved).
    var providerSheet: ProviderSheetModel {
        if let c = providerSheetCache, c.profile == profileName { return c.model }
        let made = ProviderSheetModel(coordinator: engine.downloads)
        providerSheetCache = (profileName, made)
        return made
    }
    /// Opens Repositories & Models, at the current page's address when that is a repository, model or bucket (the person still chooses Look Up to send anything).
    func openProviders(address: String? = nil, fromPrivate: Bool = false) {
        providerSheet.isPrivate = fromPrivate || (active?.leavesNoTrace ?? false)
        if let address { providerSheet.address = address; providerSheet.load() }
        ensureDownloadsShown(); providersRequested = true
    }
    @Published var feedsRequested = false
    private var feedModelCache: (profile: String, model: FeedSheetModel)?
    /// This profile's feed list and open feed (in memory; subscriptions themselves are in the profile's download folder).
    var feedSheetModel: FeedSheetModel {
        if let c = feedModelCache, c.profile == profileName { return c.model }
        let made = FeedSheetModel(coordinator: engine.downloads)
        feedModelCache = (profileName, made)
        return made
    }
    func openFeeds(address: String? = nil, origin: DownloadRequestOrigin = .user) {
        if let address { feedSheetModel.prefill(address, origin: origin) }
        ensureDownloadsShown(); feedsRequested = true
    }

    // MARK: Remote ZIP

    @Published var remoteZipRequested = false
    #if os(macOS)
    private var remoteZipCache: (profile: String, model: RemoteZipModel)?
    /// This profile's archive reader. In memory only. (The Mac's Downloads window; the iPhone has no such reader.)
    var remoteZipModel: RemoteZipModel {
        if let c = remoteZipCache, c.profile == profileName { return c.model }
        let made = RemoteZipModel(coordinator: engine.downloads)
        remoteZipCache = (profileName, made)
        return made
    }
    #endif
    func openRemoteZip(address: String? = nil, origin: DownloadRequestOrigin = .user) {
        #if os(macOS)
        if let address { remoteZipModel.prefill(address, origin: origin) }
        #endif
        ensureDownloadsShown(); remoteZipRequested = true
    }

    // MARK: Website Explorer

    @Published var explorerRequested = false
    @Published var packagesRequested = false
    /// Set to open the TikTok account-export window from Downloads.
    @Published var tiktokExportRequested = false
    @Published var explorerAddress: String?
    private var explorerCache: (profile: String, store: ExplorerStore)?
    /// This profile's proposals. Never saved: they are in memory for as long as the window is, and the pages they came from are not kept.
    var websiteExplorer: ExplorerStore {
        if let c = explorerCache, c.profile == profileName { return c.store }
        explorerCache?.store.clear()
        let made = ExplorerStore(profile: profileName)
        explorerCache = (profileName, made)
        return made
    }
    func openExplorer(address: String? = nil) { explorerAddress = address; ensureDownloadsShown(); explorerRequested = true }
    func openPackages() { ensureDownloadsShown(); packagesRequested = true }

    /// "Explore This Website…": starts from the page that is open. A private tab is refused: what it finds could not be downloaded from here anyway, and nothing of it may be kept.
    func exploreCurrentSite(in chosen: TabController? = nil) {
        guard let tab = chosen ?? active, !tab.isBlank, let url = tab.url else { linkNotice = "There is no page open."; return }
        if tab.leavesNoTrace { linkNotice = "A private tab cannot be explored: downloads would be kept in the ordinary list."; return }
        openExplorer(address: url.absoluteString)
    }

    /// Starts reading. An address the person typed in the explorer's own field is theirs; one that came from a page is page-derived and is held to those limits. Returns a message when it cannot start.
    @discardableResult
    func startExplorer(_ url: URL, depth: Int, pages: Int, sameSite: Bool, stayInFolder: Bool, typedByPerson: Bool, listOtherWebsites: Bool = true) -> String? {
        guard DownloadSchedule.canSchedule(url) else { return "That is not a web address." }
        var scope = ExplorerScope(start: url, origin: typedByPerson ? .user : .page)
        scope.maxDepth = depth; scope.maxPages = pages; scope.sameOriginOnly = sameSite; scope.stayInDirectory = stayInFolder; scope.includeReferencedFiles = listOtherWebsites
        do {
            let fetch = try WebsiteExplorer.networkFetch(scope: scope.clamped(), network: engine.downloads.http.engine.currentNetwork)
            websiteExplorer.start(scope, explorer: WebsiteExplorer(fetch: fetch))
            return nil
        } catch { return (error as? LocalizedError)?.errorDescription ?? "The network settings do not allow this." }
    }

    /// The shown, selected proposals go to the LinkGrabber as page-derived links. Nothing is downloaded.
    @discardableResult
    func addExplorerSelectionToLinkGrabber() -> LinkGrabberStore.Report { websiteExplorer.addSelected(to: linkStores.normal) }

    // MARK: Packages

    /// This profile's packages, with their events going to the same feed as the tasks'.
    var packages: PackageStore {
        let store = engine.downloads.packages
        if store.onEvent == nil {
            store.onEvent = { [weak self] type, package, fraction in self?.downloadFeed.publishPackage(type: type, packageID: package.id, profile: package.profile, fraction: fraction) }
        }
        return store
    }

    // MARK: Media discovery

    /// Language choices for defaults (never a quality). Saved for the ordinary profile; a private tab's choices are not looked at or saved.
    @Published var mediaPreferences = MediaPreferences() { didSet { saveSetting("media_pref_audio", mediaPreferences.audioLanguage); saveSetting("media_pref_subs", mediaPreferences.subtitleLanguage) } }
    @Published var mediaDiscoveryRequested = false
    #if os(macOS)
    /// The video the Download button was pressed on (see VideoDownloadSheet). Taken once by the Downloads window.
    @Published var videoSheetRequest: VideoSubject?
    #endif
    private var mediaStoreCache: (profile: String, normal: MediaDiscoveryStore, privateStore: MediaDiscoveryStore)?
    private var mediaStores: (normal: MediaDiscoveryStore, privateStore: MediaDiscoveryStore) {
        if let c = mediaStoreCache, c.profile == profileName { return (c.normal, c.privateStore) }
        mediaStoreCache?.normal.clear(); mediaStoreCache?.privateStore.clear()
        let made = (MediaDiscoveryStore(profile: profileName, isPrivate: false), MediaDiscoveryStore(profile: profileName, isPrivate: true))
        mediaStoreCache = (profileName, made.0, made.1)
        return made
    }
    /// The candidates for what is on screen: a private tab has a list of its own, in memory only.
    /// DX-09: one provider operation per page and profile (what a site permits, authorization, resolved sources, renewal).
    private(set) lazy var providerFlow = ProviderFlow(coordinator: { [unowned self] in self.engine.downloads }, profile: { [unowned self] in self.profileName },
                                                     activePage: { [unowned self] in (self.active?.url, self.active?.leavesNoTrace == true) })
    var mediaDiscovery: MediaDiscoveryStore { active?.leavesNoTrace == true ? mediaStores.privateStore : mediaStores.normal }
    private var mediaSearch: Task<Void, Never>?
    private var mediaSearchToken = UUID()

    /// Names a page for the purpose of telling when it has changed: the tab and the address without its fragment.
    func pageKey(of tab: TabController) -> String {
        var c = tab.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        c?.fragment = nil
        return "\(tab.id)|\(c?.string ?? "")"
    }
    #if os(macOS)
    /// The Download button on a video entry: opens the sheet that says what can be saved. Nothing starts here.
    func openVideoSheet(for r: DetectedResource) {
        guard let subject = VideoSubject(r, isPrivate: active?.leavesNoTrace ?? false) else { linkNotice = "That address cannot be opened here."; return }
        ensureDownloadsShown(); videoSheetRequest = subject
    }

    /// Download for a whole page whose player builds its video in memory (nothing to fetch by itself): the sheet asks the router what can resolve it. Only on the person's click.
    func openVideoSheet(forPage url: URL, isPrivate: Bool) {
        // The page and the privacy state are the ones the found media belongs to (not whatever tab is in front by now).
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { linkNotice = "That page cannot be looked up."; return }
        ensureDownloadsShown(); videoSheetRequest = VideoSubject(page: url, title: url.host ?? "Video", isPrivate: isPrivate)
    }
    #endif

    func openMediaDiscovery() { ensureDownloadsShown(); mediaDiscoveryRequested = true }

    /// "Find Downloadable Media": reads the media elements and media links of the page that is open, once, and lists them. Nothing is downloaded and nothing is contacted.
    func discoverMediaOnCurrentPage(in chosen: TabController? = nil) {
        guard let tab = chosen ?? active, !tab.isBlank else { linkNotice = "There is no page open."; return }
        let store = tab.leavesNoTrace ? mediaStores.privateStore : mediaStores.normal
        mediaSearch?.cancel()
        mediaSearchToken = UUID(); let token = mediaSearchToken
        store.beginSearch()
        let key = pageKey(of: tab), host = tab.url?.host
        mediaSearch = Task { [weak self] in
            let read = await tab.engine.discoverMedia()
            guard !Task.isCancelled, let self else { store.endSearch(); return }
            // What the page's observer has seen (frames, players, loaded playlists) joins what the page read found: one list, one set of rules.
            let snapshot = MediaPageSnapshot(hits: MediaObservationBuffer.merge(scan: read.hits, observed: tab.mediaBuffer.hits()), truncated: read.truncated, failed: read.failed && tab.mediaBuffer.isEmpty)
            // The person may have gone somewhere else while the page was read: those results belong to the page they left.
            // A tab the person chose from its own right-click menu keeps its results even when it is not the one in front (the list is keyed by that tab).
            if self.active?.id == tab.id || chosen != nil, self.pageKey(of: tab) == key { store.ingest(snapshot, pageKey: key, pageHost: host); store.unobservedFrames = tab.mediaBuffer.unobservedFrames; store.observedNavigation = tab.mediaBuffer.navigation }
            if self.mediaSearchToken == token { store.endSearch() }
        }
        openMediaDiscovery()
    }
    // MARK: Live media observation (DX-07)

    private var mediaLive: Task<Void, Never>?

    /// A page in this tab reported a player. A tab that is not on screen only keeps it in its own buffer; the open list follows only the page it shows.
    func mediaObservationChanged(in tab: TabController, observation: MediaObservation) {
        guard active?.id == tab.id else { return }
        scheduleMediaSummary(for: tab)
        if resourceSummary.isEmpty, resourceTask == nil || resourceKey != pageKey(of: tab) { scheduleResourceScan(for: tab) }
        let store = tab.leavesNoTrace ? mediaStores.privateStore : mediaStores.normal
        // The list follows the same document: a single-page route change keeps the tab and the document, a new document does not.
        guard let listed = store.pageKey, listed.hasPrefix("\(tab.id)|"), store.observedNavigation == tab.mediaBuffer.navigation else { return }
        if observation.kind == .gone { if let p = observation.player { store.removePlayers(inFrame: observation.frame.token, player: p) }; return }
        if observation.kind == .bye { store.removePlayers(inFrame: observation.frame.token); return }
        mediaLive?.cancel()
        let key = listed, host = tab.url?.host
        mediaLive = Task { [weak self, weak tab] in
            try? await Task.sleep(nanoseconds: 300_000_000)          // a burst of events is one update
            guard !Task.isCancelled, let self, let tab, self.active?.id == tab.id, store.pageKey == key, store.observedNavigation == tab.mediaBuffer.navigation else { return }
            store.ingest(MediaPageSnapshot(hits: tab.mediaBuffer.hits(), truncated: false), pageKey: key, pageHost: host, removeMissing: false)
            store.unobservedFrames = tab.mediaBuffer.unobservedFrames
        }
    }

    /// The tab's page was replaced: whatever was listed from the old page is out of date (and any live update still waiting is dropped).
    func mediaPageNavigated(_ tab: TabController) {
        if active?.id == tab.id { scheduleMediaSummary(for: tab); scheduleResourceScan(for: tab) }
        if active?.id == tab.id { mediaLive?.cancel() }          // another tab's navigation does not cancel this tab's pending update
        let store = tab.leavesNoTrace ? mediaStores.privateStore : mediaStores.normal
        if active?.id == tab.id, store.pageKey != nil { store.markStale(currentPageKey: pageKey(of: tab)) }
    }

    // MARK: Media indicator (toolbar)

    /// What the page in front has shown of its media (see MediaPageSummary). Recomputed, briefly delayed, when the page reports something, navigates, or another tab comes to the front.
    @Published private(set) var mediaSummary = MediaPageSummary.empty
    private var summaryTask: Task<Void, Never>?
    private var summaryTab: UInt64?

    func scheduleMediaSummary(for tab: TabController? = nil) {
        summaryTask?.cancel()
        guard let tab = tab ?? active, active?.id == tab.id, MediaPageObserver.isEnabled else { summaryTab = nil; if !mediaSummary.isEmpty { mediaSummary = .empty; refreshResourceMedia() }; return }
        let id = tab.id
        summaryTab = id
        summaryTask = Task { [weak self, weak tab] in
            try? await Task.sleep(nanoseconds: 300_000_000)          // a burst of reports is one update
            guard !Task.isCancelled, let self, let tab, self.active?.id == id, self.summaryTab == id else { return }
            let next = MediaPageSummary.make(hits: tab.mediaBuffer.hits(), pageHost: tab.url?.host, isPrivate: tab.leavesNoTrace)
            if next != self.mediaSummary { self.mediaSummary = next; self.refreshResourceMedia() }
        }
    }

    // MARK: Download categories (toolbar)

    /// What the page in front links to, by category. Read passively (link addresses only), briefly after the page settles, and again a little later for pages that build themselves.
    @Published private(set) var resourceSummary = PageResourceSummary.empty
    private var resourceTask: Task<Void, Never>?
    /// Which category list is open (nil: none). Kept here so a rescan that changes the chips does not close it.
    @Published var resourcePopoverKey: String?

    private var resourceKey: String?
    /// When to read the page's links after it loads: soon, again as it builds itself, and once more later. A UI-test run (Debug only, `-UITestFastScan YES`) uses much shorter gaps.
    static var resourceScanDelays: [UInt64] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "UITestFastScan") { return [150_000_000, 700_000_000, 1_500_000_000] }
        #endif
        return [900_000_000, 2_100_000_000, 5_000_000_000]
    }

    func scheduleResourceScan(for tab: TabController? = nil, now: Bool = false) {
        resourceTask?.cancel()
        guard let tab = tab ?? active, active?.id == tab.id, ResourceDetectionSettings.isEnabled, !tab.isBlank else {
            resourceKey = nil; resourcePopoverKey = nil; if !resourceSummary.isEmpty { resourceSummary = .empty }; return
        }
        // A different page (or tab) than the one the chips describe: they go at once, so a stale Download button cannot be pressed while the new page is read.
        let key = pageKey(of: tab)
        noteResourcePage(key)
        let id = tab.id
        resourceTask = Task { [weak self, weak tab] in
            for delay in (now ? [50_000_000 as UInt64] : Self.resourceScanDelays) {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled, let self, let tab, self.active?.id == id, self.resourceKey == key, self.pageKey(of: tab) == key else { return }
                let scan = await tab.engine.scanPageLinks()
                guard !Task.isCancelled, self.active?.id == id, self.resourceKey == key, self.pageKey(of: tab) == key else { return }
                // A read that came back empty on a page that had items is a failed read, not a page that lost them.
                if scan.links.isEmpty, !self.resourceSummary.isEmpty, !scan.truncated { continue }
                self.applyResourceSummary(PageResourceSummary.build(scan: scan, media: self.mediaSummary, pageHost: tab.url?.host))
            }
        }
    }

    /// The page the chips describe. A different page clears the chips and any open list at once; the same page keeps both.
    func noteResourcePage(_ key: String) {
        guard resourceKey != key else { return }
        resourceKey = key; resourcePopoverKey = nil
        if !resourceSummary.isEmpty { resourceSummary = .empty }
    }

    /// New results for the same page. They replace the chips' contents but never close a list that is open: the list's open state is not part of the summary.
    func applyResourceSummary(_ next: PageResourceSummary) { if next != resourceSummary { resourceSummary = next } }

    /// Rebuilds only the media counts (the page's players changed) without reading the page again.
    private func refreshResourceMedia() {
        var s = resourceSummary
        let m = mediaSummary
        s.mediaDetected = m.detected > 0 ? [.audio: m.audioDetected, .video: m.detected - m.audioDetected] : [:]
        s.mediaOpenable = m.detected > 0 ? [.audio: m.audioOpenable, .video: m.openable - m.audioOpenable] : [:]
        if s != resourceSummary { resourceSummary = s }
    }

    /// One resource, through the engine that already handles its kind: a web file is a download (the person clicked it); a torrent or magnet goes to the link collection, whose preview asks before anything is contacted.
    /// A download started from a list in the browser window (the category chips, the media picker) ends with a visible card: finished (with the file), or failed (with the reason). Without this the
    /// only sign was the Downloads window, which may not be open. Private downloads get the same card with no file name kept anywhere else.
    func announceWhenDone(_ id: UUID) {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, let record = self.engine.downloads.ledger.record(id) else { return }
                switch record.state {
                case .completed:
                    let url = record.file.destinationPath.map { URL(fileURLWithPath: $0) }
                    self.showDownloadBanner(filename: record.isPrivate ? "A private download" : record.file.filename, fileURL: record.isPrivate ? nil : url, warning: nil); return
                case .failed, .recoveryRequired:
                    self.showDownloadBanner(filename: record.isPrivate ? "A private download" : record.file.filename, fileURL: nil, warning: "The download did not finish: \(record.failure?.reason ?? "it failed")."); return
                case .cancelled: return
                default: continue
                }
            }
        }
    }

    func downloadDetected(_ r: DetectedResource) {
        if r.category == .torrent || r.isManifest {
            let store = (active?.leavesNoTrace ?? false) ? linkStores.privateStore : linkStores.normal
            _ = store.add(candidates: [r.url], provenance: .page, group: active?.url?.host)
            openLinkGrabber()
        } else if let url = URL(string: r.url), let id = engine.downloads.scheduleDownload(url: url, at: Date(), origin: .page, isPrivate: active?.leavesNoTrace ?? false) {
            linkNotice = "Added to Downloads."
            announceWhenDone(id)
        } else { linkNotice = "That file could not be added." }
    }

    /// The listed resources go to the link collection, where each can be checked and added one by one.
    /// What "Download all" may start: what is listed, a file (not a card or playlist) the page or server gave real reason to think is one, and no more than a handful at a time.
    static let bulkLimit = 25
    func downloadableAll(_ items: [DetectedResource], among ids: Set<String>) -> [DetectedResource] {
        let eligible = items.prefix(200).filter { !$0.needsResolution && $0.confidence != .low && { if case .notAFile = $0.availability { return false }; return true }($0) }
        return Array((ids.isEmpty ? Array(eligible) : eligible.filter { ids.contains($0.id) }).prefix(Self.bulkLimit))
    }

    func collectResources(_ items: [DetectedResource]) -> LinkGrabberStore.Report {
        let store = (active?.leavesNoTrace ?? false) ? linkStores.privateStore : linkStores.normal
        let report = store.add(candidates: items.map(\.url), provenance: .page, group: active?.url?.host)
        openLinkGrabber()
        return report
    }

    func cancelMediaDiscovery() { mediaSearch?.cancel(); mediaSearch = nil; mediaDiscovery.endSearch(); mediaDiscovery.cancelInspections() }

    /// A candidate's playlist is read so its choices can be shown. Only the playlist is fetched.
    func inspectDiscoveredMedia(_ id: String) {
        let store = mediaDiscovery
        if let tab = active, store.pageKey != nil { store.markStale(currentPageKey: pageKey(of: tab)) }
        // The address came from a web page, so the local network is refused here even though the person asked for the look.
        store.inspect(id) { [weak self] url in
            guard let self else { throw CancellationError() }
            return try await self.engine.downloads.media.inspect(url, origin: .page, refuseInternal: true)
        }
    }

    /// Starts what the person chose: a file as an ordinary download, a stream at its choices. Refused (with the reason) for anything else.
    @discardableResult
    func openDiscoveredMedia(_ id: String) -> LinkRoute {
        let store = mediaDiscovery
        if let tab = active, store.pageKey != nil { store.markStale(currentPageKey: pageKey(of: tab)) }
        let route = store.route(id)
        switch route {
        case .download(let url):
            // Once: a second click on the same item must not make a second download.
            if let started = engine.downloads.scheduleDownload(url: url, at: Date(), origin: .page, isPrivate: active?.leavesNoTrace ?? false) { store.remove([id]); linkNotice = "Added to Downloads."; announceWhenDone(started) } else { linkNotice = "That media could not be added." }
        case .mediaPreview: openLinkPreview(route)
        case .refused(let why): linkNotice = why
        default: break
        }
        return route
    }

    /// Puts chosen candidates in the LinkGrabber (the same collection, the same duplicate rules). A private tab's go to the private collection.
    @discardableResult
    func addDiscoveredMediaToLinkGrabber(_ ids: Set<String>) -> LinkGrabberStore.Report {
        let source = mediaDiscovery
        if let tab = active, source.pageKey != nil { source.markStale(currentPageKey: pageKey(of: tab)) }
        let target = source.isPrivate ? linkStores.privateStore : linkStores.normal
        // Only what could be opened: not protected media, not in-page streams, not what the page's own network refused, not what is out of date.
        let urls = source.candidates.filter { ids.contains($0.id) && $0.canOpen }.compactMap(\.url)
        return target.add(candidates: urls, provenance: .page, group: active?.url?.host)
    }

    /// "Collect Download Links from This Page": reads the links of the page that is open, once, and puts the likely downloads in the collection. Nothing is downloaded or contacted.
    func collectLinksFromCurrentPage() async {
        guard let tab = active else { linkNotice = "There is no page open."; return }
        let store = tab.leavesNoTrace ? linkStores.privateStore : linkStores.normal
        let snapshot = await tab.engine.collectLinks()
        let report = store.add(candidates: snapshot.candidates, provenance: .page, group: tab.url?.host)
        linkNotice = snapshot.candidates.isEmpty ? "No download links were found on this page."
            : "\(report.added) link\(report.added == 1 ? "" : "s") collected\(report.duplicates > 0 ? ", \(report.duplicates) already there" : "")\(snapshot.truncated ? " (the page has more than the limit)" : "")."
        openLinkGrabber()
    }

    /// "Collect Images from This Page": the pictures of a gallery page (full-size files where the page links them) go to the LinkGrabber, grouped by the site, with the same duplicate rules. Nothing is downloaded yet.
    func collectImagesFromCurrentPage(in chosen: TabController? = nil) async {
        guard let tab = chosen ?? active, !tab.isBlank else { linkNotice = "There is no page open."; return }
        let store = tab.leavesNoTrace ? linkStores.privateStore : linkStores.normal
        let snapshot = await tab.engine.collectImages()
        let report = store.add(candidates: snapshot.candidates, provenance: .page, group: (tab.url?.host).map { $0 + " images" })
        linkNotice = snapshot.candidates.isEmpty ? "No pictures were found on this page."
            : "\(report.added) picture\(report.added == 1 ? "" : "s") collected\(report.duplicates > 0 ? ", \(report.duplicates) already there" : "")\(snapshot.truncated ? " (the page has more than the limit)" : "")."
        openLinkGrabber()
    }

    // MARK: Metalink (a description of one or more files and the places they can be had)

    /// Opens a Metalink document: what it lists is shown and asked about first, then it becomes ordinary downloads (several files: one collection). `data` is the document, `title` names the collection.
    func openMetalink(data: Data, title: String, privateTab: Bool? = nil) {
        let privateTab = privateTab ?? (active?.leavesNoTrace ?? false)
        Task { @MainActor in
            do {
                let files = try MetalinkParser.parse(data)
                let choice = await Dialogs.choose(title: files.count == 1 ? "Download “\(files[0].name)”?" : "Download \(files.count) files from this Metalink?",
                                                  message: MetalinkImport.summary(files), buttons: ["Download", "Cancel"])
                guard choice == 0 else { return }
                let out = await MetalinkImport.add(files, title: title, documentKey: MetalinkImport.documentKey(data), coordinator: engine.downloads, isPrivate: privateTab)
                linkNotice = out.started == 0 ? (out.alreadyThere > 0 ? "Those files are already in your Downloads." : "Nothing could be added from that Metalink file.")
                    : "Added \(out.started) download\(out.started == 1 ? "" : "s") from the Metalink file\(out.combined > 0 ? ", using several sources together where it is safe" : "")."
                ensureDownloadsShown()
            } catch { linkNotice = (error as? LocalizedError)?.errorDescription ?? "That Metalink file could not be read." }
        }
    }

    /// A link or typed address to a Metalink file: it is read here (never saved as a file the person has to find), under the rules of a page's address unless the person typed it.
    func openMetalink(url: URL, origin: DownloadRequestOrigin) {
        linkNotice = "Reading the Metalink file…"
        let privateTab = active?.leavesNoTrace ?? false          // (the tab it was asked from, not whichever is in front when the answer arrives)
        Task { @MainActor in
            do {
                let (data, final) = try await engine.downloads.media.fetchDocument(url, limit: MetalinkParser.maxBytes, origin: origin, refuseInternal: origin != .user)
                openMetalink(data: data, title: (final.deletingPathExtension().lastPathComponent).isEmpty ? "Metalink" : final.deletingPathExtension().lastPathComponent, privateTab: privateTab)
            } catch { linkNotice = (error as? LocalizedError)?.errorDescription ?? "That Metalink file could not be read." }
        }
    }

    // MARK: Download events (one feed: notifications, diagnostics and the automation stream all read it)

    /// Notification choices, saved per profile. Notifications are off until the person turns them on; the system's permission is asked for at that moment, not at launch.
    @Published var downloadNotifications = DownloadNotificationPreferences() { didSet { saveSetting("download_notifications", downloadNotifications.encoded() ?? ""); notificationsCache?.preferences = downloadNotifications } }
    private var feedCache: (profile: String, feed: DownloadEventFeed)?
    var downloadFeed: DownloadEventFeed {
        if let existing = feedCache, existing.profile == profileName { return existing.feed }
        feedCache?.feed.stop()
        let persistent = !isTemporaryProfile(profileName)
        let folder = URL(fileURLWithPath: root).appendingPathComponent("automation", isDirectory: true).appendingPathComponent(profileName, isDirectory: true)
        let hub = AutomationEventHub(sequence: AutomationEventSequence(file: persistent ? folder.appendingPathComponent("event-sequence.json") : nil))
        let made = DownloadEventFeed(coordinators: { [weak self] in self.map { [$0.engine.downloads] } ?? [] }, hub: hub)
        feedCache = (profileName, made)
        diagnosticsCache = nil; notificationsCache?.detach()
        return made
    }
    private var diagnosticsCache: DownloadDiagnostics?
    var downloadDiagnostics: DownloadDiagnostics {
        // The feed first: building a new one (a different profile) drops the old diagnostics, so this can never return another profile's or attach a second observer.
        let feed = downloadFeed
        if let existing = diagnosticsCache { return existing }
        let folder = URL(fileURLWithPath: root).appendingPathComponent("diagnostics", isDirectory: true).appendingPathComponent(profileName, isDirectory: true)
        let made = DownloadDiagnostics(file: isTemporaryProfile(profileName) ? nil : folder.appendingPathComponent("timelines.json"))
        diagnosticsCache = made
        feed.observe { [weak made] event, coordinator in made?.record(event, coordinator: coordinator) }
        made.prune(keeping: engine.downloads)
        return made
    }
    private var notificationsCache: DownloadNotificationService?
    var notifications: DownloadNotificationService {
        if let existing = notificationsCache { return existing }
        let center = SystemNotificationCenter()
        let service = DownloadNotificationService(
            center: center, coordinators: { [weak self] in self.map { [$0.engine.downloads] } ?? [] },
            downloadsVisible: { [weak self] in self?.sheet == .downloads },
            appActive: {
                #if os(macOS)
                NSApplication.shared.isActive
                #else
                UIApplication.shared.applicationState == .active
                #endif
            },
            openDownloads: { [weak self] _ in
                self?.sheet = .downloads
                #if os(macOS)
                NSApplication.shared.activate(ignoringOtherApps: true)
                #endif
            },
            reveal: {
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([$0])
                #endif
            },
            inApp: { [weak self] title, body in self?.engine.downloads.note("\(title): \(body)") })
        center.onAction = { [weak service] action, info in service?.perform(action: action, userInfo: info) }
        service.preferences = downloadNotifications
        notificationsCache = service
        return service
    }
    /// Starts the single feed and connects its readers. Safe to call again.
    func startDownloadEvents() {
        let feed = downloadFeed
        _ = downloadDiagnostics
        let service = notifications
        if !service.isAttached { service.attach(to: feed) }
        if downloadNotifications.enabled { service.prepare() }
        feed.start()
    }
    /// eD2k choices, saved per profile. Off until the person turns it on.
    @Published var ed2kSettings = ED2KSettings() { didSet { saveSetting("download_ed2k", ed2kSettings.encoded() ?? ""); engine.downloads.ed2kSettings = ed2kSettings } }
    /// Keeps the proxy password for this profile (an empty one removes it) and applies the settings again so the downloader picks it up.
    func setProxyPassword(_ password: String) {
        engine.downloads.proxyCredentials.setPassword(password, profile: profileName)
        engine.downloads.forgetProxyPasswordCache()
        engine.downloads.networkSettings = downloadNetwork
    }
    var hasProxyPassword: Bool { engine.downloads.cachedProxyPassword() != nil }
    /// A colour chosen for each website (hex by site), shown in place of the page's own colour.
    @Published var siteLooks: [String: String] = [:]
    @Published var feeds: [Feed] = []
    var lastPublished: SharedStore.Snapshot?
    @Published var siteTasks: [SiteTask] = []
    @Published var downloadTags: [String: [String]] = [:]
    @Published var feedItems: [FeedItem] = []
    @Published var refreshingFeeds = false
    var feedsLoaded = false
    @Published var siteTimeLog = SiteTimeLog()
    /// How many days of site time are kept (0: until cleared), and when the person last did something in the browser.
    @Published var siteTimeRetentionDays = 90
    var lastInteraction = Date()
    @Published var trackTime = false { didSet { saveSetting("track_time", trackTime ? "1" : "0") } }
    @Published var breakMinutes = 0 { didSet { saveSetting("break_minutes", String(breakMinutes)) } }
    var lastTimeTick = Date()
    var timeTicks = 0
    var breakSite = ""
    var breakStart: Date?
    /// Warns before opening an address that imitates a well-known site.
    @Published var lookalikeGuard = true { didSet { saveSetting("lookalike_guard", lookalikeGuard ? "1" : "0") } }
    /// Hosts the person chose to open anyway, until the browser closes.
    var allowedLookalikes = Set<String>()
    /// Hosts a look-alike question is already open for.
    var lookalikePrompting = Set<String>()
    /// "On weekdays 9 to 17, use the Work workspace."
    @Published var focusRules: [FocusRule] = [] { didSet { saveSetting("focus_rules", encodedMap(["list": focusRules])) } }
    /// The rule already applied in its current time window, so a change made by hand afterwards is left alone.
    var focusAppliedKey = ""
    @Published var keepClipboardHistory = false { didSet { saveSetting("clipboard_history", keepClipboardHistory ? "1" : "0"); if !keepClipboardHistory { clipboardHistory = [] } } }
    @Published var clipboardHistory: [ClipboardEntry] = []
    @Published var backdropIntensity: BackdropIntensity = .medium { didSet { ThemeState.intensity = backdropIntensity.value; saveSetting("backdrop_intensity", backdropIntensity.rawValue) } }
    @Published var iconWeight: IconWeight = .regular { didSet { IconWeight.current = iconWeight; LookState.shared.weight = iconWeight; saveSetting("icon_weight", iconWeight.rawValue) } }
    @Published var siteIconShape: SiteIconShape = .rounded { didSet { SiteIconShape.current = siteIconShape; LookState.shared.shape = siteIconShape; saveSetting("site_icon_shape", siteIconShape.rawValue) } }
    @Published var motionStyle: MotionStyle = .standard { didSet { MotionStyle.current = motionStyle; saveSetting("motion_style", motionStyle.rawValue) } }
    @Published var fasterDownloads = true { didSet { saveSetting("download_segments", fasterDownloads ? "1" : "0"); engine.downloads.segmentedEnabled = fasterDownloads } }
    @Published var organizeByDomain = false { didSet { saveSetting("organize_downloads_domain", organizeByDomain ? "1" : "0"); engine.downloads.organizeByDomain = organizeByDomain } }
    @Published var notifyDownloads = true { didSet { saveSetting("download_notify", notifyDownloads ? "1" : "0") } }
    @Published var duplicatePolicy = DuplicatePolicy.keepBoth { didSet { saveSetting("download_duplicate", duplicatePolicy.rawValue); engine.downloads.duplicatePolicy = duplicatePolicy } }
    /// A template that is not valid is kept as typed (so it can be fixed) but not used: downloads keep the name the site gave.
    @Published var downloadNameTemplate = "{name}" { didSet {
        saveSetting("download_template", downloadNameTemplate)
        engine.downloads.nameTemplate = DownloadCoordinator.templateProblem(downloadNameTemplate) == nil ? downloadNameTemplate : "{name}"
    } }
    @Published var organizeDownloads = false { didSet { saveSetting("organize_downloads", organizeDownloads ? "1" : "0"); engine.downloads.organize = organizeDownloads } }
    @Published var userScripts: [UserScript] = []
    /// The values scripts that were given storage keep for themselves, by script: kept in the profile, never shown to pages.
    var userScriptValues: [String: [String: String]] = [:]
    let userScriptStorage = UserScriptStorage()
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
    @Published private(set) var securityEvents: [SecurityEvent] = []
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
        // A blank field means "unchanged" while a user name is set; the password is removed only when the user name is cleared.
        if !password.isEmpty || config.username.isEmpty { ProxyConfig.setPassword(password) }
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
    /// The SearXNG instance this profile uses, and whether it is asked for suggestions (off until asked for).
    @Published var searxngInstance = "" { didSet { saveSetting("searxng_instance", searxngInstance) } }
    @Published var searxngSuggestions = false { didSet { saveSetting("searxng_suggest", searxngSuggestions ? "1" : "0"); refreshSearXNGSuggestions() } }
    @Published var searchSuggestionsEnabled = false { didSet { saveSetting("search_suggestions", searchSuggestionsEnabled ? "1" : "0") } }

    // MARK: Lifecycle

    var hasStarted = false
    /// While the first tab opens at launch, the address bar is not opened for typing: the window should simply appear.
    private var openingFirstTab = false
    private var pendingIncoming: [URL] = []

    /// A link handed to the browser by another app (when it is the default browser) or by the system. Opens in a new tab; one that
    /// arrives before the browser has finished starting waits for it.
    func openIncoming(_ url: URL) {
        if url.isFileURL { if url.pathExtension.lowercased() == "torrent" { openDocument(url) }; return }          // a .torrent opened from Finder; no other file is taken this way
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return }
        guard hasStarted else { pendingIncoming.append(url); return }
        _ = openTab(url: url, isPrivate: false)
    }

    func start() async {
        await engine.prepare()
        ensureWorkspaceIDs()
        // The small built-in rules are compiled and attached before any tab exists, so the first request is already filtered. The big
        // downloaded lists take far longer to compile, so they are added in the background and never hold up the window.
        await privacy.apply(includeDownloaded: false)
        #if DEBUG && os(iOS)
        if let page = ProcessInfo.processInfo.environment["BS_OPEN_URL"], let url = URL(string: page) { Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(1)); self?.openTab(url: url, isPrivate: false) } }
        if ProcessInfo.processInfo.environment["BS_SKIP_SETUP"] == "1" { Task { @MainActor [weak self] in for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(400)); self?.showSetup = false } } }
        // Development only: open the player on the page and run every control in turn against it, logging what the player reports after each.
        if ProcessInfo.processInfo.environment["BS_PLAYER_TEST"] == "1" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(12))
                self.showPlayer()
                try? await Task.sleep(for: .seconds(2))
                @MainActor func describe(_ v: DetectedVideo?) -> String {
                    guard let v else { return "no player" }
                    return "t=\(String(format: "%.2f", v.time)) paused=\(v.paused) rate=\(v.rate) loop=\(v.loops) seek=\(v.seekStart ?? -1)...\(v.seekEnd ?? -1) buffered=\(v.bufferedEnd ?? -1) tracks=\(v.tracks.map(\.showing)) chapters=\(v.chapters.map(\.title)) theater=\(v.theater) focus=\(v.focus) fit=\(v.fit) picture=\(String(describing: v.picture)) ab=\(String(describing: v.repeatA))-\(String(describing: v.repeatB)) size=\(v.width)x\(v.height) visible=\(v.visible) canSeek=\(v.canSeek)"
                }
                await self.refreshPlayers()
                debugLog("PLAYER start: \(describe(self.player.current))")
                @MainActor func step(_ name: String, _ action: String, _ value: Double = 0, wait: Double = 1.2) async {
                    guard let id = self.player.current?.id else { debugLog("PLAYER \(name): no player"); return }
                    let problem = await self.active?.engine.controlVideo(id: id, action: action, value: value)
                    try? await Task.sleep(for: .seconds(wait))
                    await self.refreshPlayers()
                    debugLog("PLAYER \(name): problem=\(problem ?? "none") -> \(describe(self.player.current))")
                }
                await step("play", "play", wait: 3)
                await step("pause", "pause")
                await step("seekBy +10", "seekBy", 10)
                let before = self.player.current?.time ?? 0
                await step("frame +1", "frame", 1)
                debugLog("PLAYER frame delta = \((self.player.current?.time ?? 0) - before) s")
                await step("speedBy +0.25", "speedBy", 0.25)
                await step("subtitle 0", "subtitle", 0)
                await step("subtitleShift +0.5", "subtitleShift", 0.5)
                await step("audioTrack 1", "audioTrack", 1)
                await step("markA", "markA")
                await step("seekBy +3", "seekBy", 3)
                await step("markB", "markB")
                await step("play (repeat A-B)", "play", wait: 6)
                await step("after repeat", "pause", wait: 0.5)
                await step("clearAB", "clearAB")
                await step("loop on", "loop", 1)
                await step("fit cover", "fit", 1)
                await step("picture contrast", "adjust:contrast", 0.2)
                await step("focus on", "focus", 1, wait: 6)
                await step("focus off", "focus", 0)
                await step("theater on", "theater", 1, wait: 6)
                await step("theater off", "theater", 0)
                if let v = self.player.current {
                    let lines = await self.loadTranscript(v)
                    debugLog("PLAYER transcript: \(lines?.lines.count ?? -1) lines, first=\(lines?.lines.first?.text ?? "-")")
                    self.captureFrame(v)
                    try? await Task.sleep(for: .seconds(1.5))
                    debugLog("PLAYER capture notice: \(self.notice ?? "none")")
                }
                debugLog("PLAYER done")
            }
        }
        if ProcessInfo.processInfo.environment["BS_SPEED"] == "1" { showSpeedPill = true }
        if let theme = ProcessInfo.processInfo.environment["BS_THEME"] { themeID = theme }
        if let page = ProcessInfo.processInfo.environment["BS_GLANCE"], let url = URL(string: page) { Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(6)); if let self, let tab = self.active { self.glance.present(url, from: tab) } } }
        if ProcessInfo.processInfo.environment["BS_TREE"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.tabTree = true
                let a = self.openTab(url: URL(string: "https://example.com/"), isPrivate: false)
                let b = self.openTab(url: URL(string: "https://example.org/"), isPrivate: false, select: false, opener: a)
                _ = self.openTab(url: URL(string: "https://example.net/"), isPrivate: false, select: false, opener: b)
                _ = self.openTab(url: URL(string: "https://www.iana.org/"), isPrivate: false, select: false, opener: a)
            }
        }
        if ProcessInfo.processInfo.environment["BS_SCROLL_END"] == "1" { Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(9)); _ = await self?.active?.engine.runScratch("window.scrollTo(0, document.documentElement.scrollHeight)") } }
        if let dark = ProcessInfo.processInfo.environment["BS_DARK"], let mode = DarkPages(rawValue: dark) { darkPages = mode }
        if ProcessInfo.processInfo.environment["BS_FOLD"] == "1" { Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(6)); self?.chromeCollapsed = true } }
        // Development only: look at the Customize card and the vertical tabs panel without touching the screen.
        if ProcessInfo.processInfo.environment["BS_START_DRAWER"] == "1" { Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(3)); self?.startDrawerOpen = true } }
        if ProcessInfo.processInfo.environment["BS_TABS_PANEL"] == "1" { Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            _ = self?.openTab(url: URL(string: "https://example.com/"), isPrivate: false); _ = self?.openTab(url: URL(string: "https://www.iana.org/"), isPrivate: false)
            self?.phoneTabsView = ProcessInfo.processInfo.environment["BS_TABS_MODE"] == "sidebar" ? .sidebar : .vertical
            try? await Task.sleep(for: .seconds(2)); if ProcessInfo.processInfo.environment["BS_TABS_OPEN"] != "0" { self?.openTabsView() } } }
        #endif
        #if DEBUG && os(macOS)
        // Development only, for looking at the start page: a picture, its look and its darkening, given on the command line (run with a throwaway -UITestRoot).
        let environment = ProcessInfo.processInfo.environment
        if environment["BS_SKIP_SETUP"] == "1" {
            saveSetting("setup_done", "1")
            Task { @MainActor [weak self] in for _ in 0..<8 { self?.showSetup = false; try? await Task.sleep(for: .milliseconds(400)) } }
        }
        if let photo = environment["BS_START_PHOTO"] { setStartImage(from: URL(fileURLWithPath: photo)) }
        if let look = environment["BS_START_LOOK"] { startLook = StartLook.decode(look) }
        if let name = environment["BS_APPEARANCE"] { NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua) }
        if let id = environment["BS_START_PRESET"] {
            startPreset = StartPreset.named(id).id
            startBackground = .preset
            startAnimatedGradient = environment["BS_START_DRIFT"] == "1"
        }
        // "path:dark,path:light,path" (tags optional): the pictures go into the collection in that order; BS_START_ROTATION picks off, everyTab, hourly or daily.
        if let list = environment["BS_START_COLLECTION"] {
            for part in list.split(separator: ",") {
                let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
                addWallpaper(from: URL(fileURLWithPath: pieces[0]), appearance: pieces.count > 1 ? (WallpaperAppearance(rawValue: pieces[1]) ?? .any) : .any)
            }
            if let rotation = environment["BS_START_ROTATION"].flatMap(WallpaperRotation.init(rawValue:)) { wallpaperLibrary.rotation = rotation }
            wallpaperLibrary.shuffle = environment["BS_START_SHUFFLE"] == "1"
        }
        if let video = environment["BS_START_VIDEO"] { Task { @MainActor [weak self] in await self?.setStartVideo(from: URL(fileURLWithPath: video)) } }
        // Development only, for checking lifecycles on the real app (read the result in the app's temporary folder, wallpaper-debug.log):
        // hide = leave the start page at 8 s and come back at 16 s; tabs = open three more start pages; appearance = switch light and dark; resize = change the window's size.
        // Development only, for looking at the first-run screens: light chosen, and the window's size (BS_WINDOW_SIZE=900x700).
        if environment["BS_SETUP_LIGHT"] == "1" { appearance = .light }
        if let name = environment["BS_LAYOUT"], let preset = LayoutPreset(rawValue: name) { layoutPreset = preset }          // to look at one layout's picture in the assistant
        if let size = environment["BS_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                if let window = NSApp.windows.first(where: { $0.isVisible }) { window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: size[0], height: size[1]), display: true, animate: false) }
            }
        }
        if let scenario = environment["BS_SCENARIO"] {
            Task { @MainActor [weak self] in
                guard let self else { return }
                WallpaperDebug.log("scenario \(scenario) begins")
                switch scenario {
                case "hide":
                    try? await Task.sleep(for: .seconds(8)); WallpaperDebug.log("scenario: leaving the start page"); self.open(urlString: "http://127.0.0.1:9/")
                    try? await Task.sleep(for: .seconds(8)); WallpaperDebug.log("scenario: new tab"); _ = self.newTab()
                case "windows":
                    for n in 1...2 { try? await Task.sleep(for: .seconds(4)); WallpaperDebug.log("scenario: new window \(n)"); self.windows.onNeedWindow?() }
                    try? await Task.sleep(for: .seconds(4))
                case "tabs":
                    for n in 1...3 { try? await Task.sleep(for: .seconds(3)); WallpaperDebug.log("scenario: new tab \(n)"); _ = self.newTab() }
                case "appearance":
                    for name in ["light", "dark", "light", "dark"] { try? await Task.sleep(for: .seconds(3)); WallpaperDebug.log("scenario: \(name)"); NSApp.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua) }
                case "resize":
                    for (w, h) in [(1200.0, 800.0), (1710.0, 1074.0), (900.0, 700.0), (1500.0, 950.0), (1710.0, 1074.0)] {
                        try? await Task.sleep(for: .seconds(2)); WallpaperDebug.log("scenario: resize \(Int(w))x\(Int(h))")
                        if let window = NSApp.windows.first(where: { $0.isVisible }) { window.setFrame(NSRect(x: window.frame.minX, y: window.frame.minY, width: w, height: h), display: true, animate: false) }
                    }
                default: break
                }
                WallpaperDebug.log("scenario \(scenario) ends")
            }
        }
        if let raw = environment["BS_SHOW_ERROR"], let kind = BrowserErrorKind(rawValue: raw) {
            Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(3)); self?.active?.debugShowError(kind) }
        }
        if environment["BS_OPEN_TOOLS"] == "1" {
            Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(9)); self?.sheet = .pageTools }
        }
        // Development only: open Settings the way a search result does (BS_SETTINGS_FIND="memory saver"): the pane, scrolled to the section.
        if let find = environment["BS_SETTINGS_FIND"], let entry = SettingsIndex.search(find).first {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.settingsReveal = SettingsIndex.macSection(for: entry).map { SettingsReveal(section: $0) }
                SettingsRouter.open(SettingsPanel(rawValue: entry.mac))
            }
        }
        if let raw = environment["BS_SETTINGS"] {
            Task { @MainActor in try? await Task.sleep(for: .seconds(3)); SettingsRouter.open(SettingsPanel(rawValue: raw)) }
        }
        if let page = environment["BS_OPEN"] {
            Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(3)); self?.open(urlString: page) }
        }
        if environment["BS_START_DRAWER"] == "1" { Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(3)); self?.startDrawerOpen = true } }
        if let dim = environment["BS_START_DIM"].flatMap(Double.init) { startImageDim = dim }
        #endif
        // Pieces left behind by a multi-part download that was cut off, a day or more ago, are cleared away.
        Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(20)); self?.engine.downloads.removeStalePieceFolders() }
        await privacy.settle()            // an earlier scheduled change must not leave the state half-applied
        expirePermissions()
        expireTemporaryPermissions(atStart: true)
        IntentInbox.attach { [weak self] in self?.workbench.handle($0) }
        downloads.profileName = profileName
        downloads.store = profileFolder.appendingPathComponent("downloads", isDirectory: true)
        pushWebPolicy()
        await engine.policyRulesReady()      // the first page already meets the extra blocking rules (home network, Google, social)
        if persistsProfileChoice {
            let unfinished = LaunchGuard.begin(root: root)
            safeStart = LaunchGuard.isLoop(unfinishedLaunches: unfinished)
            DiagLog.folder = URL(fileURLWithPath: root)
            if unfinished > 0 { ReliabilityStats.shared.noteUnexpectedTermination() }
            DiagLog.record("launch", safeStart ? "Started in safe mode after repeated crashes." : "Started.")
            loadCheckpoints()
            let folder = root
            Task { try? await Task.sleep(for: .seconds(15)); LaunchGuard.markHealthy(root: folder) }
        }
        await applyClearOnQuit()
        await runStartupDeleteRules()
        openingFirstTab = true
        restoreOrOpenFirstTab()
        openingFirstTab = false
        glance.closeLeftovers()          // a preview that was open when the app quit is not brought back
        mergeGroupNamesFromTabs()        // groups saved before groups belonged to workspaces are placed, whichever way the browser started
        if !isSecondary, let id = workbench.startupWorkflow, let flow = workbench.workflows.first(where: { $0.id == id }) { workbench.run(flow, source: "at start") }
        if !isSecondary { windows.loadPendingRestores(from: self) }
        #if DEBUG
        // For taking screenshots of a debug build: `-ShotSheet workbench -ShotPart Network` opens that screen after start-up.
        if let name = UserDefaults.standard.string(forKey: "ShotSheet"), let wanted = Sheet(rawValue: name) {
            Task { @MainActor [weak self] in try? await Task.sleep(for: .seconds(2.5)); self?.sheet = wanted }
        }
        #endif
        closeLeftoverScratchTabs()
        Task { await removeLeftoverTemporaryProfiles() }
        applyHistoryRetention()
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
        // Debug only: `-UIPhonePreset dock|bottomBar|topBar|reading` puts the iPhone into that layout at start, for looking at each one on a device.
        if let name = UserDefaults.standard.string(forKey: "UIPhonePreset"), let preset = PhonePreset(stored: name) { phonePreset = preset }
        if UserDefaults.standard.bool(forKey: "UIFolded") { foldChrome() }
        // Debug only: `-UIDownloadsScratch YES` sends this run's downloads to a scratch folder, never the person's own Downloads folder (for looking at real websites).
        if let name = UserDefaults.standard.string(forKey: "UIDownloadsScratch"), !name.isEmpty, !name.contains("/") {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ui-scratch-downloads", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCoordinator.directoryOverride = scratch
        }
        guard let state = UserDefaults.standard.string(forKey: "UIState") else { return }
        let base = "http://127.0.0.1:18765"
        switch state {
        case "none": break
        // Debug only, for looking at the newer panels with a screenshot of the window: each opens one thing after the window is up.
        case "guest-window":
            try? await Task.sleep(for: .seconds(1.5)); openGuestWindow()
        case let name where name.hasPrefix("sheet-"):
            // "sheet-<name>" opens any sheet by its name (the ones that need data of their own, a screenshot or a PDF, are not reachable this way).
            try? await Task.sleep(for: .seconds(1.5))
            if let wanted = Sheet(rawValue: String(name.dropFirst("sheet-".count))) { sheet = wanted }
        case "pagetools":
            try? await Task.sleep(for: .seconds(1.5)); sheet = .pageTools
        case "private-window":
            try? await Task.sleep(for: .seconds(1.5)); openPrivateWindow()
        case "private-choice":
            try? await Task.sleep(for: .seconds(1.5)); privateOpenMode = .ask; newPrivate()
        case "floating-player":
            try? await Task.sleep(for: .seconds(1.5)); openFloatingPlayer()
        case "private-window-busy":
            // A private window that has a download "running" (a record, not a transfer), beside one of another private session and an ordinary one, to see the close question and what it cancels.
            try? await Task.sleep(for: .seconds(1.5)); openPrivateWindow()
            try? await Task.sleep(for: .seconds(2.5))
            if let privateModel = windows.all.first(where: { $0.isPrivateWindow }) {
                func running(_ name: String, session: UUID?, priv: Bool) {
                    let id = downloads.ledger.create(protocolID: .webKit, source: URL(string: "https://example.test/\(name)"), filename: name, isPrivate: priv).id
                    downloads.ledger.update(id) { $0.privateSession = session }
                    for e in [DownloadEvent.queued, .started, .running] { _ = downloads.ledger.apply(e, to: id) }
                }
                running("mine.bin", session: privateModel.privateSessionID, priv: true)
                running("other-private.bin", session: UUID(), priv: true)
                running("ordinary.bin", session: nil, priv: false)
                // What each one is doing, once a second, for the check to read afterwards.
                let path = NSTemporaryDirectory() + "bs-close-check.txt"
                while true {
                    let lines = downloads.ledger.records.values.map { "\($0.file.filename)=\($0.state)" }.sorted().joined(separator: "\n")
                    try? lines.write(toFile: path, atomically: true, encoding: .utf8)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
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
        case "downloads":
            // Debug only, with a throwaway -UITestRoot: the Downloads window open, filled by real downloads from the local download fixture server (port 18766).
            let fixture = "http://127.0.0.1:18766"
            // Never into the person's own Downloads folder.
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ui-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCoordinator.directoryOverride = scratch
            for path in ["/file/2000000", "/file/350000", "/status/404"] { if let url = URL(string: fixture + path) { downloads.scheduleDownload(url: url, at: Date()) } }
            for i in 0..<6 { if let url = URL(string: fixture + "/throttle/\(8 << 20)?bps=150000&n=\(i)") { downloads.scheduleDownload(url: url, at: Date()) } }
            try? await Task.sleep(for: .seconds(4))
            sheet = .downloads
        case "provider-page":
            // Debug only, with -ProviderFixture: the fixture's Vimeo-shaped page open in the first tab, and downloads going to a scratch folder (never the person's own Downloads folder).
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("bs-ui-provider-downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            DownloadCoordinator.directoryOverride = scratch
            try? await Task.sleep(for: .seconds(1.5))                        // the first tab's web view is up
            if let base = ProviderFixtureMode.base, let url = URL(string: base.absoluteString + "/media/vimeo/page.html?v=123456") { active?.load(url) }
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

    #if DEBUG && os(macOS)
    /// Development only (BS_SEED_TABS=N, with BS_BENCH=1 to log): writes a session of N tabs into the profile before it is restored, so restoring many tabs can be measured.
    private func benchSeedSession() {
        guard let count = ProcessInfo.processInfo.environment["BS_SEED_TABS"].flatMap(Int.init), count > 0 else { return }
        var first: UInt64?
        for i in 0..<count {
            let info = core.createTab(url: "http://127.0.0.1:18900/ok?i=\(i)", private: false)
            if first == nil { first = info.id }
        }
        try? core.saveSession(activeTabId: first ?? 0)
        WallpaperDebug.log("BENCH seeded \(count) tabs")
    }
    private func benchReport(_ label: String, since start: CFAbsoluteTime) {
        guard ProcessInfo.processInfo.environment["BS_BENCH"] == "1" else { return }
        let live = (engine as? WebKitEngine)?.liveTabCount ?? -1
        WallpaperDebug.log(String(format: "BENCH %@ tabs=%d webviews=%d elapsed=%.0f ms footprint=%.1f MB", label, tabs.count, live, (CFAbsoluteTimeGetCurrent() - start) * 1000, Double(currentMemoryFootprint()) / 1_048_576))
    }
    #endif

    private func restoreOrOpenFirstTab() {
        #if DEBUG && os(macOS)
        benchSeedSession()
        let benchStart = CFAbsoluteTimeGetCurrent()
        benchReport("restore-begin", since: benchStart)
        defer {
            benchReport("restore-end", since: benchStart)
            if ProcessInfo.processInfo.environment["BS_BENCH"] == "1" {
                Task { @MainActor [weak self] in
                    for seconds in [3.0, 8.0] {
                        try? await Task.sleep(for: .seconds(seconds == 3 ? 3 : 5))
                        self?.benchReport("after-\(Int(seconds))s loading=\(self?.active?.isLoading ?? false)", since: benchStart)
                    }
                }
            }
        }
        #endif
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
            // An Essential's page was in front: the workspace in front is the one the browser last used, not one the Essential belongs to.
            if !isEssentialTab(target) {
                activeGroup = target.group
                activeWorkspace = target.workspace
            }
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
        Task { await FaviconStore.shared.flush() }
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

    func openTab(url: URL?, isPrivate requestedPrivate: Bool, select makeActive: Bool = true, opener: TabController? = nil, container: String? = nil, scratch: Bool = false, essential: String? = nil) -> TabController {
        FrameMonitor.mark("Opening new tab", for: 2)
        let isPrivate = requestedPrivate || isGuest || isPrivateWindow
        let info = core.createTab(url: "about:blank", private: isPrivate)
        // Written down before the tab exists: its engine reads the container to choose where the page keeps its data.
        var meta = TabMeta()
        if !isPrivate { meta.container = container; meta.scratch = scratch ? true : nil; meta.parent = opener?.id; meta.essential = essential }
        if !meta.isEmpty { tabMeta[info.id] = meta; saveTabMeta() }
        let tab = TabController(info: info, model: self)
        // An Essential's page belongs to no workspace and no group: it is shown with the Essentials wherever the person is.
        if !activeWorkspace.isEmpty, essential == nil {
            try? core.setTabWorkspace(tabId: tab.id, workspace: activeWorkspace)
            tab.workspace = activeWorkspace
        }
        if !activeGroup.isEmpty, !isPrivate, essential == nil {
            try? core.setTabGroup(tabId: tab.id, group: activeGroup)
            tab.group = activeGroup
        }
        tabs.append(tab)
        placeAfterOpener(tab)
        placeNextToOpener(tab, opener: opener, foreground: makeActive)
        if !isPrivate { extensionCenter.tabOpened(tab) }
        if separatesPrivate { privateMode = isPrivate }
        if makeActive { select(tab.id) }
        // Closing it before looking at anything else goes back to the page it was opened from.
        if makeActive, let opener { closeReturn[tab.id] = opener.id }
        if let url { tab.load(url) }
        else if makeActive && !openingFirstTab {
            #if os(macOS)
            startFocusTick += 1      // the blank tab shows its own search field; the toolbar's keeps its focus for ⌘L
            #else
            // The keyboard comes up only for a blank page, where typing is the next thing to do. The Home page, a custom page and a private tab show
            // their own content, and a swipe past the last tab makes one of these: the keyboard covering it was not asked for.
            if newTabMode == .blank, !isPrivate { focusAddressBar() }
            #endif
        }
        saveSoon()
        return tab
    }

    /// New blank tab in the current group (and private set on iOS).
    @discardableResult
    func newTab() -> TabController {
        Haptics.tap()
        let tab = openTab(url: nil, isPrivate: separatesPrivate ? privateMode : false)
        // Private tabs keep their own page whatever the choice. Otherwise: an address of your choice, or an empty page with the address bar ready.
        if !tab.isPrivate {
            let custom = newTabMode == .custom ? NewTabMode.customURL(from: newTabURL) : nil
            if let custom { tab.load(custom) }
            // The phone's keyboard is decided in openTab; the Mac focuses the toolbar's address field here.
            #if os(macOS)
            if custom != nil || newTabMode == .blank { focusAddressBar() }
            #endif
        }
        return tab
    }

    func select(_ id: UInt64) {
        Perf.measure("Select tab") { selectTab(id: id) }
    }

    /// Tabs by when they were last in front (Control-Tab walks back through them).
    private var recency = TabRecency()
    private var recencyWalkEnd: Task<Void, Never>?

    /// The next more recently used tab (Control-Tab, `direction` 1: one further back; Control-Shift-Tab, -1: forward again). Only tabs this window shows are chosen, so a private
    /// tab is never reached from a normal window or the other way round. Presses close together make one walk; the tab it stops on becomes the most recent.
    func cycleRecentTab(_ direction: Int) {
        guard let target = recency.step(direction, current: activeID, available: visibleTabs.map(\.id)) else { return }
        recencyFrozen = true
        select(target)
        recencyFrozen = false
        recencyWalkEnd?.cancel()
        recencyWalkEnd = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(TabRecency.walkWindow * 1000) + 100))
            guard !Task.isCancelled, let self else { return }
            self.recency.endWalk(on: self.activeID)
        }
    }
    private var recencyFrozen = false

    /// Hide the separate tab strip while there is only one tab and the person asked for that.
    var stripHiddenForSingleTab: Bool { hideSingleTabStrip && effectiveTabLayout == .separate && !singleRow && visibleTabs.count <= 1 }

    private func selectTab(id: UInt64) {
        FrameMonitor.mark("Switching tab")
        // Choosing any other tab ends a Glance preview (one that is promoted selects its own tab after it has stopped being a preview).
        if let preview = glance.session, preview.tabID != id { glance.dismiss(animated: false) }
        if let previous = active, previous.id != id {
            closeReturn[previous.id] = nil
            previous.lastActive = Date()
            Task { await previous.captureSnapshot() }
            // Chat pages scroll inside their own list; remember where, so coming back does not leave you at the first message.
            if !previous.isDiscarded, !previous.isBlank { Task { await previous.engine.saveScrollState() } }
        }
        let previousTab = active
        if previousTab?.id != id { Haptics.selection() }
        expandChrome()
        activeID = id
        if !recencyFrozen { recency.noteSelected(id) }
        if let tab = active { activeFixedTop = tab.fixedTop; activeFixedBottom = tab.fixedBottom }
        // A pinned tab set to start over when its workspace was left goes back to its pinned address now, before its page is brought back, so it loads once.
        if pendingPinnedResets.remove(id) != nil, let tab = active { resetPinnedTab(tab, becauseOfWorkspaceSwitch: true) }
        active?.ensureLoaded()
        if let shown = active, shown.id != previousTab?.id, shown.hasLoadedPage, !shown.isDiscarded { shown.engine.restoreScrollState() }
        if let current = active, !current.isPrivate { extensionCenter.tabActivated(current, previous: previousTab.flatMap { $0.isPrivate ? nil : $0 }) }
        // An Essential is shown in whichever workspace is in front; opening one never moves the person to another workspace.
        if let tab = active, !isEssentialTab(tab) {
            if tab.workspace != activeWorkspace { activeWorkspace = tab.workspace }
            if tab.group != activeGroup { activeGroup = tab.group }
        }
        if separatesPrivate, let tab = active { privateMode = tab.isPrivate }
        refreshBookmarkState()
        // A navigation/tab update must not replace the user's in-progress address edit.
        // Escape restores the newly selected tab's address; Return submits to that tab.
        saveSoon()
    }

    /// Closes every tab in this view (this workspace and group), pinned ones too, and leaves one fresh tab.
    func closeAllTabs() {
        bulkClosing = true
        defer { bulkClosing = false }
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
        if !force, needsPinnedConfirmation(id) { confirmClosePinned(id); return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        // A preview does not outlive the page it was opened from.
        if glance.session?.sourceID == id { glance.dismiss(animated: false) }
        // Closing an Essential's page lets go of it but keeps the Essential (a forced close, such as quitting or deleting its container, really closes it).
        if !force, closeEssentialTabSoftly(tabs[index]) { return }
        let wasActive = id == activeID
        // Which tab comes forward is decided from the strip as it is now (what the person sees), before the tab leaves it.
        let comeForward = tabToShowAfterClosing(id)
        forgetReturns(involving: id)
        adoptChildren(ofClosing: id)
        let closing = tabs.remove(at: index)
        if !closing.isPrivate { extensionCenter.tabClosed(closing) }
        // Private and scratch tabs are never remembered; blank tabs have nothing to reopen.
        if !closing.isPrivate, tabMeta[id]?.scratch != true, tabMeta[id]?.essential == nil, closing.workspace != GlanceCoordinator.hiddenWorkspace, !closing.isBlank, let url = closing.url {
            closedTabs.append(ClosedTab(url: url, title: closing.title, group: closing.group, workspace: closing.workspace))
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        forgetSplitPanel(id)
        if tabMeta[id] != nil { tabMeta[id] = nil; saveTabMeta() }
        let closedHost = closing.url?.host
        closing.shutdown()
        try? core.closeTab(tabId: id)
        if !closing.isPrivate { siteTabClosed(host: closedHost) }
        // (A private window's storage is its own and goes with the window; it never ends, or keeps alive, the one ordinary windows' private tabs share.)
        if !isPrivateWindow, !tabs.contains(where: \.isPrivate), !windows.anotherWindowHasPrivateTabs(besides: self) { engine.privateSessionEnded() }
        if wasActive || active == nil {
            if let target = comeForward, tabs.contains(where: { $0.id == target }) {
                select(target)
            } else if let next = visibleTabs.first ?? tabs.first {
                select(next.id)
            } else if isSecondary {
                activeID = nil
                onWindowShouldClose?()       // a window with no tab left closes; the first window always keeps one
            } else {
                newTab()    // the window keeps a blank tab, so opening the app again finds something to show
                if closeWindowWithLastTab, !bulkClosing { closeFrontWindow() }
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
        closeInBulk(visibleTabs.filter { $0.id != id && !$0.pinned }, reason: "Before closing other tabs")
    }

    /// The one place that closes several tabs for the person: a restore point first when there are many, then each tab through the ordinary close (so locked
    /// tabs, Essentials and the next-tab choice behave as they do for a single tab).
    func closeInBulk(_ doomed: [TabController], reason: String) {
        if doomed.count > 5 { takeCheckpoint(reason: reason, force: true) }
        // Closing many at once is not "closing the last tab": the window stays, with a fresh tab if none is left.
        bulkClosing = true
        defer { bulkClosing = false }
        for tab in doomed { closeTab(id: tab.id) }
    }

    /// True while several tabs are being closed together on the person's behalf.
    private var bulkClosing: Bool {
        get { bulkClosingDepth > 0 }
        set { bulkClosingDepth = max(0, bulkClosingDepth + (newValue ? 1 : -1)) }
    }

    /// The tabs a "Close Tabs Above/Below" would close, as they are listed now. Pinned and locked tabs stay.
    func tabsToClose(above id: UInt64, wantAbove: Bool) -> [TabController] {
        let list = visibleTabs
        guard let index = list.firstIndex(where: { $0.id == id }) else { return [] }
        let side = wantAbove ? list[..<index] : list[(index + 1)...]
        return side.filter { !$0.pinned && !lockedTabIDs.contains($0.id) }
    }

    func closeTabs(above id: UInt64, wantAbove: Bool) {
        closeInBulk(tabsToClose(above: id, wantAbove: wantAbove), reason: "Before closing tabs")
    }

    func duplicateTab(_ tab: TabController) {
        guard let url = tab.url, !tab.isBlank else { return }
        openTab(url: url, isPrivate: tab.isPrivate)
    }

    func selectAdjacent(_ offset: Int) {
        let list = visibleTabs
        guard !list.isEmpty else { return }
        // An Essential's page is in no list: from it, next goes to the first tab and previous to the last, so the keys never get stuck there.
        guard let current = list.firstIndex(where: { $0.id == activeID }) else {
            select((offset >= 0 ? list[0] : list[list.count - 1]).id)
            return
        }
        select(list[(current + offset + list.count) % list.count].id)
    }

    /// A swipe on the address bar: the next or previous tab, the page sliding in from that side. Swiping forward from the last tab opens
    /// a new one, as in Safari; backward from the first does nothing.
    func swipeToTab(_ offset: Int) {
        let list = visibleTabs
        // From an Essential (in no list) a swipe forward goes to the first tab; backward has nowhere to go.
        guard let current = list.firstIndex(where: { $0.id == activeID }) else {
            if offset > 0, let first = list.first { tabSlide = offset; select(first.id); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.tabSlide = 0 } }
            return
        }
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
        if tab.pinned { registerPinnedAddress(for: tab) } else { forgetPinnedAddress(for: tab) }
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
        workspaces.append(Workspace(name: clean, icon: icon, preset: nil, uid: UUID().uuidString))
        saveWorkspaces()
    }

    /// Gives every workspace that has none its hidden identity, and saves them. Runs once the browser has started (settings are not written while they load).
    func ensureWorkspaceIDs() {
        var changed = false
        for index in workspaces.indices where workspaces[index].uid == nil {
            workspaces[index].uid = UUID().uuidString
            changed = true
        }
        if changed { saveWorkspaces() }
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
        // Everything that remembers the workspace by name follows it, in every window of the profile.
        for window in windows.all { window.followWorkspaceRename(from: old, to: clean) }
        if !windows.all.contains(where: { $0 === self }) { followWorkspaceRename(from: old, to: clean) }
        saveGroupNames()
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
        groupLists[name] = nil
        if activeWorkspace == name { switchWorkspace("") }
        mergeGroupNamesFromTabs()          // its tabs are in Personal now, and their groups are listed there
        saveWorkspaces()
        saveGroupNames()
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
        listedTabs(inWorkspace: name, includePrivate: false).count
    }

    // MARK: Dark pages and low power

    func shouldDarken(host: String?) -> Bool {
        guard let key = FaviconStore.key(forHost: host) else { return darkPages == .always }
        if darkSitesOff.contains(key) { return false }
        switch darkPages {
        case .off: return false
        case .always: return true
        case .chosen: return darkSites.contains(key)
        }
    }

    /// What one site is told: follow the setting, be dark, or never be touched.
    func darkChoice(forHost host: String?) -> DarkSiteChoice {
        guard let key = FaviconStore.key(forHost: host) else { return .automatic }
        if darkSitesOff.contains(key) { return .never }
        if darkSites.contains(key) { return .dark }
        return .automatic
    }

    func setDarkChoice(host: String?, _ choice: DarkSiteChoice) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        policyPushSuspended = true
        darkSites.remove(key)
        darkSitesOff.remove(key)
        switch choice {
        case .dark: darkSites.insert(key); if darkPages == .off { darkPages = .chosen }
        case .never: darkSitesOff.insert(key)
        case .automatic: break
        }
        saveDarkSites()
        policyPushSuspended = false
        pushWebPolicy()
        for tab in tabs where FaviconStore.key(forHost: tab.url?.host) == key { tab.applyDarkPages(live: true) }
    }

    /// The page-menu button: darkens this site if it is light now, or stops darkening it.
    func toggleDark(host: String?) {
        setDarkChoice(host: host, shouldDarken(host: host) ? .never : .dark)
    }

    private func saveDarkSites() {
        saveSetting("dark_sites", encodedMap(Dictionary(uniqueKeysWithValues: darkSites.map { ($0, true) })))
        saveSetting("dark_sites_off", encodedMap(Dictionary(uniqueKeysWithValues: darkSitesOff.map { ($0, true) })))
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
        setDarkChoice(host: host, .automatic)
        for tab in tabs where FaviconStore.key(forHost: tab.url?.host) == FaviconStore.key(forHost: host) { tab.applyDarkPages(live: true); tab.applyWebsiteAppearance() }
        notice = "This site’s appearance was reset."
    }

    func isDarkSite(_ host: String?) -> Bool { FaviconStore.key(forHost: host).map { darkSites.contains($0) } ?? false }

    /// Turns dark pages on or off for one site. Choosing a site while the setting is Off switches it to "only sites I choose".
    func setDarkSite(_ host: String?, _ on: Bool) {
        setDarkChoice(host: host, on ? .dark : .automatic)
    }

    /// The memory mode in force: Memory Saver while Low Power Mode is on, when the user allows it.
    var effectiveMemoryMode: MemoryMode { governor.effective.mode }

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

    func workspaceGradientMutate(_ index: Int, _ value: WorkspaceGradient?) {
        workspaces[index].gradient = value
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
    /// The split panels in the order they are drawn. It does not change when you click a panel: the clicked page becomes the active one, but it stays where it is.
    func orderedSplitPanels() -> [TabController] {
        let members = splitPanels
        let ids = members.map(\.id)
        guard ids.count > 1 else { splitDisplay = []; return members }
        var fresh = ids.filter { !splitDisplay.contains($0) }
        // A panel that went away is replaced, in its own place, by the one that took its turn.
        var order: [UInt64] = splitDisplay.compactMap { ids.contains($0) ? $0 : (fresh.isEmpty ? nil : fresh.removeFirst()) }
        order += fresh
        splitDisplay = order
        return order.compactMap { id in members.first { $0.id == id } }
    }

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
        if let problem = GroupPath.problem(clean) { notice = problem; return }
        groupNames.append(clean)
        saveGroupNames()
        if let tab { moveTab(tab, to: clean) }
    }

    func renameGroup(_ old: String, to new: String) {
        let clean = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 40, !groupNames.contains(clean),
              groupNames.contains(old) else { return }
        // A group's name is the front of every subgroup's name, so they follow it.
        func renamed(_ name: String) -> String { name == old ? clean : clean + name.dropFirst(old.count) }
        // A group cannot be moved inside itself, and the move may not make it, or anything inside it, deeper than the limit.
        if clean != old, GroupPath.isInside(clean, of: old) { notice = "A group cannot be moved inside itself."; return }
        if let problem = groupNames.filter({ GroupPath.isInside($0, of: old) }).compactMap({ GroupPath.problem(renamed($0)) }).first { notice = problem; return }
        groupNames = groupNames.map { GroupPath.isInside($0, of: old) ? renamed($0) : $0 }
        for tab in tabs where tab.workspace == activeWorkspace && GroupPath.isInside(tab.group, of: old) {
            tab.group = renamed(tab.group)
            try? core.setTabGroup(tabId: tab.id, group: tab.group)
        }
        if GroupPath.isInside(activeGroup, of: old) { activeGroup = renamed(activeGroup) }
        saveGroupNames()
        saveSoon()
    }

    /// Deleting a group keeps its tabs; they return to the ungrouped set.
    func deleteGroup(_ name: String) {
        for tab in tabs where tab.workspace == activeWorkspace && GroupPath.isInside(tab.group, of: name) {
            tab.group = ""
            try? core.setTabGroup(tabId: tab.id, group: "")
        }
        groupNames.removeAll { GroupPath.isInside($0, of: name) }
        if GroupPath.isInside(activeGroup, of: name) { selectGroup("") }
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
            if let next = visibleTabs.first(where: { $0.id != tab.id }) ?? listedTabs(inWorkspace: activeWorkspace).first(where: { $0.id != tab.id }) {
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

    /// The group on show holds its own tabs and, if it has subgroups, theirs. "All Tabs" (no group) holds only ungrouped tabs.
    func inActiveGroup(_ group: String) -> Bool {
        activeGroup.isEmpty ? group.isEmpty : GroupPath.isInside(group, of: activeGroup)
    }

    func createSubgroup(under parent: String, named name: String) {
        let leaf = name.replacingOccurrences(of: String(GroupPath.separator), with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !leaf.isEmpty else { return }
        createGroup(parent + String(GroupPath.separator) + leaf)
    }

    func tabCount(inGroup name: String) -> Int {
        listedTabs(inWorkspace: activeWorkspace).filter { (name.isEmpty ? $0.group.isEmpty : GroupPath.isInside($0.group, of: name)) && (!separatesPrivate || !$0.isPrivate) }.count
    }

    /// Makes sure every group a tab is in is listed in that tab's workspace, and places groups saved before groups belonged to workspaces: a group goes to the
    /// workspaces whose tabs use it, and one no tab uses goes to Personal.
    func mergeGroupNamesFromTabs() {
        var all = groupLists
        for tab in tabs where !tab.group.isEmpty && !isHiddenTab(tab) {
            var list = all[tab.workspace] ?? []
            if !list.contains(tab.group) { list.append(tab.group); all[tab.workspace] = list }
        }
        if !legacyGroupNames.isEmpty {
            for name in legacyGroupNames where !all.values.contains(where: { $0.contains(name) }) {
                all["", default: []].append(name)
            }
            legacyGroupNames = []
        }
        if all != groupLists { groupLists = all; saveGroupNames() }
    }

    func saveGroupNames() {
        saveSetting("tab_groups_v2", encodedMap(groupLists))
    }

    // MARK: Overview

    func showOverview() {
        FrameMonitor.mark("Opening tab overview")
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
        // An ftp://, ftps://, sftp:// or dav(s):// address is not a web page: it opens the Remote Files browser instead of a navigation WebKit cannot do.
        if RemoteScheme(urlScheme: URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme) != nil, RemoteConnection.from(address: input) != nil {
            openRemote(address: input.trimmingCharacters(in: .whitespacesAndNewlines), origin: .user, fromPrivate: active?.leavesNoTrace ?? false)
            return
        }
        // A magnet link typed or pasted into the address bar goes where a clicked one goes: a preview that asks before anything is fetched.
        let typedText = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if typedText.lowercased().hasPrefix("magnet:?"), typedText.count <= 8192 {
            // Not from a private tab: the download would be kept in the ordinary list (the same rule a clicked magnet link follows).
            if active?.leavesNoTrace == true { linkNotice = "Peer-to-peer links cannot be opened from a private tab. Open the link in an ordinary tab to preview it."; return }
            openLinkPreview(.preview(text: typedText)); return
        }
        if let typed = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), MetalinkLink.isMetalink(typed) { openMetalink(url: typed, origin: .user); return }
        guard let result = resolveInput(input: input, searchTemplate: activeSearchTemplate) else { return }
        let target: String
        switch result {
        case .url(let u), .search(let u): target = u
        }
        guard let url = URL(string: target) else { return }
        if offerPreferredProfile(for: url) { return }
        (active ?? openTab(url: nil, isPrivate: false)).load(url)
    }

    func open(urlString: String, newTab: Bool = false) {
        guard let url = URL(string: urlString) else { return }
        // (A suggestion for an ftp://, sftp:// or dav(s):// address goes to Remote Files like a typed one.)
        if RemoteScheme(urlScheme: url.scheme) != nil, RemoteConnection.from(address: urlString) != nil { openRemote(address: urlString, origin: .user, fromPrivate: active?.leavesNoTrace ?? false); sheet = nil; return }
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
        // What was typed is an ftp://, sftp:// or dav(s):// address: it opens Remote Files, whatever suggestion (a search, usually) happens to be selected beside it.
        let typedText = addressBar.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if suggestion.kind != .command, suggestion.kind != .openTab, RemoteScheme(urlScheme: URL(string: typedText)?.scheme) != nil, RemoteConnection.from(address: typedText) != nil {
            addressBar.isEditing = false; addressBar.clear()
            openRemote(address: typedText, origin: .user, fromPrivate: active?.leavesNoTrace ?? false)
            return
        }
        learnChoice(suggestion, typed: addressBar.text)
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

    /// Runs the memory policy now as if the system had asked for memory.
    func lifecycleRun() async { _ = await lifecycle?.run(.warning) }

    func recordPerf(_ name: String, millis: Double) {
        perfLog = PerfLog.add(PerfRecord(name: name, millis: millis), to: perfLog)
        saveSetting("perf_log", (try? String(data: JSONEncoder().encode(perfLog), encoding: .utf8)) ?? "[]")
    }

    func didFinishLoading(_ tab: TabController) {
        guard let url = tab.url else { return }
        // How long from opening the window to the first page being ready; kept to spot a launch that has become slower.
        if !recordedStartup, !isSecondary {
            recordedStartup = true
            recordPerf("startup-first-page", millis: Date().timeIntervalSince(launchedAt) * 1000)
        }
        // A scratch tab leaves no history and no saved address.
        // A page in a Glance preview is not a visit until it is promoted.
        if tabMeta[tab.id]?.scratch != true, !glance.isGlance(tab) { try? core.commitNavigation(tabId: tab.id, url: url.absoluteString, title: tab.title) }
        learnVisit(tab, url: url)
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

    /// Keeps a line about something the browser did for safety. Private tabs are never recorded.
    func recordSecurity(kind: String, site: String, detail: String, isPrivate: Bool = false) {
        guard !isPrivate else { return }
        securityEvents.insert(SecurityEvent(kind: kind, site: site, detail: detail), at: 0)
        if securityEvents.count > 200 { securityEvents.removeLast(securityEvents.count - 200) }
        saveSetting("security_events", (try? String(data: JSONEncoder().encode(securityEvents), encoding: .utf8)) ?? "[]")
    }

    func clearSecurityEvents() {
        securityEvents = []
        saveSetting("security_events", "[]")
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

    /// One saved setting of this profile, read without writing anything.
    func settingValue(_ key: String) -> String? { (try? core.getSetting(key: key)) ?? nil }

    /// Reads the profile's interface settings without writing them back.
    func loadUISettings() {
        applyingSettings = true
        defer { applyingSettings = false }
        func get(_ key: String) -> String? { (try? core.getSetting(key: key)) ?? nil }
        appearance = AppearanceMode(rawValue: get("appearance") ?? "") ?? .system
        tabLayout = TabLayout(rawValue: get("tab_layout") ?? "") ?? .separate
        if let data = get("phone_custom_layout")?.data(using: .utf8), let spec = try? JSONDecoder().decode(PhoneLayoutSpec.self, from: data) { phoneCustomSpec = spec }
        phonePreset = PhonePreset(stored: get("phone_preset") ?? "") ?? .bottomBar
        phoneTabsView = PhoneTabsView(rawValue: get("phone_tabs_view") ?? "") ?? .grid
        backToTopPill = get("back_to_top_pill") != "0"
        pageMenuExtras = get("page_menu_extras") != "0"
        autoScrollSpeed = min(max(Double(get("auto_scroll_speed") ?? "") ?? 90, 20), 400)
        resumeMedia = get("player_resume") == "1"
        loadMediaEntries(get("media_resume"))
        loadPlayerSiteSteps(get("player_site_steps"))
        loadPlayerSiteSubtitles(get("player_site_subtitles"))
        audioFocus = get("audio_focus") == "1"
        mediaBackgroundMinutes = [0, 10, 30, 60].contains(Int(get("media_background_minutes") ?? "") ?? 0) ? Int(get("media_background_minutes") ?? "") ?? 0 : 0
        playerSeekStep = [5.0, 10, 15, 30].contains(Double(get("player_seek_step") ?? "") ?? 0) ? Double(get("player_seek_step") ?? "10") ?? 10 : 10
        #if DEBUG && os(iOS)
        // Development only (not in a release build): open a chosen layout and a chosen page, so a screenshot shows exactly that.
        if let forced = ProcessInfo.processInfo.environment["BS_PHONE_PRESET"], let preset = PhonePreset(rawValue: forced) { phonePreset = preset }
        #endif
        layoutPreset = LayoutPreset(rawValue: get("layout_preset") ?? "") ?? .classic
        sidebarPosition = SidebarPosition(rawValue: get("sidebar_position") ?? "") ?? .left
        sidebarWidth = clampedSidebarWidth(Double(get("sidebar_width") ?? "") ?? 260)
        sidebarRail = get("sidebar_rail") == "1"
        sidebarAutoHide = get("sidebar_autohide") == "1"
        density = InterfaceDensity(rawValue: get("density") ?? "") ?? .comfortable
        accentChosen = get("accent_chosen") == "1"
        singleToolbarCustom = get("single_toolbar") == "1"
        toolbarAutoHide = get("toolbar_autohide") == "1"
        tintToolbar = get("tint_toolbar") != "0"
        collapseOnScroll = get("collapse_on_scroll") != "0"
        doubleClickAction = DoubleClickAction(rawValue: get("double_click") ?? "") ?? .cycleLayout
        // Off until the person turns it on: what is typed is not sent to a search engine as it is typed unless they choose that.
        searchSuggestionsEnabled = get("search_suggestions") == "1"
        searxngInstance = get("searxng_instance") ?? ""
        linkAskBeforeReceiving = get("link_ask") != "0"
        loadWebApps(get)
        searxngSuggestions = get("searxng_suggest") == "1"
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
        userScriptValues = Self.decodeMap(get("user_script_values"), as: [String: String].self)
        configureUserScriptStorage()
        engine.setUserScriptStorage(userScriptStorage)
        engine.setUserScripts(effectiveUserScripts)
        lockSensitiveSettings = get("lock_sensitive") == "1"
        siteNotes = Self.decodeMap(get("site_notes"), as: String.self)
        siteStyles = Self.decodeMap(get("site_styles"), as: String.self)
        customSearchShortcuts = Self.decodeMap(get("search_shortcuts"), as: String.self)
        bookmarkTags = Self.decodeMap(get("bookmark_tags"), as: [String].self)
        readingList = ReadingStore.loadIndex(root: profileFolder)
        organizeDownloads = get("organize_downloads") == "1"
        duplicatePolicy = DuplicatePolicy(rawValue: get("download_duplicate") ?? "") ?? .keepBoth
        automationEnabled = get("download_automation") == "1"
        interceptP2PLinks = get("link_p2p_intercept") != "0"
        watchClipboardForLinks = get("link_clipboard_watch") == "1"
        mediaPreferences = MediaPreferences(audioLanguage: get("media_pref_audio") ?? "", subtitleLanguage: get("media_pref_subs") ?? "")
        downloadNotifications = DownloadNotificationPreferences.decode(get("download_notifications")) ?? DownloadNotificationPreferences()
        startDownloadEvents()
        _ = packages                  // so a package finishing is announced whether or not its sheet was ever opened
        downloadNameTemplate = get("download_template") ?? "{name}"
        organizeByDomain = get("organize_downloads_domain") == "1"
        fasterDownloads = get("download_segments") != "0"
        motionStyle = MotionStyle(rawValue: get("motion_style") ?? "") ?? .standard
        iconWeight = IconWeight(rawValue: get("icon_weight") ?? "") ?? .regular
        trackTime = get("track_time") == "1"
        siteTimeRetentionDays = get("site_time_days").flatMap { Int($0) }.flatMap { SiteTimeLog.retentionChoices.contains($0) ? $0 : nil } ?? 90
        breakMinutes = [0, 20, 30, 45, 60].contains(Int(get("break_minutes") ?? "") ?? -1) ? Int(get("break_minutes")!)! : 0
        keepClipboardHistory = get("clipboard_history") == "1"
        backdropIntensity = BackdropIntensity(rawValue: get("backdrop_intensity") ?? "") ?? .medium
        siteIconShape = SiteIconShape(rawValue: get("site_icon_shape") ?? "") ?? .rounded
        siteLooks = Self.decodeMap(get("site_looks"), as: String.self)
        updateDownloadFolder()
        notifyDownloads = get("download_notify") != "0"
        maxDownloads = DownloadQueueRules.maxConcurrentChoices.contains(Int(get("download_concurrent") ?? "") ?? 0) ? Int(get("download_concurrent") ?? "")! : DownloadQueueRules.defaultConcurrent
        engine.downloads.profileName = profileName          // the proxy password is looked up under it
        _ = accountStore          // this profile's accounts (and no other's) are the ones the downloader consults
        downloadNetwork = DownloadNetworkSettings.decode(get("download_network"))
        torrentSettings = TorrentSettings.decode(get("download_torrent"))
        ed2kSettings = ED2KSettings.decode(get("download_ed2k"))
        tabSchedules = ((get("tab_schedules")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([TabSchedule].self, from: $0) }) ?? []
        protectPinned = get("protect_pinned") != "0"
        keepMediaHistory = get("media_history_on") != "0"
        loadReaderStyle()
        mediaHistory = ((get("media_history")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([MediaHistoryEntry].self, from: $0) }) ?? []
        securityEvents = ((get("security_events")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([SecurityEvent].self, from: $0) }) ?? []
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
        loadPinnedAddresses(get("pinned_addresses"))
        glanceEnabled = get("glance_enabled") != "0"
        glanceTrigger = GlanceTrigger(rawValue: get("glance_trigger") ?? "") ?? .option
        glanceTemporarySession = get("glance_temporary") == "1"
        learnSuggestions = get("learn_suggestions") != "0"
        suggestionExcludedHosts = Self.decodeMap(get("suggestion_excluded"), as: [String].self)["list"] ?? []
        spaceRequestsOpenNewWindow = get("space_request_new_window") == "1"
        clearIncludesSleeping = get("clear_includes_sleeping") != "0"
        clearTabsAsks = get("clear_tabs_asks") != "0"
        reloadEssentials()
        splitTemplates = Self.decodeMap(get("split_templates"), as: [SplitTemplate].self)["list"] ?? []
        lastSplit = Self.decodeMap(get("last_split"), as: [SplitTemplate].self)["list"]?.first
        tabTree = get("tab_tree") == "1"
        loadLoginSettings(get)
        spotlightBookmarks = get("spotlight_bookmarks") == "1"
        mouseGestures = get("mouse_gestures") == "1"
        mouseGestureMap = MouseGesture.decode(get("mouse_gesture_map"))
        syncPasswords = get("sync_passwords") == "1"
        syncLedger = Self.decodeMap(get("sync_ledger"), as: SyncState.self)["state"] ?? SyncState()
        if !syncLedger.logins.isEmpty { syncLedger = SyncLedgerGuard.rehydrated(syncLedger, current: Dictionary(WebLoginVault.list(profile: profileName).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), profile: profileName) }
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
        darkSitesOff = Set(Self.decodeMap(get("dark_sites_off"), as: Bool.self).filter(\.value).keys)
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
        customMemory = CustomMemoryPolicy(keepRecent: CustomMemoryPolicy.keepChoices.contains(Int(get("custom_keep") ?? "") ?? 0) ? Int(get("custom_keep")!)! : 5,
                                          idleMinutes: CustomMemoryPolicy.idleChoices.contains(Int(get("custom_idle") ?? "") ?? 0) ? Int(get("custom_idle")!)! : 15)
        batteryAware = get("battery_aware") != "0"
        referrerMode = ReferrerMode(rawValue: get("referrer_mode") ?? "") ?? .standard
        privateSearchID = get("private_search") ?? ""
        doubleClickClosesTab = get("double_click_closes_tab") == "1"
        hideTabCloseButtons = get("hide_tab_close") == "1"
        closeWindowWithLastTab = get("close_window_last_tab") == "1"
        globalPrivacyControl = get("gpc") != "0"
        blockLinkPings = get("block_link_pings") != "0"
        lockdownHosts = Set(Self.decodeMap(get("lockdown_hosts"), as: [String].self)["list"] ?? [])
        debounceLinks = get("debounce_links") != "0"
        redirectSkipOff = Set(Self.decodeMap(get("redirect_skip_off"), as: [String].self)["list"] ?? [])
        blockLocalNetwork = get("block_local_network") == "1"
        localNetworkAllowed = Set(Self.decodeMap(get("local_network_allowed"), as: [String].self)["list"] ?? [])
        blockGoogleServices = get("block_google_services") == "1"
        blockSocialWidgets = get("block_social_widgets") == "1"
        devCapture = get("dev_capture") == "1"
        perfLog = ((get("perf_log")?.data(using: .utf8)).flatMap { try? JSONDecoder().decode([PerfRecord].self, from: $0) }) ?? []
        keepPinnedTabs = get("keep_pinned") != "0"
        threatList = ThreatListStore.load(root: root)
        sidebarVisible = !sidebarAutoHide && resolveLayout(preset: layoutPreset, customTabLayout: tabLayout, customSidebarVisible: get("custom_sidebar") == "1", customSingleToolbar: singleToolbarCustom).sidebarVisible
        // An explicit pin choice wins over what the layout would do, and over auto-hide.
        switch get("sidebar_pinned") {
        case "1": sidebarPinChoice = true; if layoutPreset == .sidebar { sidebarAutoHide = false; sidebarVisible = true }
        case "0": sidebarPinChoice = false; if layoutPreset == .sidebar { sidebarAutoHide = true; sidebarVisible = false }
        default: sidebarPinChoice = nil
        }
        addressBarPosition = AddressBarPosition(rawValue: get("address_bar") ?? "") ?? Self.defaultAddressBarPosition
        showFavorites = get("show_favorites") != "0"
        showContinue = get("show_continue") != "0"
        lookalikeGuard = get("lookalike_guard") != "0"
        focusRules = Self.decodeMap(get("focus_rules"), as: [FocusRule].self)["list"] ?? []
        showFrequent = get("show_frequent") != "0"
        if let raw = get("toolbar_items") {
            var chosen = raw.split(separator: ",").compactMap { ToolbarItemID(rawValue: String($0)) }
            // The workspace and split-view buttons came later; a toolbar chosen before them gets them once, and can switch them off.
            #if os(macOS)
            let toolbarVersion = get("toolbar_items_version")
            if toolbarVersion == nil {
                for item in [ToolbarItemID.workspaces, .splitView] where !chosen.contains(item) { chosen.append(item) }
            }
            // The media indicator came with DX-09: a toolbar chosen before it gets it once, and can switch it off.
            if toolbarVersion == nil || toolbarVersion == "2" {
                if !chosen.contains(.media) { chosen.append(.media) }
                try? core.setSetting(key: "toolbar_items_version", value: "3")
            }
            #endif
            toolbarItems = ToolbarItemID.allCases.filter { chosen.contains($0) }
        } else {
            toolbarItems = ToolbarItemID.defaults
        }
        // Groups belong to workspaces. Settings from before that hold one list for everything: it is kept aside and placed once the tabs are known.
        if get("tab_groups_v2") != nil {
            groupLists = Self.decodeMap(get("tab_groups_v2"), as: [String].self)
            legacyGroupNames = []
        } else if let json = get("tab_groups"), let data = json.data(using: .utf8),
                  let names = try? JSONSerialization.jsonObject(with: data) as? [String] {
            groupLists = [:]
            legacyGroupNames = names
        } else {
            groupLists = [:]
            legacyGroupNames = []
        }
        accent = AccentChoice(rawValue: get("accent") ?? "") ?? .teal
        Theme.accent = accent.color
        startBackground = StartBackground(rawValue: get("start_background") ?? "") ?? .gradient
        newTabMode = NewTabMode(rawValue: get("new_tab_mode") ?? "") ?? .home
        privateOpenMode = PrivateOpenMode(rawValue: get("private_open_mode") ?? "") ?? .window
        autoShowPlayer = get("player_auto_show") != "0"
        floatingPlayerLayout = FloatingPlayerLayout(stored: get("player_position"))
        loadStartImage()
        startTitle = String((get("start_title") ?? "").prefix(40))
        startFont = StartFont(rawValue: get("start_font") ?? "") ?? .rounded
        startSearchStyle = StartSearchStyle(rawValue: get("start_search_style") ?? "") ?? .pill
        startWidth = StartWidth(rawValue: get("start_width") ?? "") ?? .standard
        startImageDim = min(max(Double(get("start_image_dim") ?? "") ?? 0.3, 0), 0.7)
        startImageBlur = min(max(Double(get("start_image_blur") ?? "") ?? 0, 0), 30)
        historyRetentionDays = HistoryRetention.choices.contains(Int(get("history_retention_days") ?? "") ?? -1) ? Int(get("history_retention_days")!)! : 0
        newTabURL = get("new_tab_url") ?? ""
        startColorA = StartColor.components(get("start_color_a") ?? "") != nil ? get("start_color_a")! : StartColor.defaultA
        startColorB = StartColor.components(get("start_color_b") ?? "") != nil ? get("start_color_b")! : StartColor.defaultB
        startLook = StartLook.decode(get("start_look"))
        let savedLibrary = WallpaperLibraryState.decode(get("wallpaper_library"))
        wallpaperLibraryWasRead = savedLibrary != nil
        wallpaperLibrary = savedLibrary ?? WallpaperLibraryState()
        startPreset = StartPreset.all.contains { $0.id == get("start_preset") } ? (get("start_preset") ?? StartPreset.defaultID) : StartPreset.defaultID
        startAnimatedGradient = get("start_animated_gradient") == "1"
        startVideoOn = get("start_video_on") == "1"
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

    /// The one way to show or hide the sidebar by hand (the toolbar button, ⇧⌘L, the menus). In the Sidebar layout this is the pin choice, so it is remembered
    /// and the pin button agrees with it; in the other layouts it only opens or closes the sidebar for now.
    func toggleSidebar() { setSidebarShown(!sidebarVisible) }

    func setSidebarShown(_ shown: Bool) {
        if layoutPreset == .sidebar {
            if shown { sidebarRail = false; pinSidebar() } else { hideSidebarToEdge() }
        } else {
            sidebarVisible = shown
        }
    }

    /// Forgets the pin choice (a layout reset).
    func clearSidebarPin() {
        sidebarPinChoice = nil
        saveSetting("sidebar_pinned", "")
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
        // Judged by what the button shows (pinned = open and docked), so a sidebar opened some other way can still be unpinned.
        if sidebarIsPinned { hideSidebarToEdge() } else { sidebarRail = false; pinSidebar() }
    }

    var sidebarIsPinned: Bool { sidebarVisible && !sidebarRail }

    func shows(_ item: ToolbarItemID) -> Bool { toolbarItems.contains(item) }
    /// How many of the added toolbar buttons are switched on, so the bar can leave room for them.
    /// What the top bar shows, for working out how much room its buttons take.
    var toolbarVisibility: ToolbarVisibility {
        #if os(macOS)
        let extensionButtons = min(4, extensionCenter.pinnedActions.count) + 1
        #else
        let extensionButtons = 0
        #endif
        return ToolbarVisibility(sidebar: shows(.sidebar), backForward: shows(.backForward), share: shows(.share), newTab: shows(.newTab), overview: shows(.tabOverview),
                                 bookmark: shows(.bookmark), downloads: shows(.downloads), extensionButtons: extensionButtons)
    }
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

    func switchProfile(_ name: String, thenOpen url: URL? = nil) {
        providerFlow.invalidateAll()                      // lookups, resolved links and watchers belong to the profile being left
        ExtractorBroker.shared.forget()                   // an extractor's remembered answers belong to the profile being left
        guard name != profileName, let newCore = try? BrowserCore.open(root: root, profile: name) else { return }
        let leaving = profileName
        pendingProfileURL = url
        saveNow()
        tabs.forEach { $0.shutdown() }
        tabs.removeAll()
        activeID = nil
        engine.privateSessionEnded()
        core = newCore
        profileName = name
        FaviconStore.shared.activate(directory: Self.faviconDirectory(root: root, profile: name), importLegacy: false)
        loadCheckpoints()   // the saved sessions belong to the profile just left; read the new profile's own, never carry the old ones over
        // A throw-away profile is never the one the app starts with next time.
        if persistsProfileChoice, !isTemporaryProfile(name) { UserDefaults.standard.set(name, forKey: "profile") }
        loadUISettings()
        privacy.load(from: core)
        attachExtensions()
        Task { [self] in
            await privacy.apply()
            restoreOrOpenFirstTab()
            if let page = pendingProfileURL { pendingProfileURL = nil; openTab(url: page, isPrivate: false) }
            if isTemporaryProfile(leaving) { await removeLeftoverTemporaryProfiles() }
        }
    }

    func removeProfile(_ name: String) async {
        guard name != profileName, name != "default" else { return }
        SuggestionLearning.forget(folder: URL(fileURLWithPath: root).appendingPathComponent("profiles/\(name)", isDirectory: true))
        try? deleteProfile(root: root, name: name)
        SignInVault.removeAll(profile: name)
        for p in [MediaProviderID.vimeo, .tiktok] { ProviderCredentials.revoke(p, profile: name) }          // provider authorizations go with the profile
        UserDefaults.standard.removeObject(forKey: "bs.tiktok.export." + name)
        providerFlow.invalidateAll()
        AccountStore.wipe(profile: name, folder: URL(fileURLWithPath: root).appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(name, isDirectory: true), secrets: KeychainAccountSecretStore(profile: name))
        AutomationController.wipe(profile: name, root: URL(fileURLWithPath: root))
        WebLoginVault.removeAll(profile: name)
        SignatureStore.removeAll(profile: name)
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
        guard tab.privacy.canWriteFilesWithoutAsking else { notice = "Pages from tabs that leave no trace are not saved to disk."; return }
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
        // Scripts come back switched off and with nothing allowed (see restore). The consent for SponsorBlock and its server, and a search server's suggestions, are never carried in a file.
        "user_scripts", "web_apps", "download_duplicate", "download_template", "searxng_instance", "cookie_banners_hide", "debounce_links", "redirect_skip_off", "consent_off", "sponsor_actions", "sponsor_off",
        "accent", "accent_chosen", "lookalike_guard", "focus_rules", "address_bar", "address_bar_items", "appearance", "density", "keep_pinned", "layout_preset", "memory_mode", "show_favorites", "show_continue",
        "show_frequent", "show_greeting", "show_recently_closed", "sidebar_autohide", "sidebar_position", "sidebar_rail",
        "organize_downloads_domain", "download_notify", "last_split", "track_time", "break_minutes", "clipboard_history", "feeds", "backdrop_intensity", "icon_weight", "site_icon_shape", "site_looks", "motion_style", "download_segments", "start_title", "start_font", "start_search_style", "start_width", "start_image_dim", "start_image_blur", "history_retention_days", "new_tab_mode", "new_tab_url", "start_color_a", "start_color_b", "reader_style", "media_history_on", "referrer_mode", "gpc", "block_link_pings", "lockdown_hosts", "tab_groups_v2", "essentials", "pinned_addresses", "glance_enabled", "glance_trigger", "glance_temporary", "learn_suggestions", "suggestion_excluded", "space_request_new_window", "clear_includes_sleeping", "clear_tabs_asks", "debounce_links", "block_local_network", "local_network_allowed", "block_google_services", "block_social_widgets", "private_search", "double_click_closes_tab", "hide_tab_close", "close_window_last_tab", "custom_keep", "custom_idle", "battery_aware", "security_events", "tab_schedules", "protect_pinned", "sidebar_width", "single_toolbar", "split_orientation", "start_background", "startup", "startup_workspace",
        "strip_tracking", "tab_groups", "tab_layout", "tab_previews", "tint_toolbar", "toolbar_autohide", "toolbar_items",
        "workspaces", "double_click", "collapse_on_scroll", "search_template", "search_suggestions", "speed_pill", "pill_collapsed", "site_icons", "shortcuts", "homepage", "saved_sessions", "organize_downloads", "site_notes", "search_shortcuts", "bookmark_tags", "site_styles", "phone_toolbar", "address_display", "address_icon", "search_panel_bottom", "search_panel_bottom2", "swipe_address", "app_links", "app_link_sites", "blur_private_switcher", "permission_expiry", "favorites_order", "overview_style", "overview_grouped", "overview_sort", "dark_pages", "dark_sites", "website_appearance", "site_appearance", "theme", "theme_custom", "low_power_memory", "clear_on_quit", "remember_reading", "keep_form_drafts", "site_zoom", "group_colors",
        "save_logins", "mouse_gestures", "mouse_gesture_map", "site_open_rules", "download_concurrent", "spotlight_bookmarks", "vim_on", "vim_keymap", "workflows", "download_rules", "extension_profiles", "site_delete_rules", "site_user_agents", "containers", "split_templates", "tab_tree", "block_webrtc", "webrtc_exceptions",
        "site_js_off", "never_sleep_sites", "dark_sites_off", "custom_sidebar", "phone_preset", "phone_custom_layout", "fingerprint_noise", "fingerprint_exceptions", "de_amp", "video_ads", "cookie_banners", "user_themes", "start_tile", "block_autoplay", "autoplay_exceptions",
        "block_popups", "popup_allowed_hosts", "youtube_rules_auto", "command_chains", "web_panels", "theme_schedule", "hidden_menu_items", "hover_previews", "hover_delay", "tab_stacks", "address_sources", "sidebar_footer",
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
            var value = value
            // A script from a file starts switched off and with nothing allowed: the person looks at it and turns it on, as for any script they install.
            if key == "user_scripts" { value = Self.quarantined(userScripts: value) }
            if (try? core.setSetting(key: key, value: value)) != nil { applied += 1 }
        }
        if let collections = payload.research { research.merge(collections) }
        lastRestoredPasswords = payload.passwords.map { restorePasswords($0) } ?? 0
        loadUISettings()
        refreshBookmarkState()
        return (added, applied)
    }

    /// The scripts of a backup, off, with no permissions, and no more than the limit. Anything that cannot be read is dropped.
    static func quarantined(userScripts json: String) -> String {
        guard let data = json.data(using: .utf8), let list = try? JSONDecoder().decode([UserScript].self, from: data) else { return "[]" }
        let safe = list.prefix(UserScript.maxScripts).map { script -> UserScript in
            var s = script
            s.enabled = false; s.granted = []
            if s.autoDisabledReason.isEmpty { s.autoDisabledReason = "Restored from a backup, so it is off until you look at it and turn it on." }
            return s
        }
        return (try? String(data: JSONEncoder().encode(Array(safe)), encoding: .utf8)) ?? "[]"
    }

    // MARK: Link cleaning, threat list, website data

    /// Where a tracker's redirect page would send the visitor, or nil. Goes with the link-cleaning loop guard, so a page that sends the visit back through
    /// a redirect can never loop.
    func debouncedLink(_ url: URL) -> URL? {
        guard debounceLinks else { return nil }
        let now = Date()
        recentStrips.removeAll { now.timeIntervalSince($0) > 5 }
        guard recentStrips.count < 3, let direct = LinkDebouncer.destination(for: url) else { return nil }
        recentStrips.append(now)
        strippedLinkCount += 1
        return direct
    }

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
            } else {
                // Not opened: the tab says so on its own page (what blocked it, and where to go), instead of silently staying where it was.
                tab.showProtectionBlock(for: url, reason: .threatList)
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
    func removeSiteData(host: String) async {
        FaviconStore.shared.remove(host: host)
        await engine.removeSiteData(host: host, profile: profileName)
    }

    /// Where a profile's site icons live: inside the profile's own folder, so deleting the profile deletes them and no other profile can read them.
    static func faviconDirectory(root: String, profile: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent("profiles/\(profile)/favicons", isDirectory: true)
    }

    func clearBrowsingData() async {
        guard recovery == nil else { return }
        try? core.clearHistory()
        eraseSearchableCopy()
        try? core.clearDownloads()
        FaviconStore.shared.clear()
        // What was learned or noted from browsing goes too: it names the same sites. (Clear Everything Now calls this, so it leaves no copy behind.)
        resetLearnedSuggestions()
        clearPageMemory()
        clearMediaHistory()
        clearPermissionLog()
        clearSecurityEvents()
        resetBlockedStats()
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
    /// False for a label that only says where a command lives (a menu's name): it is shown, but a search does not match on it, so "tool" does not list every command of the Tools menu.
    var matchesSubtitle = true
    let run: @MainActor () -> Void
}

extension BrowserModel {
    /// Every palette entry reuses an existing model command; there is no separate logic here.
    func allPaletteItems(query: String = "", full: Bool = false) -> [PaletteItem] {
        var all: [PaletteItem] = [
            .init(id: "new-tab", title: "New Tab", subtitle: "", symbol: "plus", shortcut: "⌘T") { [self] in newTab() },
            .init(id: "new-private-window", title: "New Private Window", subtitle: "", symbol: "eye.slash.fill", shortcut: shortcuts.combo(for: privateOpenMode == .window ? .newPrivate : .newPrivateWindow)?.display ?? "") { [self] in openPrivateWindow() },
            .init(id: "new-private", title: "New Private Tab", subtitle: "", symbol: "eye.slash", shortcut: shortcuts.combo(for: privateOpenMode == .tab ? .newPrivate : .newPrivateTab)?.display ?? "") { [self] in openTab(url: nil, isPrivate: true) },
            .init(id: "reopen", title: "Reopen Closed Tab", subtitle: closedTabs.last?.title ?? "", symbol: "arrow.uturn.backward", shortcut: "⇧⌘T") { [self] in reopenClosedTab() },
            .init(id: "sidebar", title: "Toggle Sidebar", subtitle: "", symbol: "sidebar.left", shortcut: "⇧⌘L") { [self] in toggleSidebar() },
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
            .init(id: "research-save", title: "Save to Research…", subtitle: "Page, selection, note and tags together", symbol: "tray.and.arrow.down", shortcut: "") { [self] in Task { @MainActor in researchDraft = await researchDraftForActivePage(); if researchDraft != nil { sheet = .saveToResearch } } },
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
            // One entry per local tool. The list is only read when the palette is built, and the tools themselves are only built when one is used.
            .init(id: "tools-panel", title: "Tools", subtitle: "JSON, Base64, hashes, JWT and more, on this device", symbol: "wrench.and.screwdriver", shortcut: "") { [self] in toolSelection = nil; sheet = .tools },
            .init(id: "highlight", title: "Highlight Selection", subtitle: "In a saved article", symbol: "highlighter", shortcut: "") { [self] in Task { await highlightSelection() } },
            .init(id: "sort-site", title: "Sort Tabs by Website", subtitle: "", symbol: "arrow.up.arrow.down", shortcut: "") { [self] in sortTabs(by: .website) },
            .init(id: "sort-title", title: "Sort Tabs by Title", subtitle: "", symbol: "textformat", shortcut: "") { [self] in sortTabs(by: .title) },
            .init(id: "sort-used", title: "Sort Tabs by Last Used", subtitle: "", symbol: "clock", shortcut: "") { [self] in sortTabs(by: .lastUsed) },
            .init(id: "mute-all", title: "Mute All Tabs Playing Sound", subtitle: "", symbol: "speaker.slash", shortcut: "") { [self] in muteAllPlaying(true) },
            .init(id: "idle-groups", title: "Put Idle Groups to Sleep", subtitle: "Groups unused for 30 minutes", symbol: "moon.zzz", shortcut: "") { [self] in Task { await sleepInactiveGroups() } },
            .init(id: "snooze-tab", title: "Snooze This Tab Until Tomorrow", subtitle: "", symbol: "zzz", shortcut: "") { [self] in if let tab = active { snooze(tab, until: SnoozeChoice.tomorrow.date()) } },
            .init(id: "reader-bigger", title: "Reader: Larger Text", subtitle: "", symbol: "textformat.size.larger", shortcut: "") { [self] in changeReaderSize(by: 2) },
            .init(id: "reader-smaller", title: "Reader: Smaller Text", subtitle: "", symbol: "textformat.size.smaller", shortcut: "") { [self] in changeReaderSize(by: -2) },
            .init(id: "cite-doi", title: "Copy Citation from the Page's DOI (Crossref)", subtitle: "Exact authors, journal, year and pages", symbol: "quote.opening", shortcut: "") { [self] in Task { await copyCitationFromDOI(.apa) } },
            .init(id: "cite-apa", title: "Copy Citation (APA)", subtitle: "", symbol: "quote.opening", shortcut: "") { [self] in copyCitation(.apa) },
            .init(id: "cite-mla", title: "Copy Citation (MLA)", subtitle: "", symbol: "quote.opening", shortcut: "") { [self] in copyCitation(.mla) },
            .init(id: "copy-highlights", title: "Copy Highlights with Citation", subtitle: "", symbol: "highlighter", shortcut: "") { [self] in copyHighlights() },
            .init(id: "translate-selection", title: "Translate Selected Text", subtitle: "", symbol: "character.bubble", shortcut: "") { [self] in Task { await translateSelection() } },
            .init(id: "page-language", title: "What Language Is This Page?", subtitle: "", symbol: "globe", shortcut: "") { [self] in Task { await detectPageLanguage() } },
            .init(id: "open-clipboard-links", title: "Open Links from the Clipboard", subtitle: "Each address in its own tab", symbol: "link.badge.plus", shortcut: "") { [self] in Task { await openLinksFromClipboard() } },
            .init(id: "clean-clipboard", title: "Remove Tracking from Links on the Clipboard", subtitle: "", symbol: "scissors", shortcut: "") { [self] in transformClipboard(.cleanLinks) },
            .init(id: "reopen-split", title: "Reopen Last Split Layout", subtitle: "", symbol: "rectangle.split.2x1", shortcut: "") { [self] in reopenLastSplit() },
            .init(id: "compare-panels", title: "Compare the Two Split Pages", subtitle: "", symbol: "rectangle.split.2x1.fill", shortcut: "") { [self] in Task { await comparePanels() } },
            .init(id: "link-panels", title: "Link Scrolling in Split View", subtitle: "", symbol: "link", shortcut: "") { [self] in setLinkedPanes(!linkedPanes) },
            .init(id: "screenshot-annotate", title: "Screenshot This Page and Mark It Up", subtitle: "Whole page, then draw, highlight, redact or sign", symbol: "camera.viewfinder", shortcut: "") { [self] in Task { await annotatePageScreenshot() } },
            .init(id: "restore-last-session", title: "Reopen My Last Session", subtitle: "The pages from the newest checkpoint", symbol: "clock.arrow.circlepath", shortcut: "") { [self] in reopenLastSession() },
            .init(id: "inbox", title: "Take In Items from the Share Sheet", subtitle: "", symbol: "tray.and.arrow.down", shortcut: "") { [self] in consumeSharedInbox() },
            .init(id: "digest", title: "Daily Digest", subtitle: "Saved articles, feeds and tasks in one place", symbol: "newspaper", shortcut: "") { [self] in sheet = .digest },
            .init(id: "panic", title: "Clear Everything Now", subtitle: "Closes every tab and erases history, data and copied text", symbol: "exclamationmark.octagon", shortcut: "") { [self] in Task { await panic() } },
            .init(id: "toolkit", title: "Feeds, Ask This Page, Time on Sites, Clipboard", subtitle: "", symbol: "square.grid.2x2", shortcut: "") { [self] in sheet = .toolkit },
            .init(id: "time-machine", title: "Session Time Machine: Go Back to Earlier Tabs", subtitle: "", symbol: "clock.arrow.circlepath", shortcut: "") { [self] in sheet = .timeMachine },
            .init(id: "diag-report", title: "Copy a Diagnostic Report", subtitle: "No addresses or titles", symbol: "stethoscope", shortcut: "") { [self] in
                copyToPasteboard(ReliabilityStats.shared.report(tabs: tabs.count, sleeping: tabs.filter(\.isDiscarded).count, extensions: extensionCenter.extensions.filter(\.enabled).count)); notice = "Report copied."
            },
            .init(id: "bookmark-tools", title: "Bookmark Tools: Duplicates, Broken Links, Collections", subtitle: "", symbol: "bookmark.square", shortcut: "") { [self] in sheet = .bookmarkTools },
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
            .init(id: "clear-tabs", title: "Clear Tabs", subtitle: "Close this workspace’s unpinned tabs; Undo brings them back", symbol: "xmark.bin", shortcut: "") { [self] in clearTabs() },
            .init(id: "clear-tabs-awake", title: "Clear Tabs Except Sleeping Ones", subtitle: "", symbol: "moon.zzz", shortcut: "") { [self] in clearTabs(includeSleeping: false) },
            .init(id: "add-essential", title: "Add This Tab to Essentials", subtitle: essentials.count >= Essentials.maxCount ? "You already have \(Essentials.maxCount)" : "", symbol: "square.grid.2x2.fill", shortcut: "") { [self] in if let tab = active { addToEssentials(tab) } },
            .init(id: "reset-pinned", title: "Reset Pinned Tab to Its Address", subtitle: "", symbol: "pin.slash", shortcut: "") { [self] in if let tab = active, tab.pinned { resetPinnedTab(tab) } else { notice = "The tab in front is not pinned." } },
        ] + essentials.map { essential in
            PaletteItem(id: "essential-\(essential.id)", title: "Open Essential: \(essential.title)", subtitle: URL(string: essential.url)?.host ?? "", symbol: "square.grid.2x2", shortcut: "") { [self] in openEssential(essential.id) }
        }
        for device in sendTargets where active?.isBlank == false && active?.isPrivate == false {
            all.append(.init(id: "send-\(device.id)", title: "Send This Tab to \(device.name)", subtitle: "", symbol: "paperplane", shortcut: "") { [self] in if let tab = active { sendTab(tab, to: device) } })
        }
        all.append(.init(id: "find", title: "Find in Page", subtitle: "", symbol: "magnifyingglass", shortcut: "⌘F") { [self] in showFind() })
        #if os(macOS)
        all.append(.init(id: "player-controls", title: "Show Player Controls", subtitle: "Floating over the page", symbol: "play.rectangle", shortcut: "") { [self] in openFloatingPlayer() })
        // Every command of the menu bar is here too (AppCommands is the one list both are made from); those the palette already offered under the same name are not listed twice.
        let known = Set(all.map { Self.paletteKey($0.title) })
        for command in AppCommands.all where !known.contains(Self.paletteKey(command.title)) {
            all.append(.init(id: command.id, title: command.title, subtitle: command.section, symbol: command.symbol,
                             shortcut: command.shortcut.flatMap { shortcuts.combo(for: $0)?.display } ?? "", matchesSubtitle: false) { [self] in
                if !AppCommands.perform(command, self) { notice = "“\(command.title)” is not available right now." }
            })
        }
        #endif
        for entry in ToolRegistry.paletteEntries { all.append(.init(id: "tool-\(entry.id)", title: "Tool: \(entry.title)", subtitle: "Runs on this device", symbol: entry.symbol, shortcut: "") { [self] in toolSelection = entry.id; sheet = .tools }) }
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

    /// A title as the palette compares it: no case, no trailing ellipsis.
    static func paletteKey(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
    }

    func paletteItems(query: String) -> [PaletteItem] {
        let all = allPaletteItems(query: query)
        // "pasta recipe last week" lists the pages from history that fit, ahead of the commands.
        let recalled: [PaletteItem] = (plainRecall(query)?.items ?? []).prefix(5).compactMap { page in
            guard let url = URL(string: page.url) else { return nil }
            return PaletteItem(id: "recall-\(page.url)", title: page.title.isEmpty ? page.url : page.title,
                               subtitle: "From your history · \(Date(timeIntervalSince1970: TimeInterval(page.lastVisit)).formatted(.relative(presentation: .named)))",
                               symbol: "clock.arrow.circlepath", shortcut: "") { [self] in _ = openTab(url: url, isPrivate: false) }
        }
        let ranked = all.compactMap { item -> (Int, PaletteItem)? in
            guard let score = fuzzyScore(query: query, in: item.title) ?? (item.matchesSubtitle ? fuzzyScore(query: query, in: item.subtitle).map({ $0 - 20 }) : nil) else { return nil }
            return (score, item)
        }
        .sorted { $0.0 > $1.0 }
        // A typed search shows up to twenty matches (the list scrolls): with every menu command searchable, a dozen would hide matches that are real. Nothing typed still shows a dozen.
        .prefix(20)
        .map(\.1)
        return Array((recalled + ranked).prefix(20))
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
