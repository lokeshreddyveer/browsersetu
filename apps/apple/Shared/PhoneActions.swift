import SwiftUI

/// What each toolbar and menu action does, whether it is on, and whether it can be used on the page in front.
extension PhoneAction {
    @MainActor func isOn(_ model: BrowserModel, _ tab: TabController) -> Bool {
        switch self {
        case .bookmark: model.activeBookmarked
        case .desktopSite: tab.desktopSite
        case .darkPages: model.isDarkSite(tab.url?.host)
        case .javaScript: !tab.javaScriptOn      // "on" means the tool is in use: JavaScript switched off
        default: false
        }
    }

    @MainActor func isEnabled(_ model: BrowserModel, _ tab: TabController) -> Bool {
        let live = !tab.isBlank
        switch self {
        case .back: return tab.canGoBack
        case .forward: return tab.canGoForward
        case .reload, .share, .bookmark, .find, .reader, .copyLink, .print, .savePDF, .savePage, .screenshot, .fullScreenshot, .desktopSite, .javaScript, .translate, .translatePage, .siteStyle, .copyCleanLink, .addReading, .pageNote, .qrCode, .highlight, .scrollBottom, .scrollTop, .darkPages, .zoomIn, .zoomOut, .zoomReset: return live
        case .favorites: return live && !tab.isPrivate
        case .recentlyClosed: return !model.closedTabs.isEmpty
        case .closeDuplicates: return !model.duplicateGroups().isEmpty
        default: return true
        }
    }

    /// The symbol, filled in where a toggle is on.
    @MainActor func symbol(_ model: BrowserModel, _ tab: TabController) -> String {
        switch self {
        case .bookmark: model.activeBookmarked ? "star.fill" : "star"
        case .darkPages: isOn(model, tab) ? "moon.fill" : "moon"
        case .reload: tab.isLoading ? "xmark" : "arrow.clockwise"
        default: symbol
        }
    }

    @MainActor func run(_ model: BrowserModel, _ tab: TabController) {
        switch self {
        case .tabs: model.showOverview()
        case .newTab: model.newTab()
        case .newPrivateTab: model.openTab(url: nil, isPrivate: true)
        case .recentlyClosed: model.reopenClosedTab()
        case .sessions: model.sheet = .sessions
        case .timeline: model.sheet = .timeline
        case .closeDuplicates: model.closeDuplicateTabs()
        case .back: tab.goBack()
        case .forward: tab.goForward()
        case .reload: tab.isLoading ? tab.stop() : tab.reload()
        case .share: model.shareActivePage()
        case .bookmark: model.toggleBookmark()
        case .favorites: if let url = tab.url?.absoluteString { model.toggleFavorite(url: url, title: tab.displayTitle) }
        case .find: model.showFind()
        case .findAllTabs: model.sheet = .findAll
        case .reader: Task { await tab.toggleReader() }
        case .copyLink, .copyCleanLink: model.copyCleanLink()
        case .readingList: model.sheet = .readingList
        case .addReading: Task { await model.addToReadingList() }
        case .pageNote: model.sheet = .note
        case .siteStyle: model.sheet = .style
        case .qrCode: model.sheet = .qr
        case .highlight: Task { await model.highlightSelection() }
        case .translatePage: Task { await model.translateOnDevice() }
        case .print: model.printActive()
        case .savePDF: Task { await model.savePageAsPDF() }
        case .savePage: Task { await model.savePageForLater() }
        case .screenshot: Task { await model.takeScreenshot(fullPage: false) }
        case .fullScreenshot: Task { await model.takeScreenshot(fullPage: true) }
        case .desktopSite: tab.toggleDesktopSite()
        case .darkPages: model.setDarkSite(tab.url?.host, !model.isDarkSite(tab.url?.host)); tab.applyDarkPages()
        case .javaScript: tab.toggleJavaScript()
        case .translate: model.translateActivePage()
        case .scrollBottom: tab.scrollToEdge(bottom: true)
        case .scrollTop: tab.scrollToEdge(bottom: false)
        case .zoomIn: tab.zoom(by: 0.1)
        case .zoomOut: tab.zoom(by: -0.1)
        case .zoomReset: tab.resetZoom()
        case .bookmarks: model.sheet = .bookmarks
        case .history: model.sheet = .history
        case .downloads: model.sheet = .downloads
        case .privacyDashboard: model.sheet = .dashboard
        case .settings: model.sheet = .settings
        }
    }
}

extension BrowserModel {
    /// Opens the page in Google Translate: a plain web address, opened only when the user asks. The page's address goes to Google then.
    func translateActivePage() {
        guard let page = active?.url, ["http", "https"].contains(page.scheme?.lowercased() ?? ""),
              var parts = URLComponents(string: "https://translate.google.com/translate") else { return }
        parts.queryItems = [URLQueryItem(name: "sl", value: "auto"), URLQueryItem(name: "u", value: page.absoluteString)]
        if let url = parts.url { active?.load(url) }
    }

    #if os(iOS)
    func shareActivePage() {
        guard let url = active?.url, let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
    }
    #endif
}

@MainActor func copyToPasteboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}
