import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// What the buttons on an error page do, and how the page is laid over a tab.

@MainActor
extension TabController {
    func performErrorAction(_ action: BrowserErrorAction) {
        guard let model else { return }
        let target = errorInfo?.url ?? failedURL
        switch action {
        case .tryAgain, .reload:
            // A page that keeps crashing refuses to reload for a minute (see `reload`); everything else loads the same address again, once, as a plain page load.
            reload()
        case .goBack:
            leaveError()
        case .checkAddress:
            model.openSearchPanel(prefill: target?.absoluteString)
        case .networkSettings:
            #if os(macOS)
            if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") { NSWorkspace.shared.open(url) }
            #else
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            #endif
        case .openSettings:
            #if os(macOS)
            SettingsRouter.open(.general)
            #else
            model.sheet = .settings
            #endif
        case .savedCopy:
            Task { await model.openSavedCopy(of: target, in: self) }
        case .goHome:
            if let home = model.homepageURL { load(home) } else if let blank = URL(string: "about:blank") { load(blank) }
        case .reviewProtection:
            model.sheet = .sitePrivacy
        case .copyAddress:
            if let target { copyToPasteboard(target.absoluteString); model.notice = "Copied the address." }
        case .chooseAnotherFile:
            #if os(macOS)
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let file = panel.url { allowedLocalFile = file; load(file) }
            #else
            model.notice = "Open a file from the Files app, then choose Open in Browser Setu."
            #endif
        case .playOffline:
            break       // handled inside the page: it only shows the games
        }
    }
}

/// Lays the native error page over a tab's page area while the tab has an error. `compact` is for narrow places (a side panel, a peek).
struct TabErrorOverlay: ViewModifier {
    @ObservedObject var tab: TabController
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if let info = tab.errorInfo {
                    // There is somewhere to go back to when a different page is still showing behind the error (the load that failed never replaced it), or history goes further back.
                    let pageBehind = tab.engine.currentURL.map { $0 != info.url } ?? false
                    ErrorPageView(info: info, canGoBack: pageBehind || tab.canGoBack, isPublicWeb: PublicAddress.isPublicWeb(info.url), embedded: compact) { tab.performErrorAction($0) }
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: tab.errorInfo != nil)
    }
}

extension View {
    func tabErrorOverlay(_ tab: TabController, compact: Bool = false) -> some View { modifier(TabErrorOverlay(tab: tab, compact: compact)) }
}
