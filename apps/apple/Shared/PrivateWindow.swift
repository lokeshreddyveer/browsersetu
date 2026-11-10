import Foundation

// Private windows. A private window is a window whose every tab is private, with storage of its own that exists only while the window does. It is not a guest window: the person's
// bookmarks and saved passwords stay available (a guest window hides them). Private tabs in an ordinary window keep working as before.

/// What ⇧⌘N does (Settings › Tabs). The two explicit menu commands never ask.
enum PrivateOpenMode: String, CaseIterable, Identifiable {
    case window, tab, ask
    var id: String { rawValue }
    var title: String {
        switch self {
        case .window: "Open a private window"
        case .tab: "Open a private tab in this window"
        case .ask: "Ask every time"
        }
    }
}

enum PrivateOpening {
    /// What to do when the person asks for private browsing without saying how.
    enum Action: Equatable { case tabHere, newWindow, askFirst }

    /// In a window that is already private (a private or guest window) a new private page is simply a tab there: asking, or opening yet another window, would only get in the way.
    /// Only the Mac has windows to open: elsewhere it is always a tab.
    static func action(mode: PrivateOpenMode, inPrivateContext: Bool, canOpenWindows: Bool) -> Action {
        if inPrivateContext || !canOpenWindows { return .tabHere }
        switch mode {
        case .window: return .newWindow
        case .tab: return .tabHere
        case .ask: return .askFirst
        }
    }
}

/// Which tabs may move between windows. A tab's privacy belongs to the storage it was made with, so moving a private window's tab elsewhere (or any tab into a private window) would
/// silently change who can see its cookies. Those moves are refused; the person is offered a fresh copy instead.
enum PrivateTabMove {
    enum Refusal: Equatable {
        case leavesPrivateWindow, entersPrivateWindow, normalTabInGuest
        var message: String {
            switch self {
            case .leavesPrivateWindow: "A private window's tabs stay in it. Open the page in a new private tab instead."
            case .entersPrivateWindow: "A private window only holds its own tabs. Open the page in a new private tab there instead."
            case .normalTabInGuest: "A guest window only holds private tabs."
            }
        }
    }

    static func refusal(tabIsPrivate: Bool, sourceIsPrivateWindow: Bool, targetIsPrivateWindow: Bool, targetIsGuest: Bool) -> Refusal? {
        if sourceIsPrivateWindow { return .leavesPrivateWindow }
        if targetIsPrivateWindow { return .entersPrivateWindow }
        if targetIsGuest, !tabIsPrivate { return .normalTabInGuest }
        return nil
    }
}

extension BrowserModel {
    /// Whether this window's tabs may be offered to automation and to the AI-tool connection. Guest and private windows never are (a private tab is also refused one by one, by `TabPrivacy`;
    /// this keeps the whole window out of the list).
    var isOfferedToAutomation: Bool { !isGuest && !isPrivateWindow }
}

/// Every private window's session id since the app started (ids only, kept for the run). A task that came from such a session stays out of every other window's Downloads list, including after
/// its window has closed.
@MainActor
enum PrivateWindowSessions {
    static var known = Set<UUID>()
}

/// Who may see a task in a Downloads list. An ordinary task: everyone. A private task of a private window: that window only. A private task of any other private session (the private tabs of
/// ordinary windows share one): ordinary windows only, never a private window.
enum PrivateDownloadVisibility {
    static func isVisible(isPrivate: Bool, session: UUID?, viewer: UUID?, privateWindowSessions: Set<UUID>) -> Bool {
        guard isPrivate else { return true }
        if let session, privateWindowSessions.contains(session) { return session == viewer }
        return viewer == nil
    }
}

extension DownloadCoordinator {
    /// A private window closed: what it was still downloading stops with it. (It would otherwise go on, in a list nobody can open; the finished files already on disk are kept.)
    func cancelPrivateSession(_ session: UUID) {
        for (id, record) in ledger.records where record.privateSession == session && !record.state.isFinal { cancel(id) }
    }
}

extension Notification.Name {
    /// A window has become a private window (posted by it, with the window's model as the object).
    static let privateWindowStarted = Notification.Name("BrowserSetuPrivateWindowStarted")
}
