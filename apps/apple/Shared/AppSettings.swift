import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TabLayout: String, CaseIterable, Identifiable {
    /// Tab bar under the toolbar.
    case separate
    /// No tab bar; the address bar stands in for the tab strip.
    case compact
    /// Tabs listed in the sidebar.
    case sidebar
    var id: String { rawValue }
    var title: String {
        switch self {
        case .separate: "Separate tab bar"
        case .compact: "Compact"
        case .sidebar: "Tabs in sidebar"
        }
    }
}

enum AddressBarPosition: String, CaseIterable, Identifiable {
    case top, bottom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Buttons the user can show or hide in the toolbar.
enum ToolbarItemID: String, CaseIterable, Identifiable {
    case sidebar, backForward, reload, share, bookmark, newTab, tabOverview, downloads
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sidebar: "Sidebar"
        case .backForward: "Back and forward"
        case .reload: "Reload"
        case .share: "Share"
        case .bookmark: "Bookmark"
        case .newTab: "New tab"
        case .tabOverview: "Tab overview"
        case .downloads: "Downloads"
        }
    }
    var symbol: String {
        switch self {
        case .sidebar: "sidebar.left"
        case .backForward: "chevron.left"
        case .reload: "arrow.clockwise"
        case .share: "square.and.arrow.up"
        case .bookmark: "star"
        case .newTab: "plus"
        case .tabOverview: "square.on.square"
        case .downloads: "arrow.down.circle"
        }
    }
    /// Back/forward/reload, bookmark and downloads sit in the bar; everything else is in the More menu and the keyboard.
    static let defaults: [ToolbarItemID] = {
        #if os(iOS)
        // A phone has no menu bar or keyboard to fall back on, so the tab overview and new tab stay on the toolbar.
        [.sidebar, .backForward, .reload, .share, .bookmark, .newTab, .tabOverview]
        #else
        [.sidebar, .backForward, .reload, .bookmark, .downloads]
        #endif
    }()
}

/// BrowserSetu's own visual identity on top of native controls and materials.
enum Theme {
    /// Deep teal, a nod to the “setu” (bridge) name.
    nonisolated(unsafe) static var accent = Color(red: 0.05, green: 0.50, blue: 0.60)
    static let privateAccent = Color(red: 0.55, green: 0.36, blue: 0.85)
    static let cardRadius: CGFloat = 14
    static let pillRadius: CGFloat = 10

    /// Stable colour per site so letter tiles are recognisable without fetching icons.
    static func tileColor(for text: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.05, green: 0.50, blue: 0.60), Color(red: 0.86, green: 0.38, blue: 0.27),
            Color(red: 0.36, green: 0.45, blue: 0.88), Color(red: 0.30, green: 0.65, blue: 0.40),
            Color(red: 0.80, green: 0.55, blue: 0.15), Color(red: 0.70, green: 0.30, blue: 0.60),
        ]
        let sum = text.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[abs(sum) % palette.count]
    }
}

