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
    func engineDidFinishLoading()
    func engineLoadFailed(url: URL?, description: String)
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
    /// The page named these icon addresses, best first (read in the engine; none if it named none).
    func engineIconsFound(_ urls: [URL])
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
    func pageDiagnostics() async -> [String: Any]? { nil }
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
    func controlVideo(index: Int, action: String, value: Double) async {}
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
    func showHTML(_ html: String, baseURL: URL?) {}
    func presentNativeFind() {}
    func pagePDF() async -> Data? { nil }
    func blockedAttempts() async -> Int { 0 }
    func selectedText() async -> String? { nil }
    func pageText() async -> String? { nil }
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
    func engineMouseGesturesEnabled() -> Bool { false }
    func engineScriptsAllowed(for url: URL) -> Bool { true }
    func engineMouseGesture(_ sequence: String, finished: Bool) {}
    func engineFixedBars(top: Bool, bottom: Bool) {}
    func engineWantsLoginCapture() -> Bool { false }
    func engineLoginSubmitted(origin: String, user: String, password: String) {}
    func engineLoginFieldFocused(origin: String?, usernameOnly: Bool) {}
    func engineLoginTyped(origin: String, user: String, password: String) {}
    func engineOpenPopup(configuration: AnyObject) -> TabEngine? { nil }
    func engineBlockedPopup(url: URL?) {}
    func engineSuspiciousRedirect(sites: [String]) {}
    func enginePopupsAllowedWithoutGesture() -> Bool { false }
    func engineLinkAction(_ url: URL, _ action: LinkAction) {}
    func engineVimKey(_ key: String) -> Bool { false }
    func engineThemeColorChanged(_ tint: PageTint?) {}
    func engineScrolled(deltaY: Double) {}
    func engineIconsFound(_ urls: [URL]) {}
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
    /// Resource timing, storage keys, page errors and load numbers, for the developer tools.
    func pageDiagnostics() async -> [String: Any]?
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
    /// Play, pause, speed, Picture in Picture or full screen for one player on the page; typing a saved code into the page's coupon box.
    func controlVideo(index: Int, action: String, value: Double) async
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
    func showErrorPage(title: String, detail: String, baseURL: URL?)
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
    /// Switches the page's WebRTC off (except on the named sites), for tabs opened afterwards and, by reinstalling, the ones that are open.
    func setWebPolicy(_ policy: WebPolicy)
    /// Sends page loads in every profile (private ones too) through the proxy, or, with nil, directly. Takes effect for pages opened afterwards.
    func setProxy(_ proxy: ProxyConfig?, password: String?)
}

extension BrowserEngine {
    func setUserScripts(_ scripts: [UserScript]) {}
    func setWebPolicy(_ policy: WebPolicy) {}
    func setProxy(_ proxy: ProxyConfig?, password: String?) {}
}

/// Engine-neutral error page markup shared by all engines.
enum ErrorPage {
    static func html(title: String, detail: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
        <style>:root{color-scheme:light dark}body{font:16px -apple-system,system-ui;display:flex;align-items:center;
        justify-content:center;height:100vh;margin:0;text-align:center}div{max-width:30em;padding:1.5em}
        h1{font-size:1.4em}p{opacity:.7}</style><div><h1>\(esc(title))</h1><p>\(esc(detail))</p></div>
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
enum LinkAction { case newTab, backgroundTab, privateTab, split, otherPane }

extension BrowserEngine {
    func makePopupTab(configuration: AnyObject, events: TabEngineEvents) -> TabEngine? { nil }
}
