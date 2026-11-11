import SetuPrivacyCore
import SwiftUI
#if os(macOS)
import AppKit
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Engine-neutral cookie description (used for isolation checks and diagnostics).
struct CookieInfo: Equatable {
    let name: String
    let value: String
    let domain: String
}

/// A page's own theme colour (the colour it declares in its meta tag), in sRGB, 0...1.
struct PageTint: Equatable {
    var red: Double
    var green: Double
    var blue: Double
}

/// What one website has stored in the profile (shown so the user can remove it).
struct SiteDataInfo: Identifiable, Equatable {
    let host: String
    let kinds: [String]
    var id: String { host }
}

/// Events an engine reports to the shell. The shell never sees engine-specific types,
/// so the same app code runs on every platform engine.
@MainActor
protocol TabEngineEvents: AnyObject {
    func engineTitleChanged(_ title: String)
    func engineURLChanged(_ url: URL)
    func engineLoadingChanged(isLoading: Bool, canGoBack: Bool, canGoForward: Bool)
    func engineProgress(_ progress: Double)
    func engineSecurityChanged(_ secure: Bool)
    /// The page started or stopped using the camera or the microphone (a call, a recording), so the tab can say so.
    func engineCaptureChanged(camera: Bool, microphone: Bool)
    func engineDidFinishLoading()
    func engineLoadFailed(url: URL?, description: String)
    /// The same failure with the system's own evidence (the error's domain and code), which is what the error page is chosen from.
    func engineLoadFailed(url: URL?, domain: String, code: Int, description: String)
    /// The site answered the page load with an error status and sent nothing to show (a bare 404 or 503). A site's own error page is left alone: this is only for an empty one.
    func engineHTTPFailure(url: URL?, status: Int)
    func engineProcessCrashed()
    func engineMouseGesturesEnabled() -> Bool
    /// Whether the page being opened may run scripts (the person can switch them off for a site, or for this one tab).
    func engineScriptsAllowed(for url: URL) -> Bool
    /// The strokes drawn so far while the middle button is held (`finished` false), and the whole gesture when it is let go (`finished` true; empty means it was only a click).
    func engineMouseGesture(_ sequence: String, finished: Bool)
    /// Whether the page has its own bar fixed to the top or bottom edge of the screen (a site header, a row of tabs). Only these pages are kept clear of the status bar and the dock.
    func engineFixedBars(top: Bool, bottom: Bool)
    /// Whether the browser wants to look at a login form just before it is submitted (never in a private tab, or when the setting is off).
    func engineWantsLoginCapture() -> Bool
    func engineLoginSubmitted(origin: String, user: String, password: String)
    /// The person put the cursor in a password field: the moment to offer a saved sign-in.
    func engineLoginFieldFocused(origin: String?, usernameOnly: Bool)
    /// A password was typed (and a name with it); the sign-in has not been sent. Kept in memory so the person can save it from the page.
    func engineLoginTyped(origin: String, user: String, password: String)
    /// DX-07: a media observation from a frame of the page (already checked; the frame's origin is the engine's, not the page's), and a committed navigation, after which earlier observations are void.
    func engineMediaObserved(_ observation: MediaObservation)
    func engineMediaNavigated()
    /// A script asked for a new window and the person had just clicked or typed: the new page, connected to this one. Nil if none could be made.
    func engineOpenPopup(configuration: AnyObject) -> TabEngine?
    /// A script asked for a new window with no click or key press behind it, and it was not opened.
    func engineBlockedPopup(url: URL?)
    /// A page bounced through many different sites before settling.
    func engineSuspiciousRedirect(sites: [String])
    /// Whether this site may open windows without a click (the person allowed it, or blocking is off).
    func enginePopupsAllowedWithoutGesture() -> Bool
    /// A choice from the page's link menu.
    func engineLinkAction(_ url: URL, _ action: LinkAction)
    /// The page's right-click menu asked for the Downloads window; the window that owns the page opens it.
    func engineShowDownloads()
    /// The person clicked a magnet or eD2k link. true if the browser handled it (nothing more happens in the page).
    func engineCustomLink(_ url: URL, linkActivated: Bool) -> Bool
    /// A choice from the extra part of the page's right-click menu, and whether that part is switched on.
    func enginePageMenuAction(_ action: PageMenuAction, target: PageMenuTarget)
    func enginePageMenuEnabled() -> Bool
    /// A typed character while no text field has the keyboard. True means the browser acted on it.
    func engineVimKey(_ key: String) -> Bool
    /// Synchronous: engines must not start the navigation until this returns.
    func engineDecideNavigation(url: URL, mainFrame: Bool) -> NavDecision
    func engineOpenInNewTab(url: URL, userInitiated: Bool)
    func engineRequestPermission(origin: String, kinds: [PermissionType]) async -> Bool
    func engineRequestClose()
    /// The page declared (or dropped) a theme colour. Engines that cannot report one never call this.
    func engineThemeColorChanged(_ tint: PageTint?)
    /// The user scrolled the page. Positive moves the page toward its top, negative further down.
    func engineScrolled(deltaY: Double)
    /// How far down the page now is, in screens, with how far it just moved (positive toward the top). Only the person's own scrolling reports this.
    func engineScrollPosition(screens: Double, deltaY: Double)
    /// The page named these icon addresses, best first (read in the engine; none if it named none).
    /// The icons a page declared, read when it finished loading. `page` is the address those links were read from, captured then, not whatever the tab shows later.
    func engineIconsFound(_ candidates: [IconCandidate], page: URL)
    /// A website's sign-in box: the saved sign-in for it (in normal tabs only), and what to do with one the user chose to keep or that failed.
    func engineSavedSignIn(space: SignInSpace) -> (user: String, password: String)?
    func engineRememberSignIn(space: SignInSpace, user: String, password: String)
    func engineForgetSignIn(space: SignInSpace)
    var enginePrivate: Bool { get }
}