/// A site's host without a leading `www.`, for compact display.
func displayHost(_ url: URL?) -> String {
    guard let host = url?.host else { return "" }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

func tileLetter(title: String, url: String) -> String {
    let source = displayHost(URL(string: url)).isEmpty ? title : displayHost(URL(string: url))
    return String(source.first ?? "•").uppercased()
}

// MARK: - Double-click on the top bar

enum DoubleClickAction: String, CaseIterable, Identifiable {
    case cycleLayout, zoom
    var id: String { rawValue }
    var title: String { self == .cycleLayout ? "Switch to the next layout" : "Zoom the window" }
}

// MARK: - Layout presets

enum LayoutPreset: String, CaseIterable, Identifiable {
    case classic, sidebar, minimal, floating, inline, custom
    var id: String { rawValue }
    var title: String { self == .inline ? "One Row" : rawValue.capitalized }
    var summary: String {
        switch self {
        case .classic: "Horizontal tabs, standard toolbar"
        case .sidebar: "Vertical tabs; the address bar and navigation live in the sidebar"
        case .minimal: "Compact tabs, no sidebar"
        case .floating: "No top bar. A pill shows the site, a search button opens the address bar, and tabs slide in from the edge"
        case .inline: "Everything on one line: tabs as icons beside the address field"
        case .custom: "Choose each option yourself"
        }
    }
}

enum SidebarPosition: String, CaseIterable, Identifiable {
    case left, right
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum InterfaceDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var rowPadding: CGFloat { self == .compact ? 3 : 6 }
    // The sizes the interface follows. Compact fits noticeably more on screen; Comfortable is roomier.
    var tabRowHeight: CGFloat { self == .compact ? 28 : 36 }
    var smallRowHeight: CGFloat { self == .compact ? 24 : 30 }
    var searchResultHeight: CGFloat { self == .compact ? 34 : 42 }
    var pinnedTileHeight: CGFloat { self == .compact ? 34 : 44 }
    var rowSpacing: CGFloat { self == .compact ? 1 : 3 }
    var stripHeight: CGFloat { self == .compact ? 30 : 38 }
    var stripPillHeight: CGFloat { self == .compact ? 24 : 30 }
    var listRowPadding: CGFloat { self == .compact ? 4 : 9 }
}

struct ResolvedLayout: Equatable {
    var tabLayout: TabLayout
    var sidebarVisible: Bool
    /// Single toolbar: no top bar; the address bar and navigation live in the sidebar. Requires vertical tabs.
    var singleToolbar = false
}

/// Pure layout resolution: presets override the individual options, `custom` uses them as given.
/// Presets change appearance only; they never touch profiles, privacy or data.
func resolveLayout(preset: LayoutPreset, customTabLayout: TabLayout, customSidebarVisible: Bool, customSingleToolbar: Bool = false) -> ResolvedLayout {
    switch preset {
    case .classic: ResolvedLayout(tabLayout: .separate, sidebarVisible: false)
    case .sidebar: ResolvedLayout(tabLayout: .sidebar, sidebarVisible: true, singleToolbar: true)
    case .minimal: ResolvedLayout(tabLayout: .compact, sidebarVisible: false)
    // Tabs are vertical and live in the sidebar, which stays out of sight until the pointer reaches the window's edge.
    case .floating: ResolvedLayout(tabLayout: .sidebar, sidebarVisible: false)
    // Tabs are drawn inside the toolbar itself, so no separate tab row is shown.
    case .inline: ResolvedLayout(tabLayout: .compact, sidebarVisible: false)
    // Without vertical tabs there is nowhere for the address bar to live, so single toolbar implies the sidebar layout.
    case .custom: ResolvedLayout(tabLayout: customSingleToolbar ? .sidebar : customTabLayout, sidebarVisible: customSidebarVisible, singleToolbar: customSingleToolbar)
    }
}

let sidebarWidthRange: ClosedRange<Double> = 190...340
let sidebarRailWidth: Double = 60

func clampedSidebarWidth(_ value: Double) -> Double {
    min(sidebarWidthRange.upperBound, max(sidebarWidthRange.lowerBound, value))
}

/// Subsequence fuzzy match; nil when `query` is not contained. Higher is better.
func fuzzyScore(query: String, in text: String) -> Int? {
    let q = Array(query.lowercased()), t = Array(text.lowercased())
    if q.isEmpty { return 0 }
    var score = 0, ti = 0, previous = -2
    for ch in q {
        var found = false
        while ti < t.count {
            if t[ti] == ch {
                score += 10
                if ti == previous + 1 { score += 15 }            // consecutive run
                if ti == 0 || t[ti - 1] == " " { score += 12 }    // word start
                previous = ti
                ti += 1
                found = true
                break
            }
            ti += 1
        }
        if !found { return nil }
    }
    return score - t.count / 8
}

/// Where the selected tab's address field sits in the One Row toolbar (Mac), so the suggestions open right under it.
struct InlineFieldSpan: Equatable { var x: CGFloat; var width: CGFloat }
