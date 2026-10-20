import SwiftUI

/// One browsing context in the shell. Engine-neutral: it owns a `TabEngine`, enforces core policy
/// on every navigation the engine proposes, and publishes state for the UI.
@MainActor
final class TabController: ObservableObject, Identifiable, TabEngineEvents {
    let id: UInt64
    let isPrivate: Bool
    /// Weak on purpose: the engine can report an event for a tab after its model is gone (a model that was released
    /// while a page was still loading). An `unowned` reference would crash there; a weak one just ignores the event.
    private weak var owner: BrowserModel?

    /// The tab now belongs to another window.
    func reassign(to model: BrowserModel) { owner = model }
    private(set) var engine: TabEngine!

    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isSecure = false
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
    private(set) var isDiscarded = false
    private var savedState: Any?
    private var crashGuard = CrashGuard()

    /// Set for restored tabs whose page has not been loaded yet.
    private var pendingURL: URL?
    private var showingError = false
    private var failedURL: URL?

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
            ?? model.engine.makeTab(isPrivate: info.private, profile: model.profileName, container: info.private ? nil : model.tabMeta[info.id]?.container, events: self)
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
        if !autoRetrying { retryAttempt = 0 }
        autoRetrying = false
        // Moving to a different site starts the crash count again.
        if target.host != url?.host { crashGuard.reset() }
        pendingURL = nil
        showingError = false
        url = target
        engine.load(target)
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
    private(set) var sleepReason = ""