/// One page in a tab's back or forward list. `offset` is how far from the page in front: -1 is the one before, 1 the one after.
struct NavEntry: Identifiable, Equatable {
    let offset: Int
    let title: String
    let url: URL?
    var id: Int { offset }
    /// What to show: the page's title, or its address when it has none.
    var label: String { title.isEmpty ? (url?.host ?? url?.absoluteString ?? "Untitled") : title }
}

extension TabEngine {
    func navigationEntries() -> (back: [NavEntry], forward: [NavEntry]) { ([], []) }
    func navigate(toOffset offset: Int) {}

    func readableContent() async -> ReadableArticle? { nil }
    func collectLinks() async -> LinkPageSnapshot { LinkPageSnapshot(candidates: [], truncated: false) }
    func collectImages() async -> LinkPageSnapshot { LinkPageSnapshot(candidates: [], truncated: false) }
    func scanPageLinks() async -> PageLinkScan { PageLinkScan(links: [], truncated: false) }
    func discoverMedia() async -> MediaPageSnapshot { MediaPageSnapshot(hits: [], truncated: false) }
    /// DX-07: asks the page's observer to look again (a single-page app changed route). Engines without an observer do nothing.
    func rescanMedia() {}
    func pageDiagnostics() async -> [String: Any]? { nil }
    func consentOutcome(rerun: Bool) async -> String? { nil }
    func webAppMetadata() async -> String? { nil }
    func setSponsorSpans(videoID: String, json: String) async {}
    func sponsorStats() async -> String? { nil }
    func pickElement() async -> [String: Any]? { nil }
    func cancelPicking() {}
    func loginFormOrigin() async -> String? { nil }
    func fillLogin(origin: String, user: String, password: String) async -> Bool { false }
    func runScratch(_ code: String) async -> String { "Not available in this engine." }
    func setInspectable(_ on: Bool) {}
    func probeMediaCapabilities() async -> [String: Any]? { nil }
    func setGestures(_ options: GestureOptions) {}
    func pageHasSensitiveForm() async -> Bool { true }
    func pageMetadata() async -> [String: String]? { nil }
    func securityReport() async -> SecurityReport? { nil }
    func connectionCertificate() async -> Data? { nil }
    func setUserAgent(_ value: String?) {}
    func controlVideo(id: Int, action: String, value: Double) async -> String? { nil }
    func fillCouponField(_ code: String) async -> Bool { false }
    func scrollFraction() async -> Double? { nil }
    func audioPlaying() async -> Bool { false }
    func saveScrollState() async {}
    func restoreScrollState() {}
    func respondsWithin(_ seconds: Double) async -> Bool { true }
    func devLog() async -> DevLog? { nil }
    func pageSource() async -> String? { nil }
    func userAgentString() async -> String? { nil }
    func loadLocalFile(_ url: URL) {}
    func setScrollFraction(_ fraction: Double) async {}
    func pageNetwork() async -> PageNetworkReport { PageNetworkReport() }
    func setMuted(_ on: Bool) async {}
    func scrollTo(fraction: Double) async {}
    func formDraftFields() async -> [[String: Any]]? { nil }
    func restoreFormDraft(_ fields: [[String: Any]]) async -> Int { 0 }
    func extractPageData() async -> [String: Any]? { nil }
    func scrollToHeading(_ index: Int) async {}
    func mediaElements() async -> [[String: Any]]? { nil }
    func blockedMediaFrames() async -> Int { 0 }
    func mediaData(_ script: String, id: Int) async -> [String: Any]? { nil }
    func showHTML(_ html: String, baseURL: URL?) {}
    func presentNativeFind() {}
    func pagePDF() async -> Data? { nil }
    func blockedAttempts() async -> Int { 0 }
    func selectedText() async -> String? { nil }
    func pageText() async -> String? { nil }
    func agentSnapshot() async -> [String: Any]? { nil }
    func agentInspect(_ index: Int) async -> [String: Any]? { nil }
    func agentClick(_ index: Int) async -> Bool { false }
    func agentType(_ index: Int, text: String, pressEnter: Bool) async -> Bool { false }
    func agentScroll(down: Bool) async {}
    func screenshot(fullPage: Bool) async -> Data? { nil }
    func setDesktopMode(_ on: Bool) {}
    func setMobileSite(_ on: Bool) {}
    func setJavaScriptEnabled(_ on: Bool) {}
    func setPageDarkening(_ on: Bool) {}
    func setWebsiteAppearance(_ mode: String) {}
    func setViewportInsets(top: CGFloat, bottom: CGFloat) {}
    func setSiteStyle(_ css: String?) {}
    /// Runs one of the browser's own short scripts in the page, with its values passed as data.
    func runPageScript(_ script: String, arguments: [String: Any]) {}
    func scrollToEdge(bottom: Bool) {}
    func scrollBy(_ points: Double) {}
}

