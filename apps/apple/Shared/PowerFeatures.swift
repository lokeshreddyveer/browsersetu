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
    /// The colour a group is drawn in when none was chosen, as Chrome gives every new group one: always the same for the same name (not stored; choosing a colour
    /// replaces it). Grey is left out, so an uncoloured group never looks disabled.
    static func automatic(for name: String) -> GroupColor {
        let palette: [GroupColor] = [.blue, .green, .purple, .orange, .teal, .pink, .red, .yellow]
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return palette[sum % palette.count]
    }
    var title: String { rawValue.capitalized }
    var components: (r: Double, g: Double, b: Double) {
        switch self {
        case .red: (0.88, 0.32, 0.30)
        case .orange: (0.92, 0.54, 0.22)
        case .yellow: (0.92, 0.76, 0.22)
        case .green: (0.30, 0.68, 0.40)
        case .teal: (0.12, 0.62, 0.66)
        case .blue: (0.28, 0.50, 0.90)
        case .purple: (0.58, 0.40, 0.86)
        case .pink: (0.90, 0.40, 0.62)
        case .grey: (0.55, 0.57, 0.62)
        }
    }
    var color: Color { let c = components; return Color(red: c.r, green: c.g, blue: c.b) }
    /// WCAG relative luminance of the colour.
    var luminance: Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let c = components
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    /// Text on this colour is black when white text would fall under 4.5:1 (the WCAG minimum for small text), white otherwise.
    var prefersDarkText: Bool { 1.05 / (luminance + 0.05) < 4.5 }
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

    /// Saves (or with nil, removes) a workspace's gradient theme. The colours are kept inside the readable ranges; a gradient that cannot be made from the colours
    /// given is refused. Choosing a gradient does not touch the workspace's accent swatch: a swatch chosen by hand still wins.
    @discardableResult
    func setWorkspaceGradient(_ name: String, _ gradient: WorkspaceGradient?) -> Bool {
        guard let i = workspaces.firstIndex(where: { $0.name == name }) else { return false }
        var clean: WorkspaceGradient?
        if let gradient {
            guard let valid = gradient.validated() else { notice = "A gradient needs two or three colours."; return false }
            clean = valid
        }
        workspaceGradientMutate(i, clean)
        if name == activeWorkspace { applyWorkspaceTheme() }
        return true
    }

    /// The gradient of the workspace in front, if it has one.
    var activeWorkspaceGradient: WorkspaceGradient? { workspaces.first { $0.name == activeWorkspace }?.gradient }

    /// The accent the interface uses now: the workspace's own swatch if it has one, then its gradient's first colour (made readable in each look), otherwise the
    /// general choice in Settings.
    func applyWorkspaceTheme() {
        let workspace = workspaces.first { $0.name == activeWorkspace }
        let own = workspace?.accent.flatMap(AccentChoice.init(rawValue:))
        Theme.accent = (own ?? accent).color
        // A theme brings its own accent, unless the workspace has one of its own.
        if themeIsActive, own == nil, !accentChosen { Theme.accent = activeTheme.accent.color }
        if own == nil, let gradient = workspace?.gradient, let light = gradient.accent(dark: false), let dark = gradient.accent(dark: true) {
            Theme.accent = Color.workspaceAdaptive(light: light, dark: dark)
        }
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