    func discard(reason: String = "not used for a while, to save memory") {
        guard !isPrivate, !isDiscarded, engine.currentURL != nil, let model = owner else { return }
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

    /// Dark pages: first ask the site for its own dark design (a site that has one shows it, and looks right). Only a page that is still
    /// light after that is inverted. Turned off, the site goes back to the look chosen for websites in Settings.
    func applyDarkPages() {
        let want = owner?.shouldDarken(host: url?.host) ?? false
        guard want != darkened || want else { return }
        darkened = want
        if want {
            engine.setWebsiteAppearance("dark")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))     // a site changes its colours when the system look changes
                guard let self, self.darkened else { return }
                self.engine.setPageDarkening(true)
            }
        } else {
            engine.setPageDarkening(false)
            applyWebsiteAppearance()
        }
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
        owner?.rememberZoom(engine.zoomFactor, forHost: url?.host)
    }

    func resetZoom() {
        engine.zoomFactor = 1
        owner?.rememberZoom(1, forHost: url?.host)
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
        if isReading, url != readerOrigin { isReading = false; readerOrigin = nil }
        if identity != nil, identity?.host != url.host { identity = nil }
        if self.url?.host != url.host { typedLogin = nil }
        self.url = url
        pendingURL = nil
        owner?.tabURLChanged(self)
        if !isPrivate { owner?.extensionCenter.tabChanged(self) }
    }

    func engineLoadingChanged(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
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

    func engineWantsLoginCapture() -> Bool { !isPrivate && owner?.saveLoginsEnabled == true }
    func engineLinkAction(_ url: URL, _ action: LinkAction) {
        guard let model = owner, url.scheme == "http" || url.scheme == "https" else { return }
        let container = model.tabMeta[id]?.container
        switch action {
        case .newTab: model.openTab(url: url, isPrivate: isPrivate, opener: self, container: container)
        case .backgroundTab: model.openTab(url: url, isPrivate: isPrivate, select: false, opener: self, container: container)
        case .privateTab: model.openTab(url: url, isPrivate: true)
        case .otherPane: model.openInOtherPane(url, from: self)
        case .split:
            let tab = model.openTab(url: url, isPrivate: isPrivate, select: false, opener: self, container: container)
            if model.splitTabID == nil { model.openSplit(with: tab) } else { model.addThirdPanel(with: tab) }
        }
    }
    func engineLoginTyped(origin: String, user: String, password: String) {
        guard !isPrivate, let model = owner, model.saveLoginsEnabled else { return }
        let kept = WebLoginVault.list(origin: origin, profile: model.profileName)
        guard LoginRules.offer(origin: origin, user: user, password: password, kept: kept, neverFor: model.neverSaveOrigins) != .nothing else { typedLogin = nil; return }
        typedLogin = PendingLogin(origin: origin, user: user, password: password)
    }

    func engineLoginFieldFocused(origin: String?, usernameOnly: Bool) { if !isPrivate { owner?.offerToFillLogin(in: self, frameOrigin: origin, usernameOnly: usernameOnly) } }
    func engineLoginSubmitted(origin: String, user: String, password: String) { owner?.loginSubmitted(origin: origin, user: user, password: password, in: self) }

    func engineVimKey(_ key: String) -> Bool {
        guard let model = owner, model.activeID == id else { return false }
        return model.workbench.handleVimKey(key)
    }

    func engineScrolled(deltaY: Double) {
        guard let model = owner, model.activeID == id else { return }
        model.pageScrolled(deltaY: deltaY)
    }
    func engineSecurityChanged(_ secure: Bool) { isSecure = secure }
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
            if now { owner?.noteMediaStarted(self) }
        }
    }

    func setMuted(_ on: Bool) {
        muted = on
        Task { await engine.setMuted(on); await refreshAudio() }
    }

    func engineDidFinishLoading() {
        applySiteLook()
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
        owner?.recordBlocked(count - blockedRecorded, host: url?.host, privateTab: isPrivate)
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
        guard !isPrivate, let model = owner else { return }
        SignInVault.remember(space: space, user: user, password: password, profile: model.profileName)
    }

    /// A private tab never touches the saved sign-ins: a wrong password typed there must not delete one saved in a normal tab.
    func engineForgetSignIn(space: SignInSpace) {
        guard !isPrivate, let model = owner else { return }
        SignInVault.forget(space: space, profile: model.profileName)
    }

    func engineIconsFound(_ urls: [URL]) {
        // Normal tabs only, and only if the user allows it: the request goes to the site itself, so a private tab never makes one.
        guard !isPrivate, owner?.fetchSiteIcons == true, let page = url else { return }
        Task { await FaviconStore.shared.learn(pageURL: page, candidates: urls) }
    }

    func engineLoadFailed(url failed: URL?, description: String) {
        showingError = true
        failedURL = failed ?? url
        let problem = NetworkProblem(description: description)
        ReliabilityStats.shared.noteFailedNavigation(String(describing: problem))
        engine.showErrorPage(title: problem.title, detail: problem.detail(raw: description), baseURL: failedURL)
        if problem.retriesAutomatically, retryAttempt < 6 {
            retryAttempt += 1
            scheduleRetry(of: failedURL, after: Double(min(60, 5 * retryAttempt * retryAttempt)))
        }
    }

    private var retryAttempt = 0
    private var autoRetrying = false

    /// A page that failed because the connection was missing or dropped is tried again by itself, a little later each time, for as long as
    /// the tab still shows that failure. Anything else the person does with the tab ends it.
    private func scheduleRetry(of target: URL?, after seconds: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.showingError, let target, self.failedURL == target else { return }
            self.autoRetrying = true
            self.load(target)
        }
    }

    func engineProcessCrashed() {
        ReliabilityStats.shared.noteTabCrash()
        // Renderer crash: only this tab is affected; reload on demand.
        showingError = true
        failedURL = url
        switch crashGuard.record(at: Date()) {
        case .first:
            engine.showErrorPage(title: "This tab stopped unexpectedly",
                                 detail: "The page’s process ended. Reload to try again.", baseURL: url)
        case .repeated(let count):
            engine.showErrorPage(title: "This tab stopped unexpectedly again",
                                 detail: "It has happened \(count) times in a couple of minutes. Reload to try once more.", baseURL: url)
        case .loop:
            engine.showErrorPage(title: "This page keeps crashing",
                                 detail: "Reloading is paused for a minute. Open a different page, or come back to this one later.", baseURL: url)
        }
    }

    func engineDecideNavigation(url target: URL, mainFrame: Bool) -> NavDecision {
        let model = owner
        // The browser identity chosen for this site (if any) is in place before the request goes out.
        if mainFrame { engine.setUserAgent(model?.siteUserAgent(forHost: target.host)) }
        // An installed extension's own pages (its options page, say) are part of the browser, not the web.
        if let scheme = target.scheme?.lowercased(), scheme != "http", scheme != "https", !isPrivate,
           model?.extensionCenter.owns(url: target) == true {
            return .allow
        }
        // The one saved page the person just chose to open from the Saved Pages list.
        if mainFrame, target.isFileURL, let allowed = allowedLocalFile, target.standardizedFileURL == allowed.standardizedFileURL { allowedLocalFile = nil; return .allow }
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
        owner?.openPopupTab(configuration: configuration, opener: self).engine
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