extension TabEngineEvents {
    func engineLoadFailed(url: URL?, domain: String, code: Int, description: String) { engineLoadFailed(url: url, description: description) }
    func engineHTTPFailure(url: URL?, status: Int) {}
    func engineCaptureChanged(camera: Bool, microphone: Bool) {}
    func engineMouseGesturesEnabled() -> Bool { false }
    func engineScriptsAllowed(for url: URL) -> Bool { true }
    func engineMouseGesture(_ sequence: String, finished: Bool) {}
    func engineFixedBars(top: Bool, bottom: Bool) {}
    func engineWantsLoginCapture() -> Bool { false }
    func engineLoginSubmitted(origin: String, user: String, password: String) {}
    func engineLoginFieldFocused(origin: String?, usernameOnly: Bool) {}
    func engineLoginTyped(origin: String, user: String, password: String) {}
    func engineMediaObserved(_ observation: MediaObservation) {}
    func engineMediaNavigated() {}
    func engineOpenPopup(configuration: AnyObject) -> TabEngine? { nil }
    func engineBlockedPopup(url: URL?) {}
    func engineSuspiciousRedirect(sites: [String]) {}
    func enginePopupsAllowedWithoutGesture() -> Bool { false }
    func engineLinkAction(_ url: URL, _ action: LinkAction) {}
    func engineShowDownloads() {}
    func engineCustomLink(_ url: URL, linkActivated: Bool) -> Bool { false }
    func enginePageMenuAction(_ action: PageMenuAction, target: PageMenuTarget) {}
    func enginePageMenuEnabled() -> Bool { false }
    func engineVimKey(_ key: String) -> Bool { false }
    func engineThemeColorChanged(_ tint: PageTint?) {}
    func engineScrolled(deltaY: Double) {}
    func engineScrollPosition(screens: Double, deltaY: Double) {}
    func engineIconsFound(_ candidates: [IconCandidate], page: URL) {}
    func engineSavedSignIn(space: SignInSpace) -> (user: String, password: String)? { nil }
    func engineRememberSignIn(space: SignInSpace, user: String, password: String) {}
    func engineForgetSignIn(space: SignInSpace) {}
    var enginePrivate: Bool { false }
}

