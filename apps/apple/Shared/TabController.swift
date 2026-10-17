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
    private(set) var engine: TabEngine!

    @Published var title: String
    @Published var url: URL?
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isSecure = false
    /// The colour the page declares for browser chrome, if any.
    @Published var tint: PageTint?
    @Published var group: String
    @Published var pinned: Bool
    @Published var workspace: String
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

    init(info: TabInfo, model: BrowserModel, restoredURL: URL? = nil) {
        id = info.id
        isPrivate = info.private
        title = info.title
        group = info.group
        pinned = info.pinned
        workspace = info.workspace
        url = restoredURL
        pendingURL = restoredURL
        self.owner = model
        engine = model.engine.makeTab(isPrivate: info.private, profile: model.profileName, container: info.private ? nil : model.tabMeta[info.id]?.container, events: self)
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

    func load(_ target: URL) {
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
        guard !isBlank, !isDiscarded, Date().timeIntervalSince(lastSnapshotAt) > 2 else { return }
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
        self.url = url
        pendingURL = nil
        owner?.tabURLChanged(self)
        if !isPrivate { owner?.extensionCenter.tabChanged(self) }
    }

    func engineLoadingChanged(isLoading: Bool, canGoBack: Bool, canGoForward: Bool) {
        // A new page starts at its top, so the toolbar comes back with it.
        if isLoading, !self.isLoading, owner?.activeID == id { owner?.expandChrome() }
        self.isLoading = isLoading
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        if !isPrivate { owner?.extensionCenter.tabChanged(self) }
    }

    func engineProgress(_ progress: Double) { self.progress = progress }

    func engineWantsLoginCapture() -> Bool { !isPrivate && owner?.saveLoginsEnabled == true }
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
    func engineThemeColorChanged(_ tint: PageTint?) { self.tint = tint }

    func engineDidFinishLoading() {
        if !showingError { owner?.didFinishLoading(self) }
        engine.setGestures(owner?.gestureOptions ?? GestureOptions())
        applySavedZoom()
        applyBottomInset()
        applyWebsiteAppearance()
        applyDarkPages()
        applySiteStyle()
        if !isPrivate { owner?.offerToFillLogin(in: self) }
    }

    /// The page's own style sheet from Settings (per website), if the user wrote one.
    func applySiteStyle() { engine.setSiteStyle(owner?.siteStyle(forHost: url?.host)) }

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
        // The user's own threat list comes first; then link cleaning re-issues the navigation without trackers.
        if let host = target.host, model.shouldWarnAboutThreat(host: host) {
            model.presentThreatWarning(for: target, in: self)
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
            return
        }
        model.openTab(url: target, isPrivate: isPrivate, opener: self, container: model.tabMeta[id]?.container, scratch: model.tabMeta[id]?.scratch == true)
    }

    func engineRequestPermission(origin: String, kinds: [PermissionType]) async -> Bool {
        guard let model = owner else { return false }
        return await model.resolvePermission(origin: origin, kinds: kinds, isPrivate: isPrivate)
    }

    func engineRequestClose() {
        owner?.closeTab(id: id)
    }
}
