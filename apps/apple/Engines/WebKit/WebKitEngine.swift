import SetuPrivacyCore
import SetuPrivacyWebKit
import SwiftUI
import Network
import WebKit
#if os(macOS)
import AppKit
#endif

/// WebKit implementation of the engine contract, shared by macOS and iOS.
@MainActor
final class WebKitEngine: BrowserEngine {
    let name = "WebKit"
    let downloads = DownloadCoordinator()

    private let downloadDelegate: WebKitDownloads
    private var privateStore: WKWebsiteDataStore?
    private var proxy: (config: ProxyConfig, password: String?)?
    private var webPolicy = WebPolicy()
    let rules = ContentRuleInstaller()
    private let tabs = NSHashTable<WebKitTab>.weakObjects()
    /// A `WebKitExtensionManager` on systems that have WebKit extension support; type-erased because it is availability-gated.
    private var extensionManager: AnyObject?
    private var userScripts: [UserScript] = []

    init() {
        downloadDelegate = WebKitDownloads(coordinator: downloads)
        downloads.resumer = { [weak self] data in
            guard let self, let view = self.tabs.allObjects.first?.hostView as? WKWebView else { return }
            self.downloadDelegate.resume(data, in: view)
        }
        // Starts a download again from its address (a scheduled one, or a retry with nothing to resume), using any open page's web view and its cookies.
        downloads.starter = { [weak self] url in
            guard let self, let view = self.tabs.allObjects.first?.hostView as? WKWebView else { return }
            self.downloadDelegate.start(url, in: view)
        }
    }

    func prepare() async {}

    func makeConfiguration(isPrivate: Bool, profile: String, container: String? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isPrivate {
            if privateStore == nil { privateStore = .nonPersistent() }
            config.websiteDataStore = privateStore!
        } else if container == TabOrganizing.scratchContainer {
            config.websiteDataStore = .nonPersistent()                     // gone with the tab
        } else if let container {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: ProfileIdentity.dataStoreID(for: profile + "#" + container))
        } else {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: ProfileIdentity.dataStoreID(for: profile))
        }
        applyProxy(to: config.websiteDataStore)
        // A web view announces itself without the "Version/… Safari/…" part that Safari adds, and many sites (Google's home page
        // among them) answer such a browser with a stripped-down page. Announce it the way Safari does, with this system's number.
        config.applicationNameForUserAgent = "Version/\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0 Safari/605.1.15"
        config.upgradeKnownHostsToHTTPS = true
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // The fullscreen button on web video: without this, YouTube and every other player has no working fullscreen.
        config.preferences.isElementFullscreenEnabled = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        #if os(iOS)
        config.allowsPictureInPictureMediaPlayback = true
        #endif
        // Registered before the web view exists, so even its first request is filtered.
        rules.register(config.userContentController)
        if !isPrivate { UserScriptInstaller.addErrorCollector(to: config.userContentController) }
        // The user's own scripts, in normal tabs only.
        if !isPrivate { UserScriptInstaller.install(userScripts, policy: webPolicy, into: config.userContentController) }
        else {
            UserScriptInstaller.addScrollbarHider(to: config.userContentController)
            UserScriptInstaller.addPolicyScripts(webPolicy, to: config.userContentController)
            UserScriptInstaller.addBrowserScripts(to: config.userContentController, signInWatcher: false)
        }
        // Extensions never run in private tabs.
        if !isPrivate, #available(macOS 15.4, iOS 18.4, *), let manager = extensionManager as? WebKitExtensionManager {
            config.webExtensionController = manager.controller
        }
        return config
    }

    func makePopupTab(configuration: AnyObject, events: TabEngineEvents) -> TabEngine? {
        guard let configuration = configuration as? WKWebViewConfiguration else { return nil }
        let tab = WebKitTab(configuration: configuration, events: events, downloads: downloadDelegate)
        tabs.add(tab)
        wireMediaGuard(tab)
        return tab
    }

    /// iPhone only: tells the tab when its media must wait for a tap (the switch is on and the site is not an exception).
    private func wireMediaGuard(_ tab: WebKitTab) {
        #if os(iOS)
        tab.mediaGuardActive = { [weak self, weak tab] in
            guard let self, let tab, self.webPolicy.blockAutoplay else { return false }
            let key = FaviconStore.key(forHost: tab.webView.url?.host)
            return key.map { !self.webPolicy.autoplayExceptions.contains($0) } ?? true
        }
        #endif
    }

    func makeTab(isPrivate: Bool, profile: String, container: String?, events: TabEngineEvents) -> TabEngine {
        let tab = WebKitTab(configuration: makeConfiguration(isPrivate: isPrivate, profile: profile, container: container),
                            events: events, downloads: downloadDelegate)
        tabs.add(tab)
        wireMediaGuard(tab)
        return tab
    }

    func applyProtection(_ snapshot: PolicySnapshot?) async -> InstallReport {
        await rules.apply(snapshot)
    }

    func setUserScripts(_ scripts: [UserScript]) {
        userScripts = scripts
        for tab in tabs.allObjects {
            guard let view = tab.hostView as? WKWebView, view.configuration.websiteDataStore.isPersistent else { continue }
            UserScriptInstaller.install(scripts, policy: webPolicy, into: view.configuration.userContentController)
        }
    }

    func setWebPolicy(_ new: WebPolicy) {
        guard new != webPolicy else { return }
        webPolicy = new
        // Open pages keep what they already loaded; the next load of each one follows the new policy.
        for tab in tabs.allObjects {
            guard let view = tab.hostView as? WKWebView else { continue }
            if view.configuration.websiteDataStore.isPersistent { UserScriptInstaller.install(userScripts, policy: new, into: view.configuration.userContentController) }
        }
    }

    func privateSessionEnded() {
        privateStore = nil
    }

    func setProxy(_ proxy: ProxyConfig?, password: String?) {
        self.proxy = proxy.map { ($0, password) }
        for tab in tabs.allObjects { if let view = tab.hostView as? WKWebView { applyProxy(to: view.configuration.websiteDataStore) } }
        if let privateStore { applyProxy(to: privateStore) }
    }

    /// Fails closed: if the proxy cannot be reached the page does not load, rather than going out directly.
    private func applyProxy(to store: WKWebsiteDataStore) {
        guard let proxy, let port = NWEndpoint.Port(rawValue: UInt16(clamping: proxy.config.port)) else {
            if !store.proxyConfigurations.isEmpty { store.proxyConfigurations = [] }
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(proxy.config.host), port: port)
        var configuration = proxy.config.kind == .socks5 ? ProxyConfiguration(socksv5Proxy: endpoint) : ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        if !proxy.config.username.isEmpty { configuration.applyCredential(username: proxy.config.username, password: proxy.password ?? "") }
        configuration.allowFailover = false
        store.proxyConfigurations = [configuration]
    }

    func cookies(profile: String, isPrivate: Bool) async -> [CookieInfo] {
        let store: WKWebsiteDataStore
        if isPrivate {
            guard let privateStore else { return [] }
            store = privateStore
        } else {
            store = WKWebsiteDataStore(forIdentifier: ProfileIdentity.dataStoreID(for: profile))
        }
        return await store.httpCookieStore.allCookies().map { CookieInfo(name: $0.name, value: $0.value, domain: $0.domain) }
    }

    func clearData(profile: String) async {
        let store = WKWebsiteDataStore(forIdentifier: ProfileIdentity.dataStoreID(for: profile))
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func attachExtensions(center: ExtensionCenter, profile: String, directory: URL, host: ExtensionHost) {
        if #available(macOS 15.4, iOS 18.4, *) {
            let manager = WebKitExtensionManager(profile: profile, directory: directory, center: center, host: host)
            extensionManager = manager
            center.attach(manager, supported: true)
            Task { await manager.start() }
        } else {
            extensionManager = nil
            center.attach(nil, supported: false)
        }
    }

    func siteData(profile: String) async -> [SiteDataInfo] {
        let store = WKWebsiteDataStore(forIdentifier: ProfileIdentity.dataStoreID(for: profile))
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        return records
            .map { SiteDataInfo(host: $0.displayName, kinds: Self.kinds($0.dataTypes)) }
            .filter { !$0.host.isEmpty }
            .sorted { $0.host < $1.host }
    }

    func removeSiteData(host: String, profile: String) async {
        let store = WKWebsiteDataStore(forIdentifier: ProfileIdentity.dataStoreID(for: profile))
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()).filter { $0.displayName == host }
        guard !records.isEmpty else { return }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }

    private static func kinds(_ types: Set<String>) -> [String] {
        let names: [(String, String)] = [
            (WKWebsiteDataTypeCookies, "Cookies"),
            (WKWebsiteDataTypeLocalStorage, "Local storage"),
            (WKWebsiteDataTypeIndexedDBDatabases, "IndexedDB"),
            (WKWebsiteDataTypeServiceWorkerRegistrations, "Service workers"),
            (WKWebsiteDataTypeDiskCache, "Cache"),
            (WKWebsiteDataTypeFetchCache, "Cache"),
        ]
        var seen = Set<String>(), result: [String] = []
        for (type, label) in names where types.contains(type) && seen.insert(label).inserted { result.append(label) }
        if result.isEmpty, !types.isEmpty { result.append("Other") }
        return result
    }

    func removeProfileData(profile: String) async {
        // WebKit refuses while a web view or a store object that just read the profile is still being released, so ask again a few times.
        let id = ProfileIdentity.dataStoreID(for: profile)
        for attempt in 0..<5 {
            if (try? await WKWebsiteDataStore.remove(forIdentifier: id)) != nil { return }
            if !(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id)) { return }
            try? await Task.sleep(nanoseconds: UInt64(200_000_000 * (attempt + 1)))
        }
    }

    /// Identifiers of website data stores that still exist (diagnostics and tests).
    static func existingDataStoreIDs() async -> [UUID] {
        await WKWebsiteDataStore.allDataStoreIdentifiers
    }
}

// MARK: - Tab