@MainActor
protocol TabEngine: AnyObject {
    var hostView: PlatformView { get }
    /// The article on the page, if it has one (for the reader). Engines that cannot read a page return nil.
    func readableContent() async -> ReadableArticle?
    /// Addresses of the links on the open page, read once and only when the person asks (never on load). Engines that cannot read a page return none.
    func collectLinks() async -> LinkPageSnapshot
    func collectImages() async -> LinkPageSnapshot
    /// Every link the page offers (address and whether the page marks it as a download), read passively and boundedly for the toolbar's category counts.
    func scanPageLinks() async -> PageLinkScan
    /// The media elements and media links of the open page, read once and only when the person asks. Engines that cannot read a page return none.
    func discoverMedia() async -> MediaPageSnapshot
    func rescanMedia()
    /// Resource timing, storage keys, page errors and load numbers, for the developer tools.
    func pageDiagnostics() async -> [String: Any]?
    /// What the cookie-banner script made of the page's banner, as a small JSON text (a state word and the tool's name), or nil. With `rerun` the script looks again first.
    func consentOutcome(rerun: Bool) async -> String?
    /// The page's own description of itself as an app (manifest name, start address, icons), as a JSON text, or nil.
    func webAppMetadata() async -> String?
    /// Hands SponsorBlock's segments for a video to the page's script (as data), and reads back how many were skipped.
    func setSponsorSpans(videoID: String, json: String) async
    func sponsorStats() async -> String?
    /// Waits for the person to click an element on the page and describes it (nil if they cancel or nothing is picked within a minute).
    func pickElement() async -> [String: Any]?
    func cancelPicking()
    /// The origin of the page if it shows a sign-in form (a visible password field), else nil.
    func loginFormOrigin() async -> String?
    /// Types the name and password into the page's sign-in form, only if the page is still on `origin`.
    func fillLogin(origin: String, user: String, password: String) async -> Bool
    func runScratch(_ code: String) async -> String
    /// Lets Safari's Web Inspector attach to this tab.
    func setInspectable(_ on: Bool)
    /// What this engine can play (DRM, streaming, codecs, fullscreen, PiP, AirPlay), and the state of each player on the page.
    func probeMediaCapabilities() async -> [String: Any]?
    /// Which touch and trackpad gestures the page area responds to.
    func setGestures(_ options: GestureOptions)
    /// True when the page has a password, card or one-time-code box, so its text must not be copied.
    func pageHasSensitiveForm() async -> Bool
    /// Play, pause, speed, Picture in Picture or full screen for one player on the page, named by the number `mediaElements` gave it (nil: it worked; else why not); typing a saved code into the page's coupon box.
    func controlVideo(id: Int, action: String, value: Double) async -> String?
    func fillCouponField(_ code: String) async -> Bool
    /// How far down the page you are (0 to 1), and going back there; long unsent text in the page's text boxes, and putting it back into empty ones.
    func scrollFraction() async -> Double?
    /// True when a player on the page is running with sound the person could hear. Muting silences every player on the page and keeps new ones silent.
    func audioPlaying() async -> Bool
    /// Remembers where the page and its inner scrolling areas (a chat's message list) are scrolled, and puts them back after a tab switch if the page lost its place.
    func saveScrollState() async
    func restoreScrollState()
    /// False when the page does not answer a trivial script within the time (a hung page). Engines that cannot tell say true.
    func respondsWithin(_ seconds: Double) async -> Bool
    /// The page's console, WebSocket and failed-resource log, when developer capture is on. Nil when nothing was captured.
    func devLog() async -> DevLog?
    /// The page as it is now (after scripts ran), the browser's user-agent string, and a local file such as a saved web archive.
    func pageSource() async -> String?
    func userAgentString() async -> String?
    func loadLocalFile(_ url: URL)
    /// Scrolls the page to this share of its height (0 top, 1 bottom), for linked split panels.
    func setScrollFraction(_ fraction: Double) async
    /// Requests the content rules refused and the other sites the page loaded from, read from the page itself.
    func pageNetwork() async -> PageNetworkReport
    func setMuted(_ on: Bool) async
    func scrollTo(fraction: Double) async
    func formDraftFields() async -> [[String: Any]]?
    func restoreFormDraft(_ fields: [[String: Any]]) async -> Int
    /// Pictures, tables, document links and headings on the page, and scrolling to a heading by its position.
    func extractPageData() async -> [String: Any]?
    func scrollToHeading(_ index: Int) async
    func mediaElements() async -> [[String: Any]]?
    /// How many players sit in frames from other sites, which a page cannot reach into (so they cannot be controlled, only counted).
    func blockedMediaFrames() async -> Int
    /// A structured answer from one player (a captured picture, its subtitles), named by the number `mediaElements` gave it.
    func mediaData(_ script: String, id: Int) async -> [String: Any]?
    /// Shows generated HTML in place of the page. `baseURL` is where its pictures resolve from.
    func showHTML(_ html: String, baseURL: URL?)
    /// Page tools. Engines that cannot do one ignore it.
    func setDesktopMode(_ on: Bool)
    /// Mac: asks sites for their phone version (the way a phone introduces itself). Engines that cannot ignore it.
    func setMobileSite(_ on: Bool)
    func setJavaScriptEnabled(_ on: Bool)
    func setPageDarkening(_ on: Bool)
    /// Which look websites are asked for ("system", "light" or "dark"), apart from the browser's own appearance.
    func setWebsiteAppearance(_ mode: String)
    /// iPhone: points at the foot of the page that a floating toolbar covers.
    /// Keeps the page's own layout (its fixed headers and bottom bars, not only its scrolling) clear of the status bar and of a toolbar floating over it.
    func setViewportInsets(top: CGFloat, bottom: CGFloat)
    /// Adds (or with nil, removes) a small style sheet of the user's own on the page: CSS only, never script.
    func setSiteStyle(_ css: String?)
    /// Runs one of the browser's own short scripts in the page, with its values passed as data.
    func runPageScript(_ script: String, arguments: [String: Any])
    func scrollToEdge(bottom: Bool)
    func scrollBy(_ points: Double)
    /// Opens the system's own find bar for the page, on platforms that have one (the iPhone). Default: nothing.
    func presentNativeFind()
    /// The whole page as a PDF, or as a picture (just what is on screen, or the entire page top to bottom). nil when not possible.
    func pagePDF() async -> Data?
    /// The pages behind and ahead of this one in the tab, nearest first (at most fifteen each way).
    func navigationEntries() -> (back: [NavEntry], forward: [NavEntry])
    /// Goes to the page that many steps back (negative) or forward (positive).
    func navigate(toOffset offset: Int)
    /// How many loads on the page in front were refused so far (picture, script or frame attempts the rules stopped). An estimate.
    func blockedAttempts() async -> Int
    /// What is selected on the page, and the page's plain text (capped), for highlights and translation.
    func selectedText() async -> String?
    /// What the page and its connection look like from a security point of view: certificate chain, parts loaded without encryption, redirects.
    func securityReport() async -> SecurityReport?
    /// The DER bytes of the site's own certificate for the page that is showing, or nil when it is not an encrypted page.
    func connectionCertificate() async -> Data?
    /// Asks sites for a different browser identity (nil: the normal one). Takes effect on the next load.
    func setUserAgent(_ value: String?)
    /// What the page says about itself (title, author, date, site) from its own tags; nil when it says nothing.
    func pageMetadata() async -> [String: String]?
    func pageText() async -> String?
    /// For AI tools the person has allowed: the visible text and a numbered list of things to click or type into.
    func agentSnapshot() async -> [String: Any]?
    /// What the page says about one numbered element, read just before acting on it; nil when it is gone.
    func agentInspect(_ index: Int) async -> [String: Any]?
    func agentClick(_ index: Int) async -> Bool
    func agentType(_ index: Int, text: String, pressEnter: Bool) async -> Bool
    func agentScroll(down: Bool) async
    func screenshot(fullPage: Bool) async -> Data?
    /// URL of the page the engine actually committed (nil until something has loaded).
    var currentURL: URL? { get }
    var zoomFactor: Double { get set }
    func load(_ url: URL)
    func reload()
    func stop()
    func goBack()
    func goForward()
    /// Shows a local error page. Must bypass navigation policy (it is app-generated content).
    func showErrorPage(title: String, detail: String, baseURL: URL?, offersSavedCopy: Bool)
    /// Highlights the next match in the page; returns whether a match was found.
    func find(_ text: String, backwards: Bool) async -> Bool
    func clearFind()
    /// PNG snapshot of the visible page, used for tab overview cards.
    func snapshot() async -> Data?
    /// True while the page is loading, playing media, or using the camera or microphone: not a moment to release it.
    func isBusy() async -> Bool
    /// Opaque back/forward and scroll state, so a released tab can come back where it was.
    func captureState() -> Any?
    func restoreState(_ state: Any)
    /// Shows the system print panel for the page (which also offers Save as PDF).
    func printPage()
    /// The page and its resources as one saved-page archive, or nil when there is nothing to save.
    func webArchive() async -> Data?
    func close()
}

