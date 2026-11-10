import SwiftUI

/// One browsing context in the shell. Engine-neutral: it owns a `TabEngine`, enforces core policy
/// on every navigation the engine proposes, and publishes state for the UI.
@MainActor
final class TabController: ObservableObject, Identifiable, TabEngineEvents {
    let id: UInt64
    let isPrivate: Bool
    /// Whether nothing about this tab may be written down or learned: a private tab, a scratch tab, a page in a Glance preview, or any tab of a guest window.
    /// One question, asked by every place that keeps something (history, the searchable copy, media history, learned suggestions), so none can forget a kind.
    /// What kind of tab this is (see TabPrivacy). `leavesNoTrace` is simply "anything but a normal tab", so the two can never disagree.
    var context: TabContext {
        if owner?.isGuest == true { return .guest }
        if isPrivate { return .privateTab }
        if owner?.tabMeta[id]?.scratch == true { return .scratch }
        if owner?.glance.isGlance(self) == true { return .glance }
        return .normal
    }
    var leavesNoTrace: Bool { context != .normal }
    /// Weak on purpose: the engine can report an event for a tab after its model is gone (a model that was released
    /// while a page was still loading). An `unowned` reference would crash there; a weak one just ignores the event.
    private weak var owner: BrowserModel?
    /// The browser this tab belongs to (for the error page's recovery actions).
    var model: BrowserModel? { owner }

    /// The tab now belongs to another window.
    func reassign(to model: BrowserModel) { owner = model }
    private(set) var engine: TabEngine!

    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    /// The wait, after a page loads, to see what became of a consent banner (see ConsentTools.swift).
    var consentTask: Task<Void, Never>?
    /// Set when this tab belongs to a web app (see WebApps.swift).
    var webApp: WebAppRecord?
    /// A redirect link the person chose to follow after all: it is not skipped this once.
    var redirectBypass: URL?
    /// The lookup of SponsorBlock segments for the video on this page (see SponsorBlock.swift).
    var sponsorTask: Task<Void, Never>?
    /// The browser this tab belongs to, for the consent record (the tab's own `owner` stays private).
    var consentOwner: BrowserModel? { owner }
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isSecure = false
    /// The page is using the camera or the microphone right now.
    @Published var usesCamera = false
    @Published var usesMicrophone = false
    /// Who the site's certificate says is on the other end; nil until the page has loaded or when it is not encrypted.
    @Published private(set) var identity: CertificateIdentity?
    /// The colour the page declares for browser chrome, if any.
    @Published var tint: PageTint?
    /// The address a page tried to open in a window without a click: kept so the person can allow it from the page.
    @Published var blockedPopup: URL?
    /// A name and password just typed on this page, held in memory only until the page changes, so "Save password?" can be offered even when the sign-in itself is not noticed.
    @Published var typedLogin: PendingLogin?
    @Published var group: String
    @Published var pinned: Bool
    /// Sound is coming from a player on the page; refreshed every few seconds by the window.
    @Published private(set) var playingAudio = false
    /// The person muted this tab. Held again after each page load.
    @Published private(set) var muted = false
    @Published var workspace: String
    /// The filters in use on this page (grayscale, invert…); kept for the tab, re-applied after each load.
    @Published var pageActions: Set<PageAction> = []
    /// Refused loads on this page so far (an estimate), and how many of them are already in the running totals.
    @Published private(set) var blockedOnPage = 0
    private var blockedRecorded = 0
    /// PNG of the page as last seen, for tab overview cards.
    @Published var snapshot: Data?

    /// When the tab was last in front; the memory policy releases the longest-idle tabs first.
    var lastActive = Date()
    /// True after the page's web process was released to save memory; it reloads when the tab is selected.
    @Published private(set) var isDiscarded = false
    private var savedState: Any?
    private var crashGuard = CrashGuard()

    /// Set for restored tabs whose page has not been loaded yet.
    private var pendingURL: URL?
    /// A page failed to load and the error page is showing. Whenever the tab stops showing it, what it said goes with it.
    private var showingError = false {
        didSet { if !showingError, errorInfo != nil { errorInfo = nil } }
    }
    private(set) var failedURL: URL?
    /// What went wrong, for the native error page laid over the page area (nil when there is no error).
    @Published private(set) var errorInfo: BrowserErrorInfo?

    init(info: TabInfo, model: BrowserModel, restoredURL: URL? = nil, popupConfiguration: AnyObject? = nil) {
        id = info.id
        isPrivate = info.private
        title = info.title
        group = info.group
        pinned = info.pinned
        workspace = info.workspace
        url = restoredURL
        pendingURL = restoredURL
        self.owner = model
        engine = popupConfiguration.flatMap { model.engine.makePopupTab(configuration: $0, events: self) }
            ?? model.engine.makeTab(isPrivate: info.private, profile: model.profileName, container: info.private ? nil : model.tabMeta[info.id]?.container,
                                    privateSession: info.private && model.isPrivateWindow ? model.privateSessionID : nil, events: self)
        applyWebsiteAppearance()
    }