@MainActor
final class WebKitTab: NSObject, TabEngine, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private weak var events: TabEngineEvents?
    var eventsForLogin: TabEngineEvents? { events }
    /// The link under the pointer, as last reported by the page.
    var hoveredLink: URL?
    /// When the person last clicked, touched or typed in this page, as the page reported it.
    var lastGesture = Date.distantPast
    func performLinkAction(_ action: LinkAction) { if let url = hoveredLink { events?.engineLinkAction(url, action) } }
    private let downloads: WebKitDownloads
    private var observers: [NSKeyValueObservation] = []
    private var redirectWatch = RedirectWatch()
    #if os(iOS)
    private var lastScrollY: CGFloat?
    private var lastBoundsHeight: CGFloat = 0
    #endif

    init(configuration: WKWebViewConfiguration, events: TabEngineEvents, downloads: WebKitDownloads) {
        self.events = events
        self.downloads = downloads
        #if os(macOS)
        let reporting = ScrollReportingWebView(frame: .zero, configuration: configuration)
        webView = reporting
        #else
        webView = WKWebView(frame: .zero, configuration: configuration)
        #endif
        super.init()
        // Sign-ins the page script reports (see LoginScripts.watcher). The handler holds the tab weakly, so the tab can still go away.
        TabRegistry.tabs.setObject(self, forKey: webView)
        let controller = webView.configuration.userContentController
        // One set of handlers per content controller: a window a page opens shares its opener's controller, and adding a name twice is an error.
        if !TabRegistry.wired.contains(controller) {
            TabRegistry.wired.add(controller)
            controller.add(LoginMessageHandler(), contentWorld: .defaultClient, name: "bsLogin")
            controller.add(LinkHoverHandler(), contentWorld: .defaultClient, name: "bsLink")
            controller.add(GestureHandler(), contentWorld: .defaultClient, name: "bsGesture")
        }
        #if os(macOS)
        reporting.applyRestingColor()
        reporting.hoveredLink = { [weak self] in self?.hoveredLink }
        reporting.onLinkAction = { [weak self] action, url in self?.events?.engineLinkAction(url, action) }
        reporting.onScroll = { [weak self] delta in self?.events?.engineScrolled(deltaY: Double(delta)) }
        reporting.gesturesEnabled = { [weak self] in self?.events?.engineMouseGesturesEnabled() ?? false }
        reporting.onGesture = { [weak self] sequence, finished in self?.events?.engineMouseGesture(sequence, finished: finished) }
        reporting.onKey = { [weak self] event in
            guard let self, !self.editableFocused, event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.characters, key.count == 1 else { return false }
            return self.events?.engineVimKey(key) ?? false
        }
        // Whether a text field has the keyboard is read from the page after a click or any key the browser did not use; no message ever comes from the page.
        reporting.onInteraction = { [weak self] in self?.refreshEditableFocus() }
        #endif
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        #if os(macOS)
        webView.allowsMagnification = true
        #endif
        observe()
        #if os(iOS)
        installMediaGuard()
        #endif
    }

    #if os(iOS)
    // MARK: A second guard against media that starts by itself (iPhone)

    /// Whether this page's media is held to "a tap first" (set by the engine: the switch is on and the site is not one the person allowed).
    var mediaGuardActive: () -> Bool = { false }
    private var lastTap = Date.distantPast
    private var mediaStartedByPerson = false
    private var mediaTimer: Timer?

    /// The page's own script already refuses play() without a tap, but a site can start media in ways a script cannot see. So, as well, the tab asks WebKit what is playing
    /// a little under twice a second: playing media that follows a tap (a video you chose) is left alone for as long as it plays; media that starts with no tap behind it is paused.
    private func installMediaGuard() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(noteTap))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = self
        webView.addGestureRecognizer(tap)
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMedia() }
        }
    }

    @objc private func noteTap() { lastTap = Date() }

    private func checkMedia() {
        // Never in the background or while the video is full screen: play pressed on the lock screen, a headphone button or the player's own controls
        // is the person asking, and pausing it again is what made video feel broken.
        guard webView.window != nil, UIApplication.shared.applicationState == .active, mediaGuardActive() else { mediaStartedByPerson = false; return }
        UserTouchClock.shared.install()
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard state == .playing else { self.mediaStartedByPerson = false; return }
                if self.mediaStartedByPerson { return }
                if Date().timeIntervalSince(max(self.lastTap, UserTouchClock.shared.last)) < 6 { self.mediaStartedByPerson = true }
                else { self.webView.pauseAllMediaPlayback { } }
            }
        }
    }
    #endif

    var hostView: PlatformView { webView }
    /// A text field on the page has the keyboard.
    private var editableFocused = true
    #if os(iOS)
    private var lastViewportInsets = UIEdgeInsets.zero
    #endif

    private func refreshEditableFocus() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self else { return }
            let script = "var a = document.activeElement; if (!a) return false; var t = (a.tagName || '').toLowerCase(); return t === 'input' || t === 'textarea' || t === 'select' || a.isContentEditable === true;"
            editableFocused = ((try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? Bool) ?? true
        }
    }

    func scrollBy(_ points: Double) {
        Task { _ = try? await webView.callAsyncJavaScript("window.scrollBy({ top: points, behavior: 'smooth' });", arguments: ["points": points], contentWorld: .defaultClient) }
    }

    func showHTML(_ html: String, baseURL: URL?) { webView.loadHTMLString(html, baseURL: baseURL) }

    func setDesktopMode(_ on: Bool) {
        #if os(iOS)
        webView.configuration.defaultWebpagePreferences.preferredContentMode = on ? .desktop : .mobile
        webView.reload()
        #endif
    }

    func setMobileSite(_ on: Bool) {
        #if os(macOS)
        webView.customUserAgent = on
            ? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
            : nil
        webView.reload()
        #endif
    }

    func setJavaScriptEnabled(_ on: Bool) {
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = on
        webView.reload()
    }

    /// Makes a light page dark by inverting it, keeping pictures and video as they are. A page that is already dark is left alone.
    /// Runs in the browser's own isolated world and changes nothing but one style element.
    /// Darkening turns a light page dark by inverting it. A page that is already dark (its own dark mode) must be left alone, or it is
    /// inverted back to light-on-dark mush with invisible text. What is painted behind the page is found the way the eye would: the element
    /// in the middle of the window and each one around it, outward, until one has a solid background.
    func setPageDarkening(_ on: Bool) {
        let script = on ? """
        if (document.getElementById('bs-dark')) return true;
        const solid = (e) => {
          const m = getComputedStyle(e).backgroundColor.match(/[\\d.]+/g) || [];
          const a = m.length >= 4 ? parseFloat(m[3]) : (m.length >= 3 ? 1 : 0);
          return a > 0.5 ? [+m[0], +m[1], +m[2]] : null;
        };
        let el = document.elementFromPoint(innerWidth / 2, innerHeight / 2), color = null;
        while (el && !color) { color = solid(el); el = el.parentElement; }
        color = color || solid(document.documentElement) || [255, 255, 255];
        const luminance = 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2];
        if (luminance < 140) return false;
        const style = document.createElement('style');
        style.id = 'bs-dark';
        style.textContent = 'html{filter:invert(0.9) hue-rotate(180deg) contrast(0.95)!important;background:#fff} img,video,picture,canvas{filter:invert(0.9) hue-rotate(180deg)!important}';
        document.documentElement.appendChild(style);
        return true;
        """ : "const s = document.getElementById('bs-dark'); if (s) s.remove(); return true;"
        Task { _ = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) }
    }

    /// Which look the websites are asked for, apart from the browser's own: nil follows the system.
    /// Room at the foot of the page for a toolbar floating over it, so the last of the page can be scrolled clear of the bar.
    func setViewportInsets(top: CGFloat, bottom: CGFloat) {
        #if os(iOS)
        let insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        guard webView.scrollView.contentInset.bottom != 0 || insets != lastViewportInsets else { return }
        lastViewportInsets = insets
        // Public API (iOS 15 and later): the page lays itself out inside these insets, so its fixed headers and bottom tab bars sit clear of the status bar and the dock.
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            self.webView.setMinimumViewportInset(insets, maximumViewportInset: insets)
            self.webView.scrollView.contentInset.bottom = 0
            self.webView.scrollView.verticalScrollIndicatorInsets = .zero
        }
        #endif
    }

    func setWebsiteAppearance(_ mode: String) {
        #if os(iOS)
        webView.overrideUserInterfaceStyle = mode == "dark" ? .dark : (mode == "light" ? .light : .unspecified)
        #else
        webView.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : (mode == "light" ? NSAppearance(named: .aqua) : nil)
        #endif
    }

    func setSiteStyle(_ css: String?) {
        // The style text is passed as data, never joined into the script, so it cannot become code.
        let script = "const old = document.getElementById('bs-site-style'); if (old) old.remove(); if (css) { const s = document.createElement('style'); s.id = 'bs-site-style'; s.textContent = css; document.documentElement.appendChild(s); } return true;"
        Task { _ = try? await webView.callAsyncJavaScript(script, arguments: ["css": css ?? NSNull()], contentWorld: .defaultClient) }
    }

    func navigationEntries() -> (back: [NavEntry], forward: [NavEntry]) {
        let list = webView.backForwardList
        let back = list.backList.reversed().prefix(15).enumerated().map { NavEntry(offset: -($0.offset + 1), title: $0.element.title ?? "", url: $0.element.url) }
        let forward = list.forwardList.prefix(15).enumerated().map { NavEntry(offset: $0.offset + 1, title: $0.element.title ?? "", url: $0.element.url) }
        return (Array(back), Array(forward))
    }

    func navigate(toOffset offset: Int) {
        if let item = webView.backForwardList.item(at: offset) { webView.go(to: item) }
    }

    func blockedAttempts() async -> Int {
        let result = try? await webView.callAsyncJavaScript(BlockedCounter.read, contentWorld: .defaultClient)
        return (result as? [Any])?.count ?? 0
    }

    func runPageScript(_ script: String, arguments: [String: Any]) {
        Task { _ = try? await webView.callAsyncJavaScript(script, arguments: arguments, contentWorld: .defaultClient) }
    }

    func scrollToEdge(bottom: Bool) {
        #if os(iOS)
        let scroll = webView.scrollView
        let y = bottom ? max(-scroll.adjustedContentInset.top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                       : -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: true)
        #else
        Task { _ = try? await webView.callAsyncJavaScript("window.scrollTo({ top: edge ? Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0) : 0, behavior: 'smooth' });", arguments: ["edge": bottom], contentWorld: .defaultClient) }
        #endif
    }

    /// The size of the whole page, so the PDF and the full-page picture cover all of it and not only what is on screen.
    private func contentSize() async -> CGSize? {
        let script = "return [Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0), Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)];"
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [Any], result.count == 2,
              let w = (result[0] as? NSNumber)?.doubleValue, let h = (result[1] as? NSNumber)?.doubleValue, w > 0, h > 0 else { return nil }
        return CGSize(width: min(w, 4000), height: min(h, 30000))
    }

    func probeMediaCapabilities() async -> [String: Any]? {
        let script = """
        const out = {};
        const v = document.createElement('video');
        out.hls = v.canPlayType('application/vnd.apple.mpegurl') || v.canPlayType('application/x-mpegURL') || '';
        const MS = window.ManagedMediaSource || window.MediaSource;
        out.managedMse = !!window.ManagedMediaSource;
        if (window.MediaSource) { out.mse = { h264: MediaSource.isTypeSupported('video/mp4; codecs="avc1.640028"') }; }
        out.fullscreen = { video: !!(v.webkitEnterFullscreen || v.requestFullscreen), element: !!(document.documentElement.requestFullscreen || document.documentElement.webkitRequestFullscreen) };
        out.pip = { webkit: !!v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture'), standard: !!document.pictureInPictureEnabled };
        out.airplay = { picker: !!v.webkitShowPlaybackTargetPicker, event: 'WebKitPlaybackTargetAvailabilityEvent' in window };
        const eme = {};
        if (navigator.requestMediaKeySystemAccess) {
          const cfg = [{ initDataTypes: ['cenc', 'sinf', 'skd'], videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }], audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }] }];
          for (const [key, id] of [['fairplay', 'com.apple.fps'], ['fairplay1', 'com.apple.fps.1_0'], ['widevine', 'com.widevine.alpha'], ['playready', 'com.microsoft.playready']]) {
            try { await navigator.requestMediaKeySystemAccess(id, cfg); eme[key] = 'supported'; } catch (e) { eme[key] = (e && e.name) || 'unsupported'; }
          }
        }
        out.eme = eme;
        const decoding = {};
        const tests = { h264: 'video/mp4; codecs="avc1.640028"', hevc: 'video/mp4; codecs="hvc1.1.6.L120.90"', vp9: 'video/webm; codecs="vp09.00.10.08"', av1: 'video/mp4; codecs="av01.0.08M.08"' };
        if (navigator.mediaCapabilities) {
          for (const [k, type] of Object.entries(tests)) {
            try {
              const r = await navigator.mediaCapabilities.decodingInfo({ type: 'file', video: { contentType: type, width: 1920, height: 1080, bitrate: 6000000, framerate: 30 } });
              decoding[k] = { supported: r.supported, smooth: r.smooth, powerEfficient: r.powerEfficient };
            } catch (e) { decoding[k] = {}; }
          }
        }
        out.decoding = decoding;
        return out;
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any]
    }

    func pageHasSensitiveForm() async -> Bool {
        let r = try? await webView.callAsyncJavaScript("""
        return !!document.querySelector('input[type=password], input[autocomplete^="cc-"], input[autocomplete="one-time-code"], input[name*="card" i], input[name*="cvv" i]');
        """, contentWorld: .defaultClient)
        return (r as? NSNumber)?.boolValue ?? true
    }

    func pageNetwork() async -> PageNetworkReport {
        let js = """
        const site = h => h.split('.').slice(-2).join('.');
        const me = site(location.hostname);
        const hosts = Array.from(new Set(performance.getEntriesByType('resource').map(e => { try { return new URL(e.name).hostname; } catch (x) { return ''; } }).filter(h => h && site(h) !== me)));
        const blocked = typeof window.__bsBlockedCount === 'function' ? window.__bsBlockedCount() : [];
        return { blocked: blocked, hosts: hosts };
        """
        guard let r = try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient) as? [String: Any] else { return PageNetworkReport() }
        return PageNetworkReport(blockedURLs: r["blocked"] as? [String] ?? [], thirdPartyHosts: (r["hosts"] as? [String] ?? []).sorted())
    }

    func setScrollFraction(_ fraction: Double) async {
        _ = try? await webView.callAsyncJavaScript("const h = document.documentElement.scrollHeight - window.innerHeight; if (h > 0) window.scrollTo(0, h * f);", arguments: ["f": min(max(fraction, 0), 1)], contentWorld: .defaultClient)
    }

    func devLog() async -> DevLog? {
        guard let raw = try? await webView.callAsyncJavaScript(DevCaptureScript.read, contentWorld: .page) as? [String: Any] else { return nil }
        return DevLog(raw: raw)
    }

    func pageSource() async -> String? {
        let js = "return '<!DOCTYPE ' + (document.doctype ? document.doctype.name : 'html') + '>\\n' + document.documentElement.outerHTML;"
        let r = try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient) as? String
        return r.map { String($0.prefix(2_000_000)) }
    }

    func userAgentString() async -> String? {
        if let custom = webView.customUserAgent, !custom.isEmpty { return custom }
        return try? await webView.callAsyncJavaScript("return navigator.userAgent;", contentWorld: .defaultClient) as? String
    }

    /// Shows a file kept on this device (a saved web archive). Read access is limited to the file's own folder.
    func loadLocalFile(_ url: URL) {
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func respondsWithin(_ seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return true }
                return (try? await self.webView.callAsyncJavaScript("return 1;", contentWorld: .defaultClient)) != nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }

    func saveScrollState() async {
        let js = """
        (function () {
          var go = function () { save(); };
          if (window.requestIdleCallback) { requestIdleCallback(go, { timeout: 800 }); } else { setTimeout(go, 60); }
          function path(el) { var p = []; while (el && el !== document.body && el.parentElement) { p.unshift(el.tagName + ':' + Array.prototype.indexOf.call(el.parentElement.children, el)); el = el.parentElement; } return p.join('/'); }
          function save() {
          var out = [], all = document.body ? document.body.querySelectorAll('div, main, section, ul, ol, article') : [];
          for (var i = 0; i < all.length && i < 1500 && out.length < 30; i++) {
            var e = all[i];
            if (e.clientHeight > 120 && e.scrollHeight > e.clientHeight + 40 && e.scrollTop >= 0) {
              var oy = getComputedStyle(e).overflowY;
              if (oy === 'auto' || oy === 'scroll') { out.push({ p: path(e), top: e.scrollTop, bottom: (e.scrollHeight - e.clientHeight - e.scrollTop) < 8 }); }
            }
          }
          var de = document.documentElement;
          window.__bsScrollState = { w: { top: window.scrollY, bottom: (de.scrollHeight - window.innerHeight - window.scrollY) < 8 && de.scrollHeight > window.innerHeight + 40 }, c: out };
          }
        })();
        """
        _ = try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient)
    }

    func restoreScrollState() {
        let js = """
        (function () {
          var s = window.__bsScrollState; if (!s) { return; }
          function find(path) {
            var el = document.body;
            if (!path) { return null; }
            var parts = path.split('/');
            for (var i = 0; i < parts.length; i++) {
              var bits = parts[i].split(':'); var child = el && el.children[parseInt(bits[1], 10)];
              if (!child || child.tagName !== bits[0]) { return null; }
              el = child;
            }
            return el;
          }
          function apply() {
            var de = document.documentElement;
            if (s.w.bottom) { if (de.scrollHeight - window.innerHeight - window.scrollY > 40) { window.scrollTo(0, de.scrollHeight); } }
            else if (s.w.top > 40 && window.scrollY < s.w.top - 40) { window.scrollTo(0, s.w.top); }
            s.c.forEach(function (c) {
              var e = find(c.p); if (!e) { return; }
              if (c.bottom) { if (e.scrollHeight - e.clientHeight - e.scrollTop > 40) { e.scrollTop = e.scrollHeight; } }
              else if (c.top > 40 && e.scrollTop < c.top - 40) { e.scrollTop = c.top; }
            });
          }
          [100, 400, 1000].forEach(function (ms) { setTimeout(apply, ms); });
        })();
        """
        Task { _ = try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient) }
    }

    func audioPlaying() async -> Bool {
        let js = "return Array.from(document.querySelectorAll('video,audio')).some(m => !m.paused && !m.ended && m.readyState > 2 && m.volume > 0 && (!m.muted || m.dataset.bsMuted === '1'));"
        let r = try? await webView.callAsyncJavaScript(js, contentWorld: .defaultClient)
        return (r as? NSNumber)?.boolValue ?? false
    }

    /// Mutes by setting `muted` on every video and audio element, and again on any that starts later. Sound made another way (Web Audio) is not covered.
    func setMuted(_ on: Bool) async {
        let js = """
        window.__bsMute = on;
        const apply = () => document.querySelectorAll('video,audio').forEach(m => {
          if (window.__bsMute) { if (m.dataset.bsMuted !== '1') { m.dataset.bsWas = m.muted ? '1' : '0'; m.dataset.bsMuted = '1'; } m.muted = true; }
          else if (m.dataset.bsMuted === '1') { m.muted = m.dataset.bsWas === '1'; delete m.dataset.bsMuted; delete m.dataset.bsWas; }
        });
        apply();
        if (!window.__bsMuteHook) { window.__bsMuteHook = true; document.addEventListener('play', apply, true); document.addEventListener('loadeddata', apply, true); }
        """
        _ = try? await webView.callAsyncJavaScript(js, arguments: ["on": on], contentWorld: .defaultClient)
    }

    func scrollFraction() async -> Double? {
        let r = try? await webView.callAsyncJavaScript("const h = document.documentElement.scrollHeight - window.innerHeight; return h > 600 ? window.scrollY / h : null;", contentWorld: .defaultClient)
        return (r as? NSNumber)?.doubleValue
    }

    func scrollTo(fraction: Double) async {
        _ = try? await webView.callAsyncJavaScript("const h = document.documentElement.scrollHeight - window.innerHeight; if (h > 600 && window.scrollY < 40) window.scrollTo({ top: h * f, behavior: 'smooth' });", arguments: ["f": fraction], contentWorld: .defaultClient)
    }

    private static let draftFieldScript = """
    const bad = ["pass","pin","otp","code","card","cvv","cvc","ssn","secret","token","iban","account","security","social"];
    const out = [];
    document.querySelectorAll('textarea, input[type=text], input:not([type])').forEach((el, i) => {
      const type = (el.getAttribute('type') || (el.tagName === 'TEXTAREA' ? 'textarea' : 'text')).toLowerCase();
      const ac = (el.getAttribute('autocomplete') || '').toLowerCase();
      const name = ((el.name || '') + ' ' + (el.id || '') + ' ' + ac).toLowerCase();
      if (el.disabled || el.readOnly || bad.some(w => name.includes(w)) || ac.includes('cc-') || ac.includes('one-time')) return;
      const min = el.tagName === 'TEXTAREA' ? 12 : 30;
      if ((el.value || '').length < min) return;
      out.push({ key: i + ':' + (el.name || el.id || ''), value: el.value.slice(0, 20000) });
    });
    return out.slice(0, 10);
    """

    func formDraftFields() async -> [[String: Any]]? {
        try? await webView.callAsyncJavaScript(Self.draftFieldScript, contentWorld: .defaultClient) as? [[String: Any]]
    }

    func restoreFormDraft(_ fields: [[String: Any]]) async -> Int {
        let r = try? await webView.callAsyncJavaScript("""
        let n = 0; const els = document.querySelectorAll('textarea, input[type=text], input:not([type])');
        for (const f of fields) {
          const i = parseInt(f.key.split(':')[0], 10); const el = els[i];
          if (el && !el.disabled && !el.readOnly && (el.value || '') === '' && (el.name || el.id || '') === f.key.split(':').slice(1).join(':')) {
            el.value = f.value; el.dispatchEvent(new Event('input', { bubbles: true })); n++;
          }
        }
        return n;
        """, arguments: ["fields": fields], contentWorld: .defaultClient)
        return (r as? NSNumber)?.intValue ?? 0
    }

    func extractPageData() async -> [String: Any]? {
        let script = """
        const abs = u => { try { return new URL(u, document.baseURI).href; } catch (e) { return ''; } };
        const seen = new Set(); const images = [];
        for (const i of document.images) {
          const url = abs(i.currentSrc || i.src);
          if (!url || url.startsWith('data:') || seen.has(url) || (i.naturalWidth < 80 && i.naturalHeight < 80)) continue;
          seen.add(url); images.push({ url, alt: i.alt || '', w: i.naturalWidth, h: i.naturalHeight });
          if (images.length >= 200) break;
        }
        const tables = Array.from(document.querySelectorAll('table')).slice(0, 30).map(t => ({
          caption: t.caption ? t.caption.innerText.trim() : '',
          rows: Array.from(t.rows).slice(0, 2000).map(r => Array.from(r.cells).map(c => c.innerText.replace(/\\s+/g, ' ').trim()))
        })).filter(t => t.rows.length > 1);
        const exts = /\\.(pdf|docx?|xlsx?|pptx?|csv|txt|rtf|epub|zip)(\\?|#|$)/i; const docs = []; const dseen = new Set();
        for (const a of document.querySelectorAll('a[href]')) {
          const url = abs(a.href); const m = url.match(exts);
          if (m && !dseen.has(url)) { dseen.add(url); docs.push({ url, title: (a.innerText || a.title || url).trim().slice(0, 120), kind: m[1].toLowerCase() }); }
          if (docs.length >= 100) break;
        }
        const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4')).slice(0, 300).map(h => ({ level: Number(h.tagName[1]), text: h.innerText.replace(/\\s+/g, ' ').trim().slice(0, 160) })).filter(h => h.text);
        return { images, tables, documents: docs, headings };
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any]
    }

    func scrollToHeading(_ index: Int) async {
        _ = try? await webView.callAsyncJavaScript("""
        const all = Array.from(document.querySelectorAll('h1,h2,h3,h4')).filter(h => h.innerText.trim()).slice(0, 300);
        if (all[idx]) all[idx].scrollIntoView({ behavior: 'smooth', block: 'start' });
        """, arguments: ["idx": index], contentWorld: .defaultClient)
    }

    func controlVideo(index: Int, action: String, value: Double) async {
        _ = try? await webView.callAsyncJavaScript("""
        const m = document.querySelectorAll('video, audio')[index]; if (!m) return;
        if (action === 'play') m.play(); else if (action === 'pause') m.pause();
        else if (action === 'speed') m.playbackRate = value;
        else if (action === 'seek') m.currentTime = value;
        else if (action === 'mute') m.muted = value > 0;
        else if (action === 'volume') m.volume = Math.max(0, Math.min(1, value));
        else if (action === 'airplay') { if (m.webkitShowPlaybackTargetPicker) m.webkitShowPlaybackTargetPicker(); }
        else if (action === 'subtitle') {
          const list = Array.from(m.textTracks || []).filter(t => t.kind === 'subtitles' || t.kind === 'captions');
          list.forEach((t, i) => { t.mode = (i === Math.round(value)) ? 'showing' : 'disabled'; });
        }
        else if (action === 'pictureInPicture') {
          if (m.webkitSetPresentationMode) m.webkitSetPresentationMode(m.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
          else if (document.pictureInPictureEnabled) { document.pictureInPictureElement ? document.exitPictureInPicture() : m.requestPictureInPicture(); }
        } else if (action === 'fullscreen') { if (m.webkitEnterFullscreen) m.webkitEnterFullscreen(); else m.requestFullscreen(); }
        """, arguments: ["index": index, "action": action, "value": value], contentWorld: .defaultClient)
    }

    func fillCouponField(_ code: String) async -> Bool {
        let r = try? await webView.callAsyncJavaScript("""
        const words = /coupon|promo|discount|voucher|gift.?card|offer.?code/i;
        const field = Array.from(document.querySelectorAll('input[type=text], input:not([type])')).find(el => !el.disabled && words.test([el.name, el.id, el.placeholder, el.getAttribute('aria-label')].join(' ')));
        if (!field) return false;
        field.focus(); field.value = code; field.dispatchEvent(new Event('input', { bubbles: true })); field.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
        """, arguments: ["code": code], contentWorld: .defaultClient)
        return (r as? NSNumber)?.boolValue ?? false
    }

    func mediaElements() async -> [[String: Any]]? {
        let script = """
        return Array.from(document.querySelectorAll('video, audio')).slice(0, 8).map(m => ({
          tag: m.tagName.toLowerCase(), src: m.currentSrc || m.src || '', blob: (m.currentSrc || m.src || '').startsWith('blob:'),
          currentTime: m.currentTime, duration: isFinite(m.duration) ? m.duration : 0, paused: m.paused, rate: m.playbackRate, readyState: m.readyState, networkState: m.networkState, hasMediaKeys: !!m.mediaKeys,
          errorCode: m.error ? m.error.code : null, errorMessage: m.error ? (m.error.message || '') : null,
          volume: m.volume, muted: m.muted,
          width: m.videoWidth || 0, height: m.videoHeight || 0,
          dropped: (m.getVideoPlaybackQuality ? m.getVideoPlaybackQuality().droppedVideoFrames : 0), frames: (m.getVideoPlaybackQuality ? m.getVideoPlaybackQuality().totalVideoFrames : 0),
          sessionTitle: (navigator.mediaSession && navigator.mediaSession.metadata) ? (navigator.mediaSession.metadata.title || '') : '',
          sessionArtist: (navigator.mediaSession && navigator.mediaSession.metadata) ? (navigator.mediaSession.metadata.artist || '') : '',
          pageTitle: document.title || '',
          tracks: Array.from(m.textTracks || []).filter(t => t.kind === 'subtitles' || t.kind === 'captions').map(t => ({ label: t.label || t.language || 'Track', language: t.language || '', mode: t.mode })),
          canAirPlay: !!m.webkitShowPlaybackTargetPicker
        }));
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [[String: Any]]
    }

    func selectedText() async -> String? {
        let result = try? await webView.callAsyncJavaScript("return String(window.getSelection ? window.getSelection() : '');", contentWorld: .defaultClient) as? String
        let text = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : String(text.prefix(2000))
    }

    func setUserAgent(_ value: String?) { webView.customUserAgent = value }

    func connectionCertificate() async -> Data? {
        guard webView.url?.scheme == "https", let trust = webView.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return SecCertificateCopyData(leaf) as Data
    }

    func securityReport() async -> SecurityReport? {
        guard let url = webView.url else { return nil }
        var certificates: [SecurityReport.Certificate] = []
        if let trust = webView.serverTrust, let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            for (index, certificate) in chain.prefix(4).enumerated() {
                let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "Unknown"
                let issuer = index + 1 < chain.count ? (SecCertificateCopySubjectSummary(chain[index + 1]) as String? ?? "Unknown") : subject
                var expires: Date?
                #if os(macOS)
                if let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
                   let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any], let seconds = entry[kSecPropertyKeyValue] as? Double {
                    expires = Date(timeIntervalSinceReferenceDate: seconds)
                }
                #endif
                certificates.append(SecurityReport.Certificate(subject: subject, issuer: issuer, expires: expires))
            }
        }
        let script = """
        const secure = location.protocol === 'https:';
        const mixed = secure ? performance.getEntriesByType('resource').filter(e => e.name.startsWith('http://')).map(e => e.name).slice(0, 40) : [];
        const forms = secure ? Array.from(document.forms).map(f => f.action || '').filter(a => a.startsWith('http://')).slice(0, 10) : [];
        const nav = performance.getEntriesByType('navigation')[0];
        return { mixed: mixed, forms: forms, redirects: nav ? nav.redirectCount : 0, transport: nav ? nav.nextHopProtocol : '' };
        """
        let found = (try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any]) ?? [:]
        return SecurityReport(url: url.absoluteString, isHTTPS: url.scheme == "https", certificates: certificates,
                              mixedContent: found["mixed"] as? [String] ?? [], insecureForms: found["forms"] as? [String] ?? [],
                              redirects: found["redirects"] as? Int ?? 0, transport: found["transport"] as? String ?? "")
    }

    func pageMetadata() async -> [String: String]? {
        let script = """
        const meta = (n) => { const e = document.querySelector('meta[name="' + n + '"],meta[property="' + n + '"]'); return e && e.content ? e.content.trim() : ''; };
        let author = meta('author') || meta('article:author') || meta('twitter:creator');
        let published = meta('article:published_time') || meta('datePublished') || meta('date') || meta('pubdate') || meta('og:updated_time');
        for (const s of document.querySelectorAll('script[type="application/ld+json"]')) {
          try {
            const j = JSON.parse(s.textContent);
            const items = Array.isArray(j) ? j : (j['@graph'] || [j]);
            for (const it of items) {
              if (!author && it && it.author) author = typeof it.author === 'string' ? it.author : (Array.isArray(it.author) ? it.author.map(a => a.name || a).join(', ') : (it.author.name || ''));
              if (!published && it && (it.datePublished || it.dateCreated)) published = it.datePublished || it.dateCreated;
            }
          } catch (e) {}
        }
        return { title: meta('og:title') || document.title || '', author: author || '', published: published || '', site: meta('og:site_name') || location.hostname.replace(/^www\\./, '') };
        """
        guard let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any] else { return nil }
        return result.compactMapValues { ($0 as? String).map { String($0.prefix(300)) } }
    }

    func pickElement() async -> [String: Any]? {
        let script = """
        return await new Promise(resolve => {
          const root = document.documentElement, box = document.createElement('div');
          box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.16);border-radius:2px;transition:all .06s;left:0;top:0;width:0;height:0';
          root.appendChild(box);
          let current = null;
          const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } };
          const selectorFor = (el) => {
            if (el.id && unique('#' + CSS.escape(el.id))) return '#' + CSS.escape(el.id);
            const parts = [];
            for (let e = el; e && e.nodeType === 1 && e !== document.body && parts.length < 6; e = e.parentElement) {
              let part = e.tagName.toLowerCase();
              const cls = [...e.classList].filter(c => /^[A-Za-z_-][\\w-]*$/.test(c)).slice(0, 2);
              if (cls.length) part += '.' + cls.map(c => CSS.escape(c)).join('.');
              const same = e.parentElement ? [...e.parentElement.children].filter(c => c.tagName === e.tagName) : [];
              if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
              parts.unshift(part);
              if (unique(parts.join(' > '))) break;
            }
            return parts.join(' > ');
          };
          const describe = (el) => {
            const cs = getComputedStyle(el), r = el.getBoundingClientRect();
            const names = ['display','position','width','height','margin','padding','border','color','background-color','font-family','font-size','font-weight','line-height','text-align','opacity','z-index','overflow'];
            return { selector: selectorFor(el), tag: el.tagName.toLowerCase(), width: Math.round(r.width), height: Math.round(r.height),
                     text: (el.innerText || '').trim().slice(0, 300), html: el.outerHTML.slice(0, 1200), styles: names.map(n => [n, cs.getPropertyValue(n)]) };
          };
          const move = (e) => {
            const el = document.elementFromPoint(e.clientX, e.clientY);
            if (!el || el === box) return;
            current = el;
            const r = el.getBoundingClientRect();
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
          };
          const stop = (result) => {
            document.removeEventListener('mousemove', move, true); document.removeEventListener('pointerdown', down, true);
            document.removeEventListener('click', swallow, true); document.removeEventListener('keydown', key, true);
            box.remove(); clearTimeout(timer); window.__bsCancelPick = null; resolve(result);
          };
          const swallow = (e) => { e.preventDefault(); e.stopPropagation(); };
          const down = (e) => { swallow(e); const el = document.elementFromPoint(e.clientX, e.clientY) || current; stop(el && el !== box ? describe(el) : null); };
          const key = (e) => { if (e.key === 'Escape') { swallow(e); stop(null); } };
          const timer = setTimeout(() => stop(null), 60000);
          window.__bsCancelPick = () => stop(null);
          document.addEventListener('mousemove', move, true); document.addEventListener('pointerdown', down, true);
          document.addEventListener('click', swallow, true); document.addEventListener('keydown', key, true);
        });
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any]
    }

    func cancelPicking() {
        Task { _ = try? await webView.callAsyncJavaScript("if (window.__bsCancelPick) window.__bsCancelPick();", contentWorld: .defaultClient) }
    }

    func loginFormOrigin() async -> String? {
        try? await webView.callAsyncJavaScript(LoginScripts.probe, contentWorld: .defaultClient) as? String
    }

    /// The frame whose password field the person last put the cursor in: a sign-in box can be a page from another site inside this one (Apple's, Google's).
    var loginFrame: WKFrameInfo?

    func fillLogin(origin: String, user: String, password: String) async -> Bool {
        // A sign-in inside a frame is filled in that frame; otherwise in the page itself.
        let frame = loginFrame.flatMap { info in WebLoginOrigin.normalized(info.request.url) == origin ? info : nil }
        let r = try? await webView.callAsyncJavaScript(LoginScripts.fill, arguments: ["origin": origin, "user": user, "password": password], in: frame, contentWorld: .defaultClient)
        return (r as? Bool) ?? false
    }

    /// Reads a filled-in sign-in form just before it is sent, so the browser can offer to keep it. Gives up after a second so a stuck page never holds up a navigation.
    private func captureLoginBeforeNavigation() async -> [String: Any]? {
        await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { @MainActor in try? await self.webView.callAsyncJavaScript(LoginScripts.capture, contentWorld: .defaultClient) as? [String: Any] }
            group.addTask { try? await Task.sleep(for: .seconds(1)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func pageDiagnostics() async -> [String: Any]? {
        let script = """
        const nav = performance.getEntriesByType('navigation')[0];
        const res = performance.getEntriesByType('resource').slice(0, 400).map(r => ({ name: r.name.slice(0, 300), type: r.initiatorType || 'other', start: r.startTime, duration: r.duration, transfer: r.transferSize || 0, decoded: r.decodedBodySize || 0, status: r.responseStatus || 0 }));
        if (nav) res.unshift({ name: location.href.slice(0, 300), type: 'document', start: 0, duration: nav.duration, transfer: nav.transferSize || 0, decoded: nav.decodedBodySize || 0, status: nav.responseStatus || 0 });
        const area = (s) => { const out = []; try { for (let i = 0; i < Math.min(s.length, 200); i++) { const k = s.key(i); out.push({ key: k, value: String(s.getItem(k)).slice(0, 2000), size: (s.getItem(k) || '').length }); } } catch (e) {} return out; };
        const cookies = document.cookie ? document.cookie.split('; ').slice(0, 100).map(c => { const i = c.indexOf('='); return { key: c.slice(0, i), value: c.slice(i + 1, i + 200), size: c.length }; }) : [];
        const paint = performance.getEntriesByName('first-paint')[0];
        return { resources: res, local: area(localStorage), session: area(sessionStorage), cookies: cookies, errors: window.__bsErrors || [],
                 perf: { load: nav ? nav.loadEventEnd : 0, dcl: nav ? nav.domContentLoadedEventEnd : 0, paint: paint ? paint.startTime : null, requests: res.length, transfer: res.reduce((a, r) => a + r.transfer, 0), nodes: document.getElementsByTagName('*').length } };
        """
        return try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String: Any]
    }

    /// Runs what the person typed in the scratchpad, in the extension-style isolated world: it sees the page's elements but not its own variables.
    func runScratch(_ code: String) async -> String {
        let body = "const __r = await (async () => { " + code + "\n})(); return __r === undefined ? 'undefined' : (typeof __r === 'string' ? __r : JSON.stringify(__r, null, 2));"
        do {
            let value = try await webView.callAsyncJavaScript(body, contentWorld: .defaultClient)
            return (value as? String).map { String($0.prefix(20000)) } ?? "undefined"
        } catch { return "Error: " + error.localizedDescription }
    }


    func setInspectable(_ on: Bool) { webView.isInspectable = on }

    func pageText() async -> String? {
        let result = try? await webView.callAsyncJavaScript("return (document.body ? document.body.innerText : '').slice(0, 15000);", contentWorld: .defaultClient) as? String
        let text = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    func pagePDF() async -> Data? {
        guard webView.url != nil else { return nil }
        let config = WKPDFConfiguration()
        if let size = await contentSize() { config.rect = CGRect(origin: .zero, size: size) }
        return try? await webView.pdf(configuration: config)
    }

    func screenshot(fullPage: Bool) async -> Data? {
        guard webView.url != nil else { return nil }
        if fullPage {
            guard let pdf = await pagePDF() else { return nil }
            return PageImage.png(fromPDF: pdf)
        }
        guard let image = try? await webView.takeSnapshot(configuration: WKSnapshotConfiguration()) else { return nil }
        return PageImage.png(from: image)
    }

    func presentNativeFind() {
        #if os(iOS)
        webView.isFindInteractionEnabled = true
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
        #endif
    }

    /// Finds the main article and returns its text blocks. Runs in the browser's own isolated world and only reads the page.
    func readableContent() async -> ReadableArticle? {
        let script = """
        const roots = Array.from(document.querySelectorAll('article, main, [role="main"], #content, .post, .article, .entry-content'));
        let best = null, score = 0;
        for (const el of (roots.length ? roots : [document.body])) {
          const s = Array.from(el.querySelectorAll('p')).reduce((a, p) => a + (p.innerText || '').length, 0);
          if (s > score) { score = s; best = el; }
        }
        if (!best || score < 400) return null;
        const blocks = [];
        best.querySelectorAll('h1,h2,h3,h4,p,li,blockquote,pre,img').forEach(el => {
          const t = el.tagName.toLowerCase();
          if (el.closest('nav,header,footer,aside,form,[aria-hidden="true"],.comments,.related,.share')) return;
          if (t === 'img') {
            const src = el.currentSrc || el.src;
            if (src && el.naturalWidth > 240) blocks.push({ t: 'img', v: src, a: el.alt || '' });
            return;
          }
          const text = (el.innerText || '').trim();
          if (!text || (t === 'p' && text.length < 25)) return;
          blocks.push({ t: t, v: text });
        });
        return { title: document.title, site: location.hostname.replace(/^www\\./, ''), blocks: blocks.slice(0, 800) };
        """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        return ReadableArticle.from(result)
    }
    var currentURL: URL? { webView.url }

    var zoomFactor: Double {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    func isBusy() async -> Bool {
        if webView.isLoading { return true }
        // Spelled out: `.none` alone would be read as Optional.none and make every tab look busy.
        if webView.cameraCaptureState != WKMediaCaptureState.none || webView.microphoneCaptureState != WKMediaCaptureState.none { return true }
        return await webView.requestMediaPlaybackState() == .playing
    }

    func printPage() {
        #if os(macOS)
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // A page in a background tab has no size yet, and the operation needs one to lay the page out.
        if webView.window == nil { operation.view?.frame = NSRect(x: 0, y: 0, width: 612, height: 792) }
        if let window = webView.window ?? NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
        #else
        let controller = UIPrintInteractionController.shared
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true)
        #endif
    }

    func webArchive() async -> Data? {
        guard webView.url != nil else { return nil }
        return await withCheckedContinuation { continuation in
            webView.createWebArchiveData { result in continuation.resume(returning: try? result.get()) }
        }
    }

    func captureState() -> Any? { webView.interactionState }
    func restoreState(_ state: Any) { webView.interactionState = state }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func reload() { webView.reload() }

    func setGestures(_ options: GestureOptions) {
        webView.allowsBackForwardNavigationGestures = options.backForward
        #if os(macOS)
        webView.allowsMagnification = options.pinchZoom
        #else
        webView.scrollView.pinchGestureRecognizer?.isEnabled = options.pinchZoom
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        if options.pullToRefresh {
            if refresher == nil {
                let control = UIRefreshControl()
                control.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
                refresher = control
            }
            webView.scrollView.refreshControl = refresher
        } else {
            webView.scrollView.refreshControl = nil
        }
        #endif
    }

    #if os(iOS)
    private var refresher: UIRefreshControl?
    @objc private func pulledToRefresh() { webView.reload() }
    private func stopRefreshing() { refresher?.endRefreshing() }
    #else
    private func stopRefreshing() {}
    #endif
    func stop() { webView.stopLoading() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func close() {
        observers.removeAll()
        #if os(iOS)
        mediaTimer?.invalidate()
        mediaTimer = nil
        #endif
    }

    func find(_ text: String, backwards: Bool) async -> Bool {
        guard !text.isEmpty else { clearFind(); return false }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        config.caseSensitive = false
        return (try? await webView.find(text, configuration: config).matchFound) ?? false
    }

    func clearFind() {
        Task { _ = try? await webView.find("", configuration: WKFindConfiguration()) }
    }

    func snapshot() async -> Data? {
        guard webView.url != nil else { return nil }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 480
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        // The picture is turned into PNG data away from the main thread: doing it there froze the window for a moment on every tab switch.
        nonisolated(unsafe) let picture = image
        return await Task.detached(priority: .utility) { () -> Data? in
            #if os(macOS)
            guard let tiff = picture.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
            #else
            return picture.pngData()
            #endif
        }.value
    }

    func showErrorPage(title: String, detail: String, baseURL: URL?) {
        webView.loadHTMLString(ErrorPage.html(title: title, detail: detail), baseURL: baseURL)
    }

    private func observe() {
        func track<V>(_ kp: KeyPath<WKWebView, V>, _ apply: @escaping (TabEngineEvents, WKWebView) -> Void) {
            observers.append(webView.observe(kp, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, let events = self.events else { return }
                    apply(events, wv)
                }
            })
        }
        track(\.title) { e, wv in if let t = wv.title { e.engineTitleChanged(t) } }
        track(\.url) { e, wv in if let u = wv.url { e.engineURLChanged(u) } }
        track(\.isLoading) { e, wv in e.engineLoadingChanged(isLoading: wv.isLoading, canGoBack: wv.canGoBack, canGoForward: wv.canGoForward) }
        track(\.canGoBack) { e, wv in e.engineLoadingChanged(isLoading: wv.isLoading, canGoBack: wv.canGoBack, canGoForward: wv.canGoForward) }
        track(\.canGoForward) { e, wv in e.engineLoadingChanged(isLoading: wv.isLoading, canGoBack: wv.canGoBack, canGoForward: wv.canGoForward) }
        track(\.estimatedProgress) { e, wv in e.engineProgress(wv.estimatedProgress) }
        track(\.hasOnlySecureContent) { e, wv in e.engineSecurityChanged(wv.hasOnlySecureContent) }
        track(\.themeColor) { e, wv in e.engineThemeColorChanged(PageTint(wv.themeColor)) }
        #if os(iOS)
        if #available(iOS 26.0, *) {
            // The system fades and blurs page content under the status bar and home indicator. Nothing should be drawn there.
            webView.scrollView.topEdgeEffect.isHidden = true
            webView.scrollView.bottomEdgeEffect.isHidden = true
        }
        observers.append(webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.scrolled(scrollView) }
        })
        #endif
    }

    #if os(iOS)
    /// Turns the page's scroll position into "how far did it move toward the top". Only the user's own movement counts, and
    /// the rubber band beyond either end is ignored. Reaching the very top always counts as scrolling back up.
    private func scrolled(_ scrollView: UIScrollView) {
        let y = scrollView.contentOffset.y
        defer { lastScrollY = y; lastBoundsHeight = scrollView.bounds.height }
        // The page was resized (the bars came or went): the offset moved by itself, not because the user scrolled.
        guard abs(scrollView.bounds.height - lastBoundsHeight) < 1 else { return }
        guard let last = lastScrollY, scrollView.isDragging || scrollView.isDecelerating else { return }
        let top = -scrollView.adjustedContentInset.top
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        if y <= top + 1 { events?.engineScrolled(deltaY: 100); return }
        guard y < bottom else { return }
        events?.engineScrolled(deltaY: Double(last - y))
    }
    #endif

    // MARK: Navigation delegate

    /// The choice for each navigation, and with it whether the page may run scripts: switched off per site or per tab, it holds for this load only.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let policy = await decidePolicy(for: navigationAction, in: webView)
        if navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url, let events {
            preferences.allowsContentJavaScript = events.engineScriptsAllowed(for: url)
        }
        return (policy, preferences)
    }

    private func decidePolicy(for navigationAction: WKNavigationAction, in webView: WKWebView) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url, let events else { return .cancel }
        let main = navigationAction.targetFrame?.isMainFrame ?? true
        // A sign-in form is read here, while the page is still showing it, only when the browser asked and only for a submit or a script-made navigation.
        if main, webView.url != nil, navigationAction.navigationType == .formSubmitted || navigationAction.navigationType == .other,
           events.engineWantsLoginCapture(), let found = LoginRules.capture(await captureLoginBeforeNavigation()) {
            events.engineLoginSubmitted(origin: found.origin, user: found.user, password: found.password)
        }
        #if os(iOS)
        // A link to a site that has an installed app, followed from another site: ask before the system hands it to the app.
        if main, navigationAction.navigationType == .linkActivated, let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
           let app = ExternalApps.app(forHost: target.host), app.scheme.isEmpty == false,
           let appURL = URL(string: app.scheme + "://"), UIApplication.shared.canOpenURL(appURL),
           ExternalApps.app(forHost: webView.url?.host) != app {
            let request = navigationAction.request
            let host = (target.host ?? "").lowercased()
            let rule = ExternalApps.sites[host] ?? (ExternalApps.mode == .ask ? nil : ExternalApps.mode.rawValue)
            Task { @MainActor in
                var choice: Int
                switch rule {
                case "app": choice = 0
                case "browser": choice = 1
                default:
                    choice = await Dialogs.choose(title: "Open in \(app.name)?",
                                                  message: "This link can open in the \(app.name) app instead of the browser.",
                                                  buttons: ["Open in \(app.name)", "Always Open in \(app.name)", "Always Stay for \(host)", "Stay in Browser Setu"])
                    switch choice {
                    case 1: ExternalApps.remember?(host, "app"); choice = 0
                    case 2: ExternalApps.remember?(host, "browser"); choice = 1
                    case 3: choice = 1
                    default: break
                    }
                }
                if choice == 0 { UIApplication.shared.open(target, options: [.universalLinksOnly: true]) { opened in
                    // If the app could not take it after all, the page still opens here.
                    if !opened { webView.load(request) }
                } } else {
                    // Loaded by the browser itself, which the system does not hand to an app.
                    webView.load(request)
                }
            }
            return .cancel
        }
        #endif
        // A page's own "Download" button often hands the browser a data: or blob: address (a key, a profile, an export). As a download that is only a file
        // saved to Downloads, never a page that runs; shown as a page it stays blocked. Only a click on a link marked as a download qualifies.
        if navigationAction.shouldPerformDownload, navigationAction.navigationType == .linkActivated,
           let scheme = target.scheme?.lowercased(), scheme == "data" || scheme == "blob" {
            return .download
        }
        let decision = events.engineDecideNavigation(url: target, mainFrame: main)
        #if os(iOS)
        // Staying means staying. The system hands a tapped web address that belongs to an installed app (YouTube, Maps, ...) to that app. Loading the
        // same request from here is not a tap, so it is never handed over: the tap is cancelled and the page is loaded by the browser itself (public API
        // only). Unless the user chose the app for this site. Redirects the page makes on its own are not covered by this.
        if decision == .allow, navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .linkActivated,
           let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https", !navigationAction.shouldPerformDownload,
           ExternalApps.sites[(target.host ?? "").lowercased()] != "app", ExternalApps.mode != .app {
            let request = navigationAction.request
            Task { @MainActor in webView.load(request) }
            return .cancel
        }
        #endif
        switch decision {
        case .allow: return navigationAction.shouldPerformDownload ? .download : .allow
        case .external, .deny: return .cancel
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            // A web page asked for as a page (the address has no file name, like youtube.com) is shown, whatever the header says: saving the
            // home page of a site as "www.example.com.html" is never what someone typing the address wanted.
            let mime = (http.mimeType ?? "").lowercased()
            let isPage = mime == "text/html" || mime == "application/xhtml+xml"
            let lastPart = http.url?.lastPathComponent ?? ""
            let looksLikeFile = lastPart.contains(".") && lastPart != "/"
            if navigationResponse.isForMainFrame, isPage, !looksLikeFile { return .allow }
            return .download
        }
        return navigationResponse.canShowMIMEType ? .allow : .download
    }

    /// Sites that ask for a name and password with a browser sign-in box. Certificate problems are never overridden:
    /// those go back to the system, which refuses the connection.
    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard ChallengeAction.action(forAuthenticationMethod: space.authenticationMethod) == .askUser else {
            return (.performDefaultHandling, nil)
        }
        // A saved sign-in is tried once. If the site refuses it, it is forgotten (the password has probably changed) and the user is asked.
        // What the sign-in box belongs to, in full: a saved sign-in is only offered back to exactly this (scheme, host, port, realm, method), over HTTPS.
        let signInSpace = SignInSpace(scheme: space.protocol ?? "", host: space.host, port: space.port, realm: space.realm ?? "",
                                      method: space.authenticationMethod, isProxy: space.proxyType != nil)
        if challenge.previousFailureCount == 0, let saved = events?.engineSavedSignIn(space: signInSpace) {
            return (.useCredential, URLCredential(user: saved.user, password: saved.password, persistence: .forSession))
        }
        if challenge.previousFailureCount > 0 { events?.engineForgetSignIn(space: signInSpace) }
        // A wrong password comes back as a second challenge; asking again forever would trap the page.
        guard challenge.previousFailureCount < 3 else { return (.cancelAuthenticationChallenge, nil) }
        let canRemember = !(events?.enginePrivate ?? true) && signInSpace.allowsAutomatic
        guard let entered = await Dialogs.credentials(host: space.host, realm: space.realm, isProxy: space.proxyType != nil, canRemember: canRemember) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if entered.remember { events?.engineRememberSignIn(space: signInSpace, user: entered.user, password: entered.password) }
        return (.useCredential, URLCredential(user: entered.user, password: entered.password, persistence: .forSession))
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = downloads
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if let sites = redirectWatch.hop(to: webView.url?.host) { events?.engineSuspiciousRedirect(sites: sites) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        redirectWatch.reset()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        #if os(macOS)
        refreshEditableFocus()
        #endif
        stopRefreshing()
        events?.engineDidFinishLoading()
        readIconLinks(in: webView)
        #if os(iOS)
        paintBehindPage(webView)
        fixedBarsSeen = (false, false)
        probeFixedBars(webView)
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(for: .milliseconds(700))      // a page that sets its dark background late is read again
            if let webView { self?.paintBehindPage(webView); self?.probeFixedBars(webView) }
            try? await Task.sleep(for: .milliseconds(2000))     // single-page sites build their bars after the page has loaded
            if let webView { self?.probeFixedBars(webView) }
        }
        #endif
        #if os(macOS)
        sampleTint(webView)
        Task { @MainActor [weak self, weak webView] in
            try? await Task.sleep(for: .milliseconds(800))      // a page that sets its colour late is read again
            if let webView { self?.sampleTint(webView) }
        }
        #endif
    }

    #if os(macOS)
    /// A page that names no theme colour still has a background, and that is what the toolbar can take on. Read once the page has loaded, from the page and read-only.
    private func sampleTint(_ webView: WKWebView) {
        guard webView.themeColor == nil else { return }
        Task { @MainActor [weak self, weak webView] in
            guard let webView else { return }
            let rgb = (try? await webView.callAsyncJavaScript(Self.backgroundProbe, contentWorld: .defaultClient)) as? [Int]
            if let rgb, rgb.count == 3, webView.themeColor == nil {
                self?.events?.engineThemeColorChanged(PageTint(red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255))
            }
        }
    }
    #endif

    /// The solid colour at the top of the page, found the way the eye would: the element at the top edge and the ones around it, outward, then the middle of the page.
    static let backgroundProbe = """
    const solid = (e) => {
      const m = getComputedStyle(e).backgroundColor.match(/[\\d.]+/g) || [];
      const a = m.length >= 4 ? parseFloat(m[3]) : (m.length >= 3 ? 1 : 0);
      return a > 0.5 ? [+m[0], +m[1], +m[2]] : null;
    };
    for (const [x, y] of [[innerWidth / 2, 2], [4, 2], [innerWidth / 2, innerHeight / 2]]) {
      let el = document.elementFromPoint(x, y), color = null;
      while (el && !color) { color = solid(el); el = el.parentElement; }
      if (color) return color;
    }
    return solid(document.documentElement) || [255, 255, 255];
    """

    #if os(iOS)
    /// The strip under the status bar (and above the page on a phone) is not part of the page, so it showed white on a dark page and the clock
    /// vanished. It is painted with the page's own background colour, read from the page (read-only), as the page's theme colour if it gave none.
    private var fixedBarsSeen = (top: false, bottom: false)

    /// Looks, read-only, for a bar fixed to the top or bottom edge. Within one page load a bar that was seen stays seen, so the layout does not flip back and forth.
    private func probeFixedBars(_ webView: WKWebView) {
        let script = """
        const W = innerWidth, H = innerHeight, out = { top: false, bottom: false };
        const near = (el, edge) => {
          for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
            const p = getComputedStyle(e).position;
            if (p === 'fixed' || p === 'sticky') {
              const r = e.getBoundingClientRect();
              if (r.width >= W * 0.6 && r.height >= 30 && r.height <= 200 && r.height < H * 0.3) {
                if (edge === 'top' && r.top <= 3) return true;
                if (edge === 'bottom' && r.bottom >= H - 3) return true;
              }
            }
          }
          return false;
        };
        for (const x of [W * 0.25, W * 0.5, W * 0.75]) {
          for (const el of document.elementsFromPoint(x, 4)) if (near(el, 'top')) out.top = true;
          for (const el of document.elementsFromPoint(x, H - 4)) if (near(el, 'bottom')) out.bottom = true;
        }
        return out;
        """
        Task { @MainActor [weak self, weak webView] in
            guard let self, let webView, let r = (try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? [String: Any] else { return }
            fixedBarsSeen = (fixedBarsSeen.top || (r["top"] as? Bool ?? false), fixedBarsSeen.bottom || (r["bottom"] as? Bool ?? false))
            events?.engineFixedBars(top: fixedBarsSeen.top, bottom: fixedBarsSeen.bottom)
        }
    }

    private func paintBehindPage(_ webView: WKWebView) {
        let script = """
        const solid = (e) => {
          const m = getComputedStyle(e).backgroundColor.match(/[\\d.]+/g) || [];
          const a = m.length >= 4 ? parseFloat(m[3]) : (m.length >= 3 ? 1 : 0);
          return a > 0.5 ? [+m[0], +m[1], +m[2]] : null;
        };
        // The element at the top edge, and the ones around it, outward until one has a solid background; then the middle of the page.
        for (const [x, y] of [[innerWidth / 2, 2], [4, 2], [innerWidth / 2, innerHeight / 2]]) {
          let el = document.elementFromPoint(x, y), color = null;
          while (el && !color) { color = solid(el); el = el.parentElement; }
          if (color) return color;
        }
        return solid(document.documentElement) || null;
        """
        Task { @MainActor [weak self, weak webView] in
            guard let webView else { return }
            let rgb = (try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? [Int]
            let color: UIColor? = rgb.flatMap { $0.count == 3 ? UIColor(red: CGFloat($0[0]) / 255, green: CGFloat($0[1]) / 255, blue: CGFloat($0[2]) / 255, alpha: 1) : nil }
            // Unknown: let WebKit choose the strip colour itself, from the page, rather than guessing white or black.
            webView.underPageBackgroundColor = color
            webView.scrollView.backgroundColor = color
            if webView.themeColor == nil, let rgb, rgb.count == 3 {
                self?.events?.engineThemeColorChanged(PageTint(red: Double(rgb[0]) / 255, green: Double(rgb[1]) / 255, blue: Double(rgb[2]) / 255))
            }
        }
    }
    #endif

    /// Reads the page's icon links. The script runs in the browser's own isolated world, so the page cannot see or change it, and it
    /// only reads: nothing is written to the page.
    private func readIconLinks(in webView: WKWebView) {
        let script = """
        return Array.from(document.querySelectorAll('link[rel]'))
          .filter(l => /(^|\\s)(icon|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/i.test(l.rel) && l.href)
          .map(l => ({ href: l.href, rel: l.rel.toLowerCase(), sizes: l.sizes ? l.sizes.value : '' }));
        """
        Task { @MainActor [weak self, weak webView] in
            guard let webView, let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [[String: Any]] else {
                self?.events?.engineIconsFound([]); return
            }
            // A large touch icon is a clean square; otherwise the largest declared size; otherwise the order given.
            func area(_ sizes: String) -> Int {
                let parts = sizes.split(separator: " ").first?.lowercased().split(separator: "x").compactMap { Int($0) } ?? []
                return parts.count == 2 ? parts[0] * parts[1] : 0
            }
            let ranked = result.sorted {
                let a = ($0["rel"] as? String ?? "").contains("apple-touch") ? 1 : 0, b = ($1["rel"] as? String ?? "").contains("apple-touch") ? 1 : 0
                if a != b { return a > b }
                return area($0["sizes"] as? String ?? "") > area($1["sizes"] as? String ?? "")
            }
            self?.events?.engineIconsFound(ranked.compactMap { ($0["href"] as? String).flatMap(URL.init(string:)) })
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        stopRefreshing()
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        stopRefreshing()
        report(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        events?.engineProcessCrashed()
    }

    private func report(_ error: Error) {
        let ns = error as NSError
        guard ns.code != NSURLErrorCancelled, ns.domain != "WebKitErrorDomain" || ns.code != 102 else { return }
        events?.engineLoadFailed(url: ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL, description: ns.localizedDescription)
    }

    // MARK: UI delegate

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let target = navigationAction.request.url
        let clicked = navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .formSubmitted
        // A link that opens elsewhere (target=_blank) is a click by definition: it opens as an ordinary tab.
        if clicked, let target { events?.engineOpenInNewTab(url: target, userInitiated: true); return nil }
        // A script's window.open: allowed right after a real click or key press (or on a site the person allowed), and then given a page joined to its opener.
        let gesture = Date().timeIntervalSince(lastGesture) < 5
        guard gesture || events?.enginePopupsAllowedWithoutGesture() == true else {
            events?.engineBlockedPopup(url: target)
            return nil
        }
        return (events?.engineOpenPopup(configuration: configuration) as? WebKitTab)?.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        events?.engineRequestClose()
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async {
        _ = await Dialogs.choose(title: frame.request.url?.host ?? "Alert", message: message, buttons: ["OK"])
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await Dialogs.choose(title: frame.request.url?.host ?? "Confirm", message: message,
                             buttons: ["OK", "Cancel"]) == 0
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        await Dialogs.promptText(title: frame.request.url?.host ?? "Prompt", message: prompt,
                                 placeholder: defaultText ?? "")
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        let originString = "\(origin.protocol)://\(origin.host)" + (origin.port != 0 ? ":\(origin.port)" : "")
        let kinds: [PermissionType]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        default: kinds = [.camera, .microphone]
        }
        guard let events else { return .deny }
        return await events.engineRequestPermission(origin: originString, kinds: kinds) ? .grant : .deny
    }

    #if os(macOS)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
    #endif
}

// MARK: - Downloads

/// Forwards WKDownload events to the engine-neutral coordinator.
@MainActor
final class WebKitDownloads: NSObject, WKDownloadDelegate {
    private let coordinator: DownloadCoordinator
    private var ids: [ObjectIdentifier: UUID] = [:]
    private var observers: [ObjectIdentifier: NSKeyValueObservation] = [:]

    init(coordinator: DownloadCoordinator) {
        self.coordinator = coordinator
    }

    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                              suggestedFilename: String) async -> URL? {
        // Waits for a free place (or is put off until later, or cancelled while waiting); WebKit fetches nothing until a destination is chosen.
        let source = download.originalRequest?.url
        guard await coordinator.admit(filename: suggestedFilename, source: source) else { download.cancel { _ in }; return nil }
        // A big file from a server that can send it in pieces is fetched in six at once, which is several times faster where a site slows each connection.
        if await takeOverInPieces(download, response: response, source: source, suggestedFilename: suggestedFilename) { return nil }
        return await MainActor.run {
            let started = coordinator.begin(suggestedName: suggestedFilename, sourceHost: download.originalRequest?.url?.host, cancel: { download.cancel { _ in } }, suspend: { done in download.cancel { data in done(data) } })
            let key = ObjectIdentifier(download)
            ids[key] = started.id
            observers[key] = download.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                let f = p.fractionCompleted
                let done = p.completedUnitCount, total = p.totalUnitCount
                Task { @MainActor in self?.coordinator.update(started.id, fraction: f, completed: done, total: total) }
            }
            return started.destination
        }
    }

    /// Checks, without cookies, that the server really sends this file in pieces, then fetches it that way. False means WebKit carries on as usual.
    nonisolated private func takeOverInPieces(_ download: WKDownload, response: URLResponse, source: URL?, suggestedFilename: String) async -> Bool {
        guard await MainActor.run(body: { coordinator.segmentedEnabled }), let http = response as? HTTPURLResponse, let source,
              PiecePlan.eligible(response: http, request: download.originalRequest) else { return false }
        let total = http.expectedContentLength
        let agent = await MainActor.run { download.webView?.customUserAgent }
        let probe = PieceDownloader(url: source, userAgent: agent)
        guard await probe.probe(expectedTotal: total) else { return false }
        final class Current: @unchecked Sendable { var downloader: PieceDownloader?; var cancelled = false }
        let current = Current()
        await MainActor.run {
            let started = coordinator.begin(suggestedName: suggestedFilename, sourceHost: source.host, cancel: { current.cancelled = true; current.downloader?.cancel() })
            coordinator.note("Fetching \(started.destination.lastPathComponent) in pieces")
            Task { @MainActor [coordinator] in
                do {
                    // Six connections; a server that refuses that many gets three, and then one, so a limit never loses the download.
                    var lastError: Error = PieceDownloadError.refused
                    var finishedOK = false
                    for pieces in [PiecePlan.connections, 3, 1] where !finishedOK && !current.cancelled {
                        let downloader = PieceDownloader(url: source, userAgent: agent, pieces: pieces)
                        current.downloader = downloader
                        do {
                            try await downloader.run(total: total, to: started.destination) { done in
                                Task { @MainActor in coordinator.update(started.id, fraction: min(1, Double(done) / Double(total)), completed: done, total: total) }
                            }
                            finishedOK = true
                        } catch PieceDownloadError.refused { lastError = PieceDownloadError.refused; coordinator.note("Server refused \(pieces) connections") }
                    }
                    if !finishedOK { throw current.cancelled ? CancellationError() : lastError }
                    coordinator.finish(started.id, source: source)
                    coordinator.downloadSucceeded(source: source)
                } catch {
                    coordinator.discard(started.id)
                    if !(error is CancellationError) {
                        coordinator.note("Pieces failed (\(error)); trying the normal download")
                        coordinator.planRetry(for: source, error: error, resumeData: nil, id: started.id)
                    }
                }
            }
        }
        return true
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in
            let key = ObjectIdentifier(download)
            if let id = ids[key] { coordinator.finish(id, source: download.originalRequest?.url); coordinator.downloadSucceeded(source: download.originalRequest?.url) }
            forget(key)
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in
            let key = ObjectIdentifier(download)
            if let id = ids[key] {
                // With resume data (and a server that allows it) the download can carry on; otherwise it is dropped as before.
                let source = download.originalRequest?.url
                if let resumeData, !resumeData.isEmpty { coordinator.interrupt(id, resumeData: resumeData, source: source) }
                else { coordinator.discard(id) }
                // A failure that a retry can fix (the connection dropped, say) is tried again a little later, a few times.
                coordinator.planRetry(for: source, error: error, resumeData: resumeData, id: id)
            }
            forget(key)
        }
    }

    func start(_ url: URL, in webView: WKWebView) {
        webView.startDownload(using: URLRequest(url: url)) { [weak self] download in download.delegate = self }
    }

    /// Carries on a stopped download from its resume data, using any open page's web view.
    func resume(_ data: Data, in webView: WKWebView) {
        webView.resumeDownload(fromResumeData: data) { [weak self] download in download.delegate = self }
    }

    private func forget(_ key: ObjectIdentifier) {
        ids[key] = nil
        observers[key] = nil
    }
}