@MainActor
protocol BrowserEngine: AnyObject {
    var name: String { get }
    var downloads: DownloadCoordinator { get }
    func prepare() async
    /// `container` names a separate identity: the tab keeps cookies and storage of its own. "scratch" is storage that exists only for that one tab.
    func makeTab(isPrivate: Bool, profile: String, container: String?, events: TabEngineEvents) -> TabEngine
    /// A tab of a private window: `privateSession` names that window's own temporary storage, shared by its tabs and by nothing else (nil is the storage the private tabs of ordinary windows share).
    func makeTab(isPrivate: Bool, profile: String, container: String?, privateSession: UUID?, events: TabEngineEvents) -> TabEngine
    /// A private window closed: its temporary storage is dropped with it.
    func releasePrivateSession(_ id: UUID)
    /// A page that a script opened with window.open: it is built from the configuration the page's engine hands over, so it stays connected to the page that opened it.
    func makePopupTab(configuration: AnyObject, events: TabEngineEvents) -> TabEngine?
    /// Installs (or, with nil, removes) the privacy rules on every tab. Keeps the previous rules if the new ones fail.
    func applyProtection(_ snapshot: PolicySnapshot?) async -> InstallReport
    /// Called when the last private tab closed: the next private tab must start with empty storage.
    func privateSessionEnded()
    func cookies(profile: String, isPrivate: Bool) async -> [CookieInfo]
    func clearData(profile: String) async
    func removeProfileData(profile: String) async
    /// Connects web extension support for a profile: extensions live in `directory`, and `host` supplies the tabs.
    func attachExtensions(center: ExtensionCenter, profile: String, directory: URL, host: ExtensionHost)
    /// Websites that have stored data in this profile.
    func siteData(profile: String) async -> [SiteDataInfo]
    func removeSiteData(host: String, profile: String) async
    /// The scripts to run on pages in normal tabs (never private ones). Replaces the previous set on every open tab.
    func setUserScripts(_ scripts: [UserScript])
    /// Where the scripts that were given storage keep their values (kept by the profile, not by the engine).
    func setUserScriptStorage(_ storage: UserScriptStorage?)
    /// Switches the page's WebRTC off (except on the named sites), for tabs opened afterwards and, by reinstalling, the ones that are open.
    func setWebPolicy(_ policy: WebPolicy)
    /// Returns once the blocking rules of the last `setWebPolicy` are attached, so the first page of a session is already filtered by them.
    func policyRulesReady() async
    /// Sends page loads in every profile (private ones too) through the proxy, or, with nil, directly. Takes effect for pages opened afterwards.
    func setProxy(_ proxy: ProxyConfig?, password: String?)
}