    var hostView: PlatformView { engine.hostView }
    var isShowingError: Bool { showingError }
    /// True once the engine has committed a page (restored tabs stay false until selected).
    var hasLoadedPage: Bool { engine.currentURL != nil }

    var isBlank: Bool {
        guard let url else { return true }
        return url.absoluteString == "about:blank" && !showingError
    }

    /// What a screen reader says for the tab: the title, and for a page that has none and is shown by a bare numeric address, a sentence instead of the numbers.
    var spokenTitle: String { Self.spoken(displayTitle, titled: !title.isEmpty || owner?.tabMeta[id]?.name != nil) }

    /// Only a tab that has no title of its own (no page title, no name the person gave it) and is shown by its numeric host is described in words; a real title is always spoken as it is.
    static func spoken(_ display: String, titled: Bool) -> String {
        guard !titled, display.range(of: #"^[0-9.:\[\]a-fA-F]+$"#, options: .regularExpression) != nil, display.contains(where: { $0 == "." || $0 == ":" }) else { return display }
        return "Page without a title at \(display)"
    }

    var displayTitle: String {
        if let name = owner?.tabMeta[id]?.name { return name }
        if !title.isEmpty { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    // MARK: Commands

    /// Settings live in a tab of their own: this address is never sent to the engine; the window draws the settings in its place.
    static let settingsURL = URL(string: "browsersetu://settings")!
    var isSettingsPage: Bool { url == Self.settingsURL }

    /// A library panel (Bookmarks, History, Downloads) living in a tab, drawn by the window like Settings.
    static func panelURL(_ sheet: Sheet) -> URL? {
        switch sheet { case .bookmarks, .history, .downloads: URL(string: "browsersetu://panel/\(sheet.rawValue)"); default: nil }
    }
    var panelSheet: Sheet? {
        guard let url, url.scheme == "browsersetu", url.host == "panel" else { return nil }
        return Sheet(rawValue: url.lastPathComponent)
    }
    var isInternalPage: Bool { isSettingsPage || panelSheet != nil }

    func load(_ target: URL) {
        if target == Self.settingsURL || (target.scheme == "browsersetu" && target.host == "panel") {
            pendingURL = nil; showingError = false; isLoading = false
            url = target
            switch panelSheet { case .bookmarks?: title = "Bookmarks"; case .history?: title = "History"; case .downloads?: title = "Downloads"; default: title = "Settings" }
            return
        }
        // Anything the person (or the page) loads ends a wait for the network and starts the automatic-try allowance again; only the one try made by the wait itself keeps it used.
        DeviceNetwork.shared.cancel(id: id)
        if !autoRetrying { autoRetryUsed = false }
        autoRetrying = false
        // Moving to a different site starts the crash count again.
        if target.host != url?.host { crashGuard.reset() }
        pendingURL = nil
        showingError = false
        url = target
        engine.load(target)
    }

    /// Goes to `target` in this same tab (its web view, container and cookies stay; the new page is just the newest entry in its history). A sleeping tab
    /// does not wake for it: it loads `target`, and not the page it fell asleep on, when it is next shown.
    /// Hands an address to the system (the person's default browser), for a link that a web app does not show itself.
    static func openOutside(_ url: URL) {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    func goToAddress(_ target: URL) {
        guard isDiscarded else { load(target); return }
        savedState = nil
        pendingURL = target
        url = target
        showingError = false
    }

    /// Keeps this tab's address and title without loading the page, as a tab restored at launch does: it loads when it is first shown. For bringing back many tabs
    /// at once (Undo after Clear Tabs) without starting a page load for each.
    func holdAddress(_ target: URL, title: String) {
        guard !isDiscarded, !isLoading, engine.currentURL == nil else { return }
        savedState = nil
        pendingURL = target
        url = target
        if !title.isEmpty { self.title = title }
        isDiscarded = true
        sleepReason = "brought back by Undo; it loads when you open it"
    }

    /// Loads a restored tab's page the first time it becomes visible.
    func ensureLoaded() {
        lastActive = Date()
        if let state = savedState {
            // Back/forward history and scroll position come back with the page.
            savedState = nil
            pendingURL = nil
            isDiscarded = false
            engine.restoreState(state)
        } else if let pendingURL {
            isDiscarded = false
            load(pendingURL)
        }
    }

    /// Releases this tab's web process while keeping what the user sees in the tab list and what is needed to bring
    /// the page back. Private tabs are never released: their state could not be restored.
    /// Why the page was put to sleep, shown in the resource view.
    @Published private(set) var sleepReason = ""

    func discard(reason: String = "not used for a while, to save memory", afterProcessEnd: Bool = false) {
        guard !isPrivate, !isDiscarded, afterProcessEnd || engine.currentURL != nil, let model = owner, model.tabMeta[id]?.scratch != true else { return }
        let state = engine.captureState()
        let address = url ?? engine.currentURL
        engine.stop()
        engine.close()
        engine = model.engine.makeTab(isPrivate: false, profile: model.profileName, container: model.tabMeta[id]?.container, events: self)
        applyWebsiteAppearance()
        savedState = state
        pendingURL = address
        isDiscarded = true
        sleepReason = reason
        isLoading = false
        progress = 0
        showingError = false
    }

    func reload() {
        // A page that keeps crashing is left alone for a minute so reloading cannot trap the tab in a cycle.
        if crashGuard.isPaused(at: Date()) {
            owner?.notice = "This page keeps crashing. Wait \(crashGuard.secondsLeft(at: Date())) seconds, or open a different page."
            return
        }
        // An error page is local content; reloading it would just show the error again.
        if showingError, let target = failedURL ?? url { load(target) }
        else if engine.currentURL == nil, let url { load(url) }
        else if isInternalPage { return }
        else { engine.reload() }
    }

    func stop() { engine.stop() }

    /// "Go Back" from an error page. The load that failed never replaced the page that was showing, so that page is still in the web view: the error is taken away
    /// and it is there again, with the tab's history exactly as it was. With nothing behind (a new tab's first load) it steps back in history instead.
    func leaveError() {
        guard showingError else { goBack(); return }
        showingError = false
        isLoading = false
        if let current = engine.currentURL, current != failedURL { url = current } else { engine.goBack() }
    }

    func goBack() { engine.goBack() }
    func goForward() { engine.goForward() }

    /// Page tools. Each lasts for this tab until it is turned off; dark pages follow the Settings choice instead.
    @Published private(set) var desktopSite = false
    @Published private(set) var javaScriptOn = true
    @Published private(set) var darkened = false

    /// Mac: the site's phone version is being asked for.
    @Published private(set) var mobileSite = false
    func toggleMobileSite() { mobileSite.toggle(); engine.setMobileSite(mobileSite) }

    /// Set while this tab shows a saved reading-list article (so highlights go to the right one).
    var readingItemID: UUID?
    var allowedLocalFile: URL?
    /// The article on show in reader view or from the reading list, kept so a change of style can draw it again.
    var readerContent: (article: ReadableArticle, highlights: [String], base: URL?)?

    var isLocked: Bool { owner?.lockedTabIDs.contains(id) ?? false }

    func toggleDesktopSite() { desktopSite.toggle(); engine.setDesktopMode(desktopSite) }
    func toggleJavaScript() { javaScriptOn.toggle(); engine.setJavaScriptEnabled(javaScriptOn) }

    /// Applies the dark-pages choice to the page that has just loaded.
    func applyBottomInset() { engine.setViewportInsets(top: owner?.phoneTopInset ?? 0, bottom: owner?.phoneBottomInset ?? 0) }

    func applyWebsiteAppearance() { engine.setWebsiteAppearance(owner?.effectiveWebsiteAppearance(host: url?.host).rawValue ?? "system") }

    /// Dark pages: first ask the site for its own dark design (a site that has one shows it, and looks right). The page script (AdaptiveDark.swift), which
    /// runs from the start of every load, darkens only a page that is still light after that. `live` also changes the page that is already open, for a
    /// switch or the Darken button; a load finds out for itself.
    func applyDarkPages(live: Bool = false) {
        let want = owner?.shouldDarken(host: url?.host) ?? false
        if want {
            engine.setWebsiteAppearance("dark")
        } else if darkened {
            applyWebsiteAppearance()
        }
        let changed = want != darkened
        darkened = want
        if live && (changed || want) { engine.setPageDarkening(want) }
    }

    func scrollToEdge(bottom: Bool) { engine.scrollToEdge(bottom: bottom) }

    /// True while the reader's own page is showing instead of the site.
    @Published private(set) var isReading = false
    private var readerOrigin: URL?

    /// Shows the page's article as plain readable text, or goes back to the page.
    func toggleReader() async {
        if isReading, let origin = readerOrigin {
            isReading = false
            readerOrigin = nil
            load(origin)
            return
        }
        guard let page = url, !isBlank, ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { return }
        guard let article = await engine.readableContent() else {
            owner?.notice = "This page has no article to show in the reader."
            return
        }
        readerOrigin = page
        isReading = true
        readerContent = (article, [], page)
        engine.showHTML(ReaderHTML.page(for: article), baseURL: page)
    }

    func zoom(by delta: Double) {
        engine.zoomFactor = min(3, max(0.3, engine.zoomFactor + delta))
        if !leavesNoTrace { owner?.rememberZoom(engine.zoomFactor, forHost: url?.host) }      // a private tab's site is not written to the settings (and so not synced)
    }

    func resetZoom() {
        engine.zoomFactor = 1
        if !leavesNoTrace { owner?.rememberZoom(1, forHost: url?.host) }
    }

    /// A site keeps the zoom it was last given.
    func applySavedZoom() {
        guard let host = url?.host else { return }
        let wanted = owner?.siteZoomFactor(forHost: host) ?? 1
        if abs(engine.zoomFactor - wanted) > 0.001 { engine.zoomFactor = wanted }
    }

    private var lastSnapshotAt = Date.distantPast

    /// The picture shown in the tab overview. A blank tab has nothing to show, and one taken moments ago is still right, so quick
    /// switching between tabs does not ask the web engine for a picture each time.
    func captureSnapshot() async {
        guard !isBlank, !isDiscarded, Date().timeIntervalSince(lastSnapshotAt) > 2, owner?.governor.allowsThumbnails ?? true else { return }
        lastSnapshotAt = Date()
        if let data = await engine.snapshot() { snapshot = data }
    }

    func shutdown() {
        engine.stop()
        engine.close()
    }

    // MARK: Engine events

    func engineTitleChanged(_ title: String) {
        if !title.isEmpty { self.title = title }
        if !isPrivate { owner?.extensionCenter.tabChanged(self) }
    }

    func engineURLChanged(_ url: URL) {
        // A different page has been committed under the error page (history back or forward, say): the error is over. The address that failed never commits, so this
        // never clears it by mistake.
        if showingError, url != failedURL { showingError = false }
        if isReading, url != readerOrigin { isReading = false; readerOrigin = nil }
        if identity != nil, identity?.host != url.host { identity = nil }
        if self.url?.host != url.host { typedLogin = nil }
        self.url = url
        pendingURL = nil
        engine?.rescanMedia()          // a single-page app may have swapped its player without loading a page
        owner?.tabURLChanged(self)
        owner?.sponsorCheck(self)
        owner?.noteInteraction()
        if !isPrivate { owner?.extensionCenter.tabChanged(self) }
    }

    func engineLoadingChanged(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        // A page opened in a new tab never heard how much room the bars take (that is told only when it changes): tell it as the page starts, so its fixed headers and footers sit clear of them.
        if isLoading, !self.isLoading { applyBottomInset() }
        // A navigation beginning while an error is showing (history, a script, a retry) replaces it.
        if isLoading, !self.isLoading, showingError { showingError = false }
        // A new page starts at its top, so the toolbar comes back with it.
        if isLoading, !self.isLoading, owner?.activeID == id { owner?.expandChrome() }
        // A new page begins: take what the old one had refused, then start counting again.
        if isLoading, !self.isLoading { Task { await refreshBlocked(); blockedRecorded = 0; blockedOnPage = 0 } }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !isPrivate { owner?.extensionCenter.tabChanged(self) }
    }

    /// WebKit reports progress many times a second; the bar only needs a visible step, and each report redraws everything that shows this tab.
    func engineProgress(_ progress: Double) {
        guard progress == 0 || progress >= 1 || abs(progress - self.progress) >= 0.02 else { return }
        self.progress = progress
    }

    func engineMouseGesturesEnabled() -> Bool { owner?.mouseGestures == true }
    // A saved page from this device never runs scripts.
    func engineScriptsAllowed(for url: URL) -> Bool { !url.isFileURL && javaScriptOn && owner?.scriptsAllowed(forHost: url.host) != false }
    func engineMouseGesture(_ sequence: String, finished: Bool) { if owner?.activeID == id { owner?.mouseGestureProgress(sequence, finished: finished) } }

    func engineWantsLoginCapture() -> Bool { privacy.canSaveLogins && owner?.saveLoginsEnabled == true }
    func engineShowDownloads() { owner?.sheet = .downloads }
    func engineCustomLink(_ url: URL, linkActivated: Bool) -> Bool { owner?.handleCustomLink(url, linkActivated: linkActivated, fromPrivate: leavesNoTrace) ?? false }
    func engineLinkAction(_ url: URL, _ action: LinkAction) {
        guard let model = owner, url.scheme == "http" || url.scheme == "https" else { return }
        // In a web app there are no other tabs: a link that would open one goes outside the app (or stays, if it is the app's own site).
        if let app = governingWebApp { if app.allows(url) { load(url) } else { Self.openOutside(url) }; return }
        let container = model.tabMeta[id]?.container
        switch action {
        case .newTab: model.openTab(url: url, isPrivate: isPrivate, opener: self, container: container)
        case .backgroundTab: model.openTab(url: url, isPrivate: isPrivate, select: false, opener: self, container: container)
        case .privateTab: model.openTab(url: url, isPrivate: true)
        case .glance: model.glance.present(url, from: self)
        case .otherPane: model.openInOtherPane(url, from: self)
        case .split:
            let tab = model.openTab(url: url, isPrivate: isPrivate, select: false, opener: self, container: container)
            if model.splitTabID == nil { model.openSplit(with: tab) } else { model.addThirdPanel(with: tab) }
        }
    }
    func enginePageMenuEnabled() -> Bool { owner?.pageMenuExtras == true }
    func enginePageMenuAction(_ action: PageMenuAction, target: PageMenuTarget) { owner?.pageMenu(action, target: target, in: self) }
    func engineLoginTyped(origin: String, user: String, password: String) {
        guard !isPrivate, let model = owner, model.saveLoginsEnabled else { return }
        let kept = WebLoginVault.list(origin: origin, profile: model.profileName)
        guard LoginRules.offer(origin: origin, user: user, password: password, kept: kept, neverFor: model.neverSaveOrigins) != .nothing else { typedLogin = nil; return }
        typedLogin = PendingLogin(origin: origin, user: user, password: password)
    }

    // MARK: Media observations (DX-07)

    /// What this tab's page has told the browser about its media. It lives and dies with the tab, so a closed tab leaves nothing behind.
    let mediaBuffer = MediaObservationBuffer()
    func engineMediaObserved(_ observation: MediaObservation) {
        if mediaBuffer.accept(observation) { owner?.mediaObservationChanged(in: self, observation: observation) }
    }
    func engineMediaNavigated() {
        mediaBuffer.navigated()
        owner?.mediaPageNavigated(self)
    }

    func engineLoginFieldFocused(origin: String?, usernameOnly: Bool) { if !isPrivate { owner?.offerToFillLogin(in: self, frameOrigin: origin, usernameOnly: usernameOnly) } }
    func engineLoginSubmitted(origin: String, user: String, password: String) { owner?.loginSubmitted(origin: origin, user: user, password: password, in: self) }

    func engineVimKey(_ key: String) -> Bool {
        guard let model = owner, model.activeID == id else { return false }
        return model.workbench.handleVimKey(key)
    }

    func engineScrolled(deltaY: Double) {
        owner?.noteInteraction()
        guard let model = owner, model.activeID == id else { return }
        FrameMonitor.mark("Scrolling a page", for: 0.4)
        model.pageScrolled(deltaY: deltaY)
    }
    func engineScrollPosition(screens: Double, deltaY: Double) {
        guard let model = owner, model.activeID == id else { return }
        model.pageMoved(deltaY: deltaY, screens: screens)
    }
    func engineSecurityChanged(_ secure: Bool) { isSecure = secure }
    func engineCaptureChanged(camera: Bool, microphone: Bool) {
        if usesCamera != camera { usesCamera = camera }
        if usesMicrophone != microphone { usesMicrophone = microphone }
    }
    /// The colour the page itself asked for; a colour chosen for the site stands in for it.
    private var pageTint: PageTint?
    func engineThemeColorChanged(_ tint: PageTint?) { pageTint = tint; applySiteLook() }
    func applySiteLook() {
        let wanted = owner?.siteLook(forHost: url?.host) ?? pageTint
        if wanted != self.tint { self.tint = wanted }
    }

    /// Set by the engine once the page is read; the phone layout keeps only such pages clear of the status bar and the dock.
    private(set) var fixedTop = false
    private(set) var fixedBottom = false
    func engineFixedBars(top: Bool, bottom: Bool) {
        guard top != fixedTop || bottom != fixedBottom else { return }
        fixedTop = top; fixedBottom = bottom
        if owner?.activeID == id { owner?.pageFixedBarsChanged(self) }
    }

    /// Reads who the site's certificate says it is. Done after a page has loaded, when the connection's details exist; nothing is fetched.
    func refreshIdentity() {
        guard let host = url?.host, url?.scheme == "https" else { identity = nil; return }
        Task { [weak self] in
            guard let self else { return }
            let der = await engine.connectionCertificate()
            let parsed = der.flatMap { CertificateIdentity.parse(der: $0, host: host) }
            if parsed != identity { identity = parsed }
        }
    }

    func refreshAudio() async {
        guard !isDiscarded, !isBlank else { if playingAudio { playingAudio = false }; return }
        let now = await engine.audioPlaying()
        if now != playingAudio {
            playingAudio = now
            if now { owner?.noteMediaStarted(self); owner?.applyAudioFocus(startedIn: self) }
        }
    }

    func setMuted(_ on: Bool) {
        muted = on
        Task { await engine.setMuted(on); await refreshAudio() }
    }

    func engineDidFinishLoading() {
        applyBottomInset()
        applySiteLook()
        watchConsent()
        owner?.sponsorCheck(self)
        if muted { Task { await engine.setMuted(true) } }
        if !showingError { owner?.didFinishLoading(self) }
        refreshIdentity()
        engine.setGestures(owner?.gestureOptions ?? GestureOptions())
        applySavedZoom()
        applyBottomInset()
        applyWebsiteAppearance()
        applyDarkPages()
        applySiteStyle()
        if !pageActions.isEmpty { applyPageActions() }
        // Break mode holds for pages that finish loading while it is on.
        if owner?.breakActive == true { engine.runPageScript(PowerScripts.pause, arguments: [:]) }
        if !isPrivate { owner?.offerToFillLogin(in: self) }
        // Ads and trackers keep asking after the page has loaded, so the count is read twice more.
        for delay in [1.5, 6.0] { Task { try? await Task.sleep(for: .seconds(delay)); await refreshBlocked() } }
    }

    /// Reads how many loads the rules refused on this page and adds the new ones to the totals.
    func refreshBlocked() async {
        guard !isInternalPage, !isBlank else { return }
        let count = await engine.blockedAttempts()
        guard count > blockedRecorded else { return }
        owner?.recordBlocked(count - blockedRecorded, host: url?.host, privateTab: leavesNoTrace)
        blockedRecorded = count
        blockedOnPage = count
    }

    /// The page's own style sheet from Settings (per website), if the user wrote one.
    func applySiteStyle() { engine.setSiteStyle(owner?.siteStyle(forHost: url?.host)) }

    func applyPageActions() {
        guard !isInternalPage else { return }
        engine.runPageScript(PowerScripts.pageActions, arguments: ["css": PageAction.css(for: pageActions) ?? NSNull()])
    }

    var enginePrivate: Bool { isPrivate }

    func engineSavedSignIn(space: SignInSpace) -> (user: String, password: String)? {
        guard !isPrivate, let model = owner else { return nil }
        return SignInVault.saved(space: space, profile: model.profileName).map { ($0.user, $0.password) }
    }

    func engineRememberSignIn(space: SignInSpace, user: String, password: String) {
        guard privacy.canSaveLogins, let model = owner else { return }
        SignInVault.remember(space: space, user: user, password: password, profile: model.profileName)
    }

    /// A private tab never touches the saved sign-ins: a wrong password typed there must not delete one saved in a normal tab.
    func engineForgetSignIn(space: SignInSpace) {
        guard privacy.canSaveLogins, let model = owner else { return }
        SignInVault.forget(space: space, profile: model.profileName)
    }

    func engineIconsFound(_ candidates: [IconCandidate], page: URL) {
        // Normal tabs only, and only if the user allows it: the request goes to the site itself, so a private tab never makes one.
        // The icon belongs to `page`, the address the links were read from, even if this tab has since moved on.
        guard !leavesNoTrace, owner?.fetchSiteIcons == true else { return }
        Task { await FaviconStore.shared.learn(pageURL: page, declared: candidates) }
    }

    func engineLoadFailed(url failed: URL?, description: String) {
        engineLoadFailed(url: failed, domain: "", code: 0, description: description)
    }

    /// A page failed to load. What the error page says is decided from the system's own evidence (see `BrowserErrorClassifier`), never from the wording of the message.
    func engineLoadFailed(url failed: URL?, domain: String, code: Int, description: String) {
        let online = DeviceNetwork.shared.isOnline
        // A failure with no domain at all (an engine that gives only words) is shown as a plain problem with the site.
        guard let kind = domain.isEmpty ? .serverUnavailable : BrowserErrorClassifier.classify(domain: domain, code: code, deviceOnline: online) else { return }
        var info = BrowserErrorInfo(kind: kind, url: failed ?? url, domain: domain, code: code, detail: description, deviceOnline: online)
        if kind == .protectionBlocked { info.blockReason = .contentFilter }
        show(error: info)
    }

    #if DEBUG
    /// Development only: puts up an error page of a given kind with plausible evidence, to look at it (BS_SHOW_ERROR on the command line).
    func debugShowError(_ kind: BrowserErrorKind) {
        var info = BrowserErrorInfo(kind: kind, url: URL(string: "https://example.com/some/page"), deviceOnline: kind == .noInternet ? false : true)
        switch kind {
        case .noInternet: info.domain = NSURLErrorDomain; info.code = NSURLErrorNotConnectedToInternet
        case .dnsFailure: info.domain = NSURLErrorDomain; info.code = NSURLErrorCannotFindHost
        case .timedOut: info.domain = NSURLErrorDomain; info.code = NSURLErrorTimedOut
        case .serverUnavailable: info.domain = NSURLErrorDomain; info.code = NSURLErrorCannotConnectToHost
        case .pageMissing: info.httpStatus = 404
        case .certificate: info.domain = NSURLErrorDomain; info.code = NSURLErrorServerCertificateHasBadDate
        case .protectionBlocked: info.blockReason = .contentFilter; info.domain = "WebKitErrorDomain"; info.code = 104
        case .unsupportedContent: info.domain = "WebKitErrorDomain"; info.code = 101
        case .processCrashed: info.domain = "WKErrorDomain"; info.code = 4; info.crashCount = 2
        case .fileFailure: info.url = URL(string: "file:///Users/example/Documents/report.html"); info.domain = NSURLErrorDomain; info.code = NSURLErrorFileDoesNotExist
        case .syncFailure, .mediaFailure: break
        }
        show(error: info)
    }
    #endif

    /// The page was not opened because the browser's own protection stopped it (the person's threat list, or a policy), and the tab says which.
    func showProtectionBlock(for blocked: URL, reason: BlockReason) {
        show(error: BrowserErrorInfo(kind: .protectionBlocked, url: blocked, blockReason: reason))
    }

    /// An empty error answer from the site: a bare 404 or 503.
    func engineHTTPFailure(url failed: URL?, status: Int) {
        guard let kind = BrowserErrorClassifier.classify(httpStatus: status, bodyIsEmpty: true) else { return }
        show(error: BrowserErrorInfo(kind: kind, url: failed ?? url, httpStatus: status, deviceOnline: DeviceNetwork.shared.isOnline))
    }

    private func show(error info: BrowserErrorInfo) {
        showingError = true
        failedURL = info.url
        errorInfo = info
        ReliabilityStats.shared.noteFailedNavigation(info.kind.rawValue)
        // Only a missing network earns an automatic try, once, when the network returns. A timeout, a refused connection, a bad certificate or a missing page waits for the
        // person: there is no loop of retries with growing delays, and nothing is ever re-sent that was not a plain page load.
        if ErrorRetryPolicy.triesWhenNetworkReturns(info.kind), !autoRetryUsed, let target = info.url {
            DeviceNetwork.shared.onceOnline(id: id) { [weak self] in
                guard let self, self.showingError, self.failedURL == target else { return }
                self.autoRetryUsed = true
                self.autoRetrying = true
                self.load(target)
            }
        }
    }

    private var autoRetryUsed = false
    private var autoRetrying = false

    /// Loads `target` again as soon as the app is on screen (at once when it already is).
    private func reloadWhenVisible(_ target: URL) {
        Task { @MainActor [weak self] in
            #if os(iOS)
            if UIApplication.shared.applicationState != .active {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { break }
            }
            #endif
            guard let self, !self.isDiscarded, !self.showingError else { return }
            self.load(target)
        }
    }

    func engineProcessCrashed() {
        ReliabilityStats.shared.noteTabCrash()
        let verdict = crashGuard.record(at: Date())
        // The first time in a while, the page is simply brought back, as Safari does: on an iPhone the system ends a page's process whenever memory is short,
        // most often while the app sits in the background, and a screen saying so is of no use to anyone. A tab that is on screen is reloaded when the app is
        // in front again; one that is not is put to sleep and loads when it is next opened. Only a page that dies again soon is shown an error.
        if case .first = verdict, let target = url ?? engine.currentURL, !isInternalPage {
            showingError = false
            failedURL = nil
            if owner?.activeID == id { reloadWhenVisible(target); return }
            // Put to sleep a moment later, not from inside WebKit's own notice that the process ended: that builds a new page view, which asks WebKit to start a process while it is still
            // reporting the failure of one, and when no process can be started (the system refuses, memory is gone) the two wait on each other and the whole app freezes.
            if !isPrivate, !isDiscarded, let model = owner, model.tabMeta[id]?.scratch != true {
                DispatchQueue.main.async { [weak self] in self?.discard(reason: "its page process ended while it was in the background", afterProcessEnd: true) }
                return
            }
        }
        // Renderer crash: only this tab is affected; reload on demand.
        var info = BrowserErrorInfo(kind: .processCrashed, url: url, domain: "WKErrorDomain", code: 4, deviceOnline: DeviceNetwork.shared.isOnline)
        switch verdict {
        case .first: info.crashCount = 1
        case .repeated(let count): info.crashCount = count
        case .loop: info.reloadPaused = true
        }
        show(error: info)
    }

    func engineDecideNavigation(url target: URL, mainFrame: Bool) -> NavDecision {
        let model = owner
        // A web app shows only its own sites; anything else opens outside it.
        if let decision = webAppDecision(for: target, mainFrame: mainFrame) { return decision == .allow ? .allow : .external }
        // The browser identity chosen for this site (if any) is in place before the request goes out.
        if mainFrame { engine.setUserAgent(model?.siteUserAgent(forHost: target.host)) }
        // An installed extension's own pages (its options page, say) are part of the browser, not the web.
        if let scheme = target.scheme?.lowercased(), scheme != "http", scheme != "https", !isPrivate,
           model?.extensionCenter.owns(url: target) == true {
            return .allow
        }
        // The one saved page the person just chose to open from the Saved Pages list.
        if mainFrame, target.isFileURL, let allowed = allowedLocalFile, target.standardizedFileURL == allowed.standardizedFileURL { allowedLocalFile = nil; return .allow }
        // The "saved copy" link on a failed page. It is only honoured while this tab is showing its own error page, and it names no address.
        if mainFrame, showingError, target.scheme == "browsersetu", target.host == "savedcopy" {
            let page = failedURL
            Task { @MainActor [weak self] in
                guard let self, let model = self.owner else { return }
                await model.openSavedCopy(of: page, in: self)
            }
            return .deny
        }
        let decision = NavigationPolicy.decide(url: target, mainFrame: mainFrame)
        switch decision {
        case .allow: break
        case .external: model?.confirmExternal(target)
        case .deny:
            if mainFrame { model?.notice = "Blocked a navigation to “\(target.scheme ?? "unknown")”." }
        }
        guard decision == .allow, mainFrame, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let model else {
            return decision
        }
        // "When this site opens" rules: a page that belongs somewhere else is opened there, or filed, before it loads here.
        if let outcome = SiteOpenRules.outcome(forHost: target.host, rules: model.workbench.siteRules, tabIsPrivate: isPrivate,
                                               tabContainer: model.tabMeta[id]?.container, tabGroup: group, tabWorkspace: workspace) {
            switch outcome {
            case .openElsewhere(let toPrivate, let container):
                DispatchQueue.main.async { [weak self, weak model] in
                    guard let self, let model else { return }
                    model.openTab(url: target, isPrivate: toPrivate, container: container)
                    // A tab that only existed for this address (nothing was ever shown in it) is not left behind empty; one with a page keeps showing that page.
                    if !self.hasLoadedPage, model.tabs.count > 1 { model.closeTab(id: self.id, force: true) }
                    else { self.url = self.engine.currentURL; self.pendingURL = nil }
                }
                return .deny
            case .moveToGroup(let name): model.moveTab(self, to: name)
            case .moveToWorkspace(let name): model.moveTab(self, toWorkspace: name)
            }
        }
        // The user's own threat list comes first; then link cleaning re-issues the navigation without trackers.
        if let host = target.host, model.shouldWarnAboutThreat(host: host) {
            model.presentThreatWarning(for: target, in: self)
            return .deny
        }
        // An address that imitates a well-known site is held back until the person says to go on.
        if mainFrame, let host = target.host, let finding = model.lookalikeFinding(host: host) {
            model.presentLookalikeWarning(finding, for: target, in: self)
            return .deny
        }
        // A tracker's redirect page (a click logger) is skipped: the visit goes to where it would have sent you.
        if mainFrame, let direct = model.skipRedirect(target, in: self) {
            DispatchQueue.main.async { [weak self] in self?.load(direct) }
            return .deny
        }
        if mainFrame { model.describeUnfamiliarRedirect(target, in: self) }
        // A link through an AMP cache goes straight to the site's own page.
        if let own = model.deAMPedLink(target) {
            DispatchQueue.main.async { [weak self] in self?.load(own) }
            return .deny
        }
        if let cleaned = model.cleanedLink(target) {
            DispatchQueue.main.async { [weak self] in self?.load(cleaned) }
            return .deny
        }
        return decision
    }

    func engineOpenInNewTab(url target: URL, userInitiated: Bool) {
        guard let model = owner else { return }
        if let app = governingWebApp {
            // A page in a web app that asks for a new window: inside the app only if the app allows pop-ups and the site is its own; otherwise outside.
            if app.allowsPopups, app.allows(target), userInitiated { load(target) } else if userInitiated { Self.openOutside(target) }
            return
        }
        // In a Glance preview a window request stays in the preview (with a click) or is dropped (without one).
        if model.glance.isGlance(self) { model.glance.handlePopup(url: target, userInitiated: userInitiated, in: self); return }
        // Pop-ups without a user gesture are dropped; the rest open as tabs and still pass policy.
        guard userInitiated else {
            model.notice = "A pop-up was blocked."
        model.recordSecurity(kind: "popup", site: self.url?.host ?? "", detail: "Blocked a pop-up" + (url?.host.map { " to \($0)" } ?? ""), isPrivate: isPrivate)
            return
        }
        model.openTab(url: target, isPrivate: isPrivate, opener: self, container: model.tabMeta[id]?.container, scratch: model.tabMeta[id]?.scratch == true)
    }

    func engineRequestPermission(origin: String, kinds: [PermissionType]) async -> Bool {
        guard let model = owner else { return false }
        if let app = governingWebApp, kinds.contains(.notifications), !app.notifications { return false }
        return await model.resolvePermission(origin: origin, kinds: kinds, isPrivate: isPrivate)
    }

    func engineRequestClose() {
        // A window the page opened closes itself when it is done (a sign-in, a payment); the page that opened it comes back to the front.
        guard let model = owner else { return }
        let parent = model.tabMeta[id]?.parent
        let wasActive = model.activeID == id
        model.closeTab(id: id, force: true)
        if wasActive, let parent, model.tabs.contains(where: { $0.id == parent }) { model.select(parent) }
    }

    func engineOpenPopup(configuration: AnyObject) -> TabEngine? {
        if governingWebApp != nil { return nil }       // a web app has no second window: its pop-up requests are handled as links (see engineOpenInNewTab)
        // A page in a Glance preview cannot make tabs or windows: it is not allowed to grow into the person's browser.
        if owner?.glance.isGlance(self) == true { owner?.notice = "A pop-up in the preview was blocked."; return nil }
        return owner?.openPopupTab(configuration: configuration, opener: self).engine
    }

    func engineBlockedPopup(url: URL?) {
        guard let model = owner else { return }
        blockedPopup = url ?? URL(string: "about:blank")
        model.notice = "A pop-up was blocked."
        let shown = blockedPopup
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if self?.blockedPopup == shown { self?.blockedPopup = nil }
        }
    }

    func engineSuspiciousRedirect(sites: [String]) {
        guard let model = owner else { return }
        model.notice = "This page passed through \(sites.count) different sites to get here."
        model.recordSecurity(kind: "redirect", site: sites.last ?? "", detail: "Redirected through " + sites.joined(separator: " → "), isPrivate: isPrivate)
    }

    func enginePopupsAllowedWithoutGesture() -> Bool { owner?.popupsAllowed(forHost: url?.host) ?? false }
}

/// A sign-in typed but not yet kept. Never written anywhere; gone when the page changes or the tab closes.
struct PendingLogin: Equatable {
    let origin: String
    let user: String
    let password: String
}