// MARK: - Page theme colour

extension PageTint {
    #if os(macOS)
    init?(_ color: NSColor?) {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }
    #else
    init?(_ color: UIColor?) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard let color, color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.init(red: Double(r), green: Double(g), blue: Double(b))
    }
    #endif
}

#if os(macOS)
/// A web view that tells the shell how far the user scrolled. It only reads the scroll event the view already
/// receives; nothing is injected into the page.
final class ScrollReportingWebView: WKWebView {
    var onScroll: ((CGFloat) -> Void)?
    /// Asked first about each typed character; true means the browser used it and the page does not see it.
    var onKey: ((NSEvent) -> Bool)?
    /// A click or a key the page got: focus may have moved.
    var onInteraction: (() -> Void)?

    /// What shows behind a page before it has painted: the window's own colour in the current appearance, so a dark window never flashes white while a page loads.
    func applyRestingColor() {
        var resolved = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor }
        underPageBackgroundColor = resolved
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyRestingColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRestingColor()
    }

    // The page's right-click menu on a link: WebKit's own choices, with the ones a tabbed browser is expected to have added after "Open Link".
    var hoveredLink: () -> URL? = { nil }
    var onLinkAction: ((LinkAction, URL) -> Void)?
    private var menuPoint: CGPoint = .zero

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        func raw(_ item: NSMenuItem) -> String { item.identifier?.rawValue ?? "" }
        let at = menu.items.firstIndex { raw($0).contains("OpenLink") && !raw($0).contains("Window") && !raw($0).contains("InNew") }
            ?? menu.items.firstIndex { $0.title == "Open Link" }
        guard let at else { return }
        menuPoint = gesturePoint(event)
        let choices: [(String, String, LinkAction)] = [
            ("Open Link in New Tab", "plus.square.on.square", .newTab),
            ("Open Link in Background Tab", "square.stack", .backgroundTab),
            ("Open Link in Split View", "rectangle.split.2x1", .split),
            ("Open Link in the Other Panel", "arrow.right.square", .otherPane),
            ("Open Link in Private Tab", "eye.slash", .privateTab),
        ]
        for (offset, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.0, action: #selector(runLinkChoice(_:)), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: choice.1, accessibilityDescription: nil)
            item.representedObject = choice.2
            menu.insertItem(item, at: at + 1 + offset)
        }
    }

    /// The link under the point that was right-clicked, asked of the page when a choice is made.
    private func linkURL(at point: CGPoint) async -> URL? {
        let script = "const e = document.elementFromPoint(x, y); const a = e && e.closest ? e.closest('a[href]') : null; return a ? a.href : null;"
        let found = try? await callAsyncJavaScript(script, arguments: ["x": point.x, "y": point.y], contentWorld: .defaultClient) as? String
        let url = found.flatMap { URL(string: $0) } ?? hoveredLink()
        guard let url, url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    @objc private func runLinkChoice(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? LinkAction else { return }
        let point = menuPoint
        Task { @MainActor in
            if let url = await linkURL(at: point) { onLinkAction?(action, url) }
        }
    }

    // Mouse gestures: the middle button, held and dragged. A press that does not move is given to the page unchanged, so a middle click on a link still opens it in a new tab.
    var gesturesEnabled: () -> Bool = { false }
    var onGesture: ((String, Bool) -> Void)?
    private var heldPress: NSEvent?
    private var trail: [CGPoint] = []

    private func gesturePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: isFlipped ? p.y : bounds.height - p.y)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, gesturesEnabled() else { super.otherMouseDown(with: event); return }
        heldPress = event; trail = [gesturePoint(event)]
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard heldPress != nil else { super.otherMouseDragged(with: event); return }
        trail.append(gesturePoint(event))
        onGesture?(MouseGesture.strokes(of: trail), false)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let down = heldPress else { super.otherMouseUp(with: event); return }
        heldPress = nil
        let sequence = MouseGesture.strokes(of: trail); trail = []
        if sequence.isEmpty {
            super.otherMouseDown(with: down); super.otherMouseUp(with: event)
            onGesture?("", true)
        } else { onGesture?(sequence, true) }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
        onInteraction?()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        onInteraction?()
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // Momentum after the fingers lift would keep folding the toolbar; only deliberate movement counts.
        if event.momentumPhase == [] { onScroll?(event.scrollingDeltaY) }
    }
}
#endif

