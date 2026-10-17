import SwiftUI

/// What to wipe each time the browser is closed. It is done as the browser next opens, before any page loads.
enum ClearOnQuit: String, CaseIterable, Identifiable {
    case never, history, siteData, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: "Never"
        case .history: "Browsing history"
        case .siteData: "Cookies and website data"
        case .both: "History, cookies and website data"
        }
    }
    var clearsHistory: Bool { self == .history || self == .both }
    var clearsSiteData: Bool { self == .siteData || self == .both }
}

/// The colours a tab group can have.
enum GroupColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, grey
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .red: Color(red: 0.88, green: 0.32, blue: 0.30)
        case .orange: Color(red: 0.92, green: 0.54, blue: 0.22)
        case .yellow: Color(red: 0.92, green: 0.76, blue: 0.22)
        case .green: Color(red: 0.30, green: 0.68, blue: 0.40)
        case .teal: Color(red: 0.12, green: 0.62, blue: 0.66)
        case .blue: Color(red: 0.28, green: 0.50, blue: 0.90)
        case .purple: Color(red: 0.58, green: 0.40, blue: 0.86)
        case .pink: Color(red: 0.90, green: 0.40, blue: 0.62)
        case .grey: Color(red: 0.55, green: 0.57, blue: 0.62)
        }
    }
}

extension BrowserModel {
    // MARK: Per-site zoom

    private static let maxZoomSites = 500

    func siteZoomFactor(forHost host: String?) -> Double? {
        guard let key = FaviconStore.key(forHost: host) else { return nil }
        return siteZoom[key]
    }

    /// Remembers how far a site is zoomed. Back to 100% forgets it.
    func rememberZoom(_ factor: Double, forHost host: String?) {
        guard let key = FaviconStore.key(forHost: host) else { return }
        var map = siteZoom
        if abs(factor - 1) < 0.001 { map[key] = nil } else if map[key] != nil || map.count < Self.maxZoomSites { map[key] = (factor * 100).rounded() / 100 }
        guard map != siteZoom else { return }
        setSiteZoomMap(map)
    }

    func forgetAllSiteZoom() { setSiteZoomMap([:]) }

    // MARK: Group colours

    func groupColor(_ group: String) -> GroupColor? { groupColors[group].flatMap(GroupColor.init(rawValue:)) }

    func setGroupColor(_ group: String, _ color: GroupColor?) {
        var map = groupColors
        map[group] = color?.rawValue
        setGroupColorMap(map)
    }

    // MARK: Workspace themes

    func setWorkspaceAccent(_ name: String, accent: AccentChoice?) {
        guard let i = workspaces.firstIndex(where: { $0.name == name }) else { return }
        workspaceAccentMutate(i, accent?.rawValue)
        if name == activeWorkspace { applyWorkspaceTheme() }
    }

    /// The accent the interface uses now: the active workspace's own if it has one, otherwise the general choice in Settings.
    func applyWorkspaceTheme() {
        let own = workspaces.first { $0.name == activeWorkspace }?.accent.flatMap(AccentChoice.init(rawValue:))
        Theme.accent = (own ?? accent).color
        // A theme brings its own accent, unless the workspace has one of its own.
        if themeIsActive, own == nil { Theme.accent = activeTheme.accent.color }
        objectWillChange.send()
    }

    // MARK: Clear on quit

    /// Runs as the browser opens: wipes what the user chose to wipe when closing. Never under tests.
    func applyClearOnQuit() async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil, recovery == nil, clearOnQuit != .never else { return }
        if clearOnQuit.clearsHistory { try? core.clearHistory(); eraseSearchableCopy() }
        if clearOnQuit.clearsSiteData { await engine.clearData(profile: profileName) }
    }
}