extension TabEngine {
    func showErrorPage(title: String, detail: String, baseURL: URL?) { showErrorPage(title: title, detail: detail, baseURL: baseURL, offersSavedCopy: false) }
}

extension BrowserEngine {
    func makeTab(isPrivate: Bool, profile: String, container: String?, privateSession: UUID?, events: TabEngineEvents) -> TabEngine {
        makeTab(isPrivate: isPrivate, profile: profile, container: container, events: events)
    }
    func releasePrivateSession(_ id: UUID) {}
    func setUserScripts(_ scripts: [UserScript]) {}
    func setUserScriptStorage(_ storage: UserScriptStorage?) {}
    func setWebPolicy(_ policy: WebPolicy) {}
    func policyRulesReady() async {}
    func setProxy(_ proxy: ProxyConfig?, password: String?) {}
}

/// Engine-neutral error page markup shared by all engines.
enum ErrorPage {
    /// `offersSavedCopy` adds a link that asks the Internet Archive for a saved copy of the page. The link carries no address: the tab already knows which page failed.
    static func html(title: String, detail: String, offersSavedCopy: Bool = false) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <style>
        :root{color-scheme:light dark;--bg1:#f6f8fb;--bg2:#e7edf5;--ink:#1d2430;--dim:#5b6676;--card:rgba(255,255,255,.78);--edge:rgba(20,30,50,.10);--accent:#0d8299;--glow1:rgba(96,170,215,.45);--glow2:rgba(170,150,240,.38)}
        @media (prefers-color-scheme:dark){:root{--bg1:#0c0f17;--bg2:#080a10;--ink:#eef1f6;--dim:#9aa4b5;--card:rgba(255,255,255,.06);--edge:rgba(255,255,255,.12);--accent:#3bb8cf;--glow1:rgba(30,110,150,.40);--glow2:rgba(110,70,190,.30)}}
        *{box-sizing:border-box}
        body{margin:0;height:100vh;display:flex;align-items:center;justify-content:center;font:16px/1.5 -apple-system,system-ui,sans-serif;color:var(--ink);
        background:radial-gradient(60em 40em at 12% 8%,var(--glow1),transparent 60%),radial-gradient(50em 36em at 92% 14%,var(--glow2),transparent 60%),linear-gradient(180deg,var(--bg1),var(--bg2))}
        main{width:min(30em,calc(100% - 2.5em));text-align:center;padding:2.2em 2em 2em;border-radius:22px;background:var(--card);border:1px solid var(--edge);
        box-shadow:0 1px 2px rgba(0,0,0,.08),0 18px 48px -12px rgba(13,130,153,.28);-webkit-backdrop-filter:blur(24px) saturate(1.3);backdrop-filter:blur(24px) saturate(1.3)}
        svg{width:84px;height:84px;display:block;margin:0 auto 1em;filter:drop-shadow(0 8px 14px rgba(13,130,153,.35))}
        h1{font-size:1.45em;line-height:1.25;margin:0 0 .4em;letter-spacing:-.01em}
        p{margin:.5em 0 0;color:var(--dim)}
        a{color:var(--accent);text-decoration:none;font-weight:500}a:hover{text-decoration:underline}a:focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:4px}
        </style>
        <main role=main><svg viewBox="0 0 84 84" aria-hidden="true"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#4fc3d9"/><stop offset="1" stop-color="#0d7f96"/></linearGradient>
        <linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".6" stop-color="#fff" stop-opacity="0"/></linearGradient></defs>
        <path d="M42 6 70 16v22c0 17-11.5 31-28 38C25.500 69 14 55 14 38V16Z" fill="url(#g)"/><path d="M42 6 70 16v22c0 17-11.5 31-28 38C25.500 69 14 55 14 38V16Z" fill="url(#s)"/>
        <path d="M42 24v20" stroke="#fff" stroke-width="5" stroke-linecap="round"/><circle cx="42" cy="54" r="3.2" fill="#fff"/></svg>
        <h1>\(esc(title))</h1><p>\(esc(detail))</p>\(offersSavedCopy ? "<p><a href=\"browsersetu://savedcopy\">Look for a saved copy on the Internet Archive</a></p>" : "")</main>
        """
    }
}

/// The gestures the page area can respond to. Each can be turned off in Settings.
struct GestureOptions: Equatable {
    /// Swipe from the edge (iPhone) or with two fingers (Mac) to go back and forward.
    var backForward = true
    /// Pinch to zoom the page.
    var pinchZoom = true
    /// Pull down at the top of a page to reload it (iPhone).
    var pullToRefresh = true
}

/// What the page's link menu can do with a link beyond opening it in place.
enum LinkAction { case newTab, backgroundTab, privateTab, split, otherPane, glance }

extension BrowserEngine {
    func makePopupTab(configuration: AnyObject, events: TabEngineEvents) -> TabEngine? { nil }
}

/// What the page's links came to: the ones likely to be downloads, and whether the page had more than the limit.
struct PageLinkScan: Equatable, Sendable {
    var links: [(href: String, marked: Bool)]
    var truncated: Bool
    /// The pictures the page shows (`<img>`, `srcset`, lazy-load attributes): the address of the best version of each, read in the same one-time scan. Plain pictures are not links, so the links alone never saw them.
    var images: [String] = []
    /// Each link's own title or label, by address, where the page gave one.
    var labels: [String: String] = [:]
    static func == (a: Self, b: Self) -> Bool { a.truncated == b.truncated && a.images == b.images && a.links.count == b.links.count && zip(a.links, b.links).allSatisfy { $0.href == $1.href && $0.marked == $1.marked } }
}

struct LinkPageSnapshot: Equatable, Sendable {
    var candidates: [String]
    var truncated: Bool
}