/// Receives what the sign-in watcher script reports. Nothing is trusted: the browser re-checks every value before it asks about keeping it.
final class LoginMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let tab = MainActor.assumeIsolated { message.webView.flatMap { TabRegistry.tabs.object(forKey: $0) } }
        let frame = message.frameInfo
        Task { @MainActor in
            guard let tab, let events = tab.eventsForLogin, events.engineWantsLoginCapture() else { return }
            switch kind {
            case "focus":
                tab.loginFrame = frame
                events.engineLoginFieldFocused(origin: (body["origin"] as? String).flatMap(WebLoginOrigin.normalized), usernameOnly: (body["mode"] as? String) == "user")
            case "typed":
                if let found = LoginRules.capture(body) { events.engineLoginTyped(origin: found.origin, user: found.user, password: found.password) }
            case "submit":
                if let found = LoginRules.capture(body) { events.engineLoginSubmitted(origin: found.origin, user: found.user, password: found.password) }
            default: break
            }
        }
    }
}

/// Page-side half of the link menu: reports the address of the link the pointer is over, only when it changes.
enum LinkHover {
    static let script = """
    (function () {
      if (window.__bsLinkHover) return; window.__bsLinkHover = true;
      let last = '';
      document.addEventListener('mouseover', (e) => {
        const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
        const href = a ? a.href : '';
        if (href === last) return; last = href;
        try { window.webkit.messageHandlers.bsLink.postMessage(href); } catch (x) {}
      }, true);
    })();
    """
}

final class LinkHoverHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // Only the main frame is believed, and only web addresses are kept.
        guard message.frameInfo.isMainFrame, let text = message.body as? String else { return }
        let tab = MainActor.assumeIsolated { message.webView.flatMap { TabRegistry.tabs.object(forKey: $0) } }
        tab?.hoveredLink = URL(string: text).flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil }
    }
}

/// Which tab each web view belongs to, and which content controllers already have the browser's handlers.
@MainActor
enum TabRegistry {
    static let tabs = NSMapTable<WKWebView, WebKitTab>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    static let wired = NSHashTable<WKUserContentController>.weakObjects()
}

/// Page-side half of the pop-up rule: tells the browser when the person really clicked, touched or typed (never a script pretending to).
enum GestureScript {
    static let script = """
    (function () {
      if (window.__bsGesture) return; window.__bsGesture = true;
      const ping = (e) => { if (e.isTrusted) { try { window.webkit.messageHandlers.bsGesture.postMessage(1); } catch (x) {} } };
      ['pointerdown', 'keydown', 'touchstart'].forEach((t) => document.addEventListener(t, ping, true));
    })();
    """
}

final class GestureHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { message.webView.flatMap { TabRegistry.tabs.object(forKey: $0) }?.lastGesture = Date() }
    }
}

#if os(iOS)
extension WebKitTab: UIGestureRecognizerDelegate {
    /// The tap recorder watches; it never takes a touch away from the page.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif


#if os(iOS)
/// When the person last touched the screen anywhere in the app, including the system's full-screen video player, which is a window of its own.
@MainActor
final class UserTouchClock: NSObject, UIGestureRecognizerDelegate {
    static let shared = UserTouchClock()
    private(set) var last = Date.distantPast
    private var observed = Set<ObjectIdentifier>()
    private var installed = false

    func install() {
        guard !installed else { attachAll(); return }
        installed = true
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.attachAll() } }
        attachAll()
    }

    private func attachAll() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where observed.insert(ObjectIdentifier(window)).inserted {
                let tap = UITapGestureRecognizer(target: self, action: #selector(touched))
                tap.cancelsTouchesInView = false; tap.delaysTouchesBegan = false; tap.delaysTouchesEnded = false
                tap.delegate = self
                window.addGestureRecognizer(tap)
            }
        }
    }

    @objc private func touched() { last = Date() }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
