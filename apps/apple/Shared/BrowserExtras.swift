import SwiftUI

// Break mode, page actions, address bar sources, a theme schedule, command chains, web panels and editable menus.
// The settings for each are in BrowserExtrasSettings.swift; none of this touches how a page loads or plays.

// MARK: - Address bar sources

enum AddressSource: String, CaseIterable, Identifiable {
    case suggestions, tabs, bookmarks, history, pages, commands
    var id: String { rawValue }
    static let defaults: [AddressSource] = [.suggestions, .tabs, .bookmarks, .history, .pages, .commands]

    var title: String {
        switch self {
        case .suggestions: "Search suggestions"
        case .tabs: "Open tabs"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .pages: "Words inside saved pages"
        case .commands: "Commands"
        }
    }

    var symbol: String {
        switch self {
        case .suggestions: "magnifyingglass"
        case .tabs: "square.on.square"
        case .bookmarks: "book"
        case .history: "clock"
        case .pages: "doc.text.magnifyingglass"
        case .commands: "command"
        }
    }

    static func source(of kind: Suggestion.Kind) -> AddressSource? {
        switch kind {
        case .suggestion: .suggestions
        case .openTab: .tabs
        case .bookmark: .bookmarks
        case .history: .history
        case .page: .pages
        case .command: .commands
        case .go, .search: nil
        }
    }

    /// The first rows ("Go to…", "Search for…", an answer to a sum) stay on top; the rest follow the order chosen, and sources that are off are left out.
    static func arrange(_ list: [Suggestion], order: [AddressSource]) -> [Suggestion] {
        func isLead(_ s: Suggestion) -> Bool { s.kind == .go || s.kind == .search || s.target.hasPrefix("quick-answer-") }
        let lead = list.filter(isLead)
        var ranked: [(rank: Int, index: Int, item: Suggestion)] = []
        for (index, s) in list.enumerated() where !isLead(s) {
            if let source = source(of: s.kind), let rank = order.firstIndex(of: source) { ranked.append((rank, index, s)) }
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return lead + ranked.map(\.item)
    }
}

// MARK: - Page actions

enum PageAction: String, CaseIterable, Identifiable {
    case grayscale, invert, sepia, highContrast, noImages, noAnimations
    var id: String { rawValue }

    var title: String {
        switch self {
        case .grayscale: "Grayscale"
        case .invert: "Invert Colours"
        case .sepia: "Warm Paper"
        case .highContrast: "High Contrast"
        case .noImages: "Hide Images"
        case .noAnimations: "Stop Animations"
        }
    }

    var symbol: String {
        switch self {
        case .grayscale: "circle.lefthalf.filled"
        case .invert: "circle.righthalf.filled.inverse"
        case .sepia: "doc.richtext"
        case .highContrast: "circle.dotted.circle"
        case .noImages: "photo.slash"
        case .noAnimations: "pause.rectangle"
        }
    }

    /// The style sheet for the actions in use. Filters are combined into one so two of them work together.
    static func css(for actions: Set<PageAction>) -> String? {
        guard !actions.isEmpty else { return nil }
        var filters: [String] = []
        if actions.contains(.grayscale) { filters.append("grayscale(1)") }
        if actions.contains(.sepia) { filters.append("sepia(0.8)") }
        if actions.contains(.highContrast) { filters.append("contrast(1.45)") }
        if actions.contains(.invert) { filters.append("invert(1) hue-rotate(180deg)") }
        var css = ""
        if !filters.isEmpty { css += "html { filter: \(filters.joined(separator: " ")) !important; }\n" }
        if actions.contains(.invert) { css += "img, picture, video, canvas { filter: invert(1) hue-rotate(180deg) !important; }\n" }
        if actions.contains(.noImages) { css += "img, picture, video, canvas { visibility: hidden !important; }\n" }
        if actions.contains(.noAnimations) { css += "*, *::before, *::after { animation: none !important; transition: none !important; scroll-behavior: auto !important; }\n" }
        return css
    }
}

enum PowerScripts {
    /// Pauses every playing video and sound on the page, remembering which were playing.
    static let pause = "document.querySelectorAll('video, audio').forEach(m => { if (!m.paused) { m.dataset.bsBreak = '1'; m.pause(); } }); return true;"
    /// Plays again only what break mode paused.
    static let resume = "document.querySelectorAll('[data-bs-break]').forEach(m => { delete m.dataset.bsBreak; const p = m.play(); if (p && p.catch) p.catch(() => {}); }); return true;"
    /// Puts the style for the page actions in (or takes it out when `css` is null). The text is passed as data, never joined into the script.
    static let pageActions = "const old = document.getElementById('bs-page-actions'); if (old) old.remove(); if (css) { const s = document.createElement('style'); s.id = 'bs-page-actions'; s.textContent = css; document.documentElement.appendChild(s); } return true;"
}

// MARK: - Theme schedule, command chains, web panels

struct ThemeSchedule: Codable, Equatable {
    var enabled = false
    var dayTheme = ""
    var nightTheme = "midnight"
    /// Minutes after midnight.
    var dayStart = 7 * 60
    var nightStart = 19 * 60

    func themeID(atMinute minute: Int) -> String {
        let isDay = dayStart < nightStart ? (minute >= dayStart && minute < nightStart) : (minute >= dayStart || minute < nightStart)
        return isDay ? dayTheme : nightTheme
    }
}

struct CommandChain: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var steps: [String]
}

struct WebPanel: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var url: String
}

/// The items of the right-click menus that can be switched off in Settings.
enum MenuItemID: String, CaseIterable, Identifiable {
    case newTab, newPrivateTab, searchTabs, newGroup, newWorkspace, sidebarSections, sidebarPosition, collapse, autoHide, hideSidebar
    case layout, density, toolbarButtons, reopenClosed, breakMode, pageActions, customize
    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .newPrivateTab: "New Private Tab"
        case .searchTabs: "Search Tabs"
        case .newGroup: "New Tab Group"
        case .newWorkspace: "New Workspace"
        case .sidebarSections: "Show in Sidebar"
        case .sidebarPosition: "Sidebar Position"
        case .collapse: "Collapse to Icons"
        case .autoHide: "Hide Until Pointer Reaches the Edge"
        case .hideSidebar: "Hide Sidebar"
        case .layout: "Layout"
        case .density: "Density"
        case .toolbarButtons: "Toolbar Buttons"
        case .reopenClosed: "Reopen Closed Tab"
        case .breakMode: "Break Mode"
        case .pageActions: "Page Actions"
        case .customize: "Customize…"
        }
    }
}

extension BrowserModel {
    func showsMenuItem(_ item: MenuItemID) -> Bool { !hiddenMenuItems.contains(item.rawValue) }

    func saveJSON<T: Encodable>(_ key: String, _ value: T) {
        if let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) { saveSetting(key, text) }
    }

    static func loadJSON<T: Decodable>(_ text: String?, as type: T.Type) -> T? {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    func loadExtraSettings(_ get: (String) -> String?) {
        if let list = get("address_sources") { addressSources = list.split(separator: ",").compactMap { AddressSource(rawValue: String($0)) } }
        hoverPreviews = get("hover_previews") != "0"
        hoverDelay = Double(get("hover_delay") ?? "") ?? 0.6
        themeSchedule = Self.loadJSON(get("theme_schedule"), as: ThemeSchedule.self) ?? ThemeSchedule()
        chains = Self.loadJSON(get("command_chains"), as: [CommandChain].self) ?? []
        webPanels = Self.loadJSON(get("web_panels"), as: [WebPanel].self) ?? []
        hiddenMenuItems = Set((get("hidden_menu_items") ?? "").split(separator: ",").map(String.init))
        tabStacks = get("tab_stacks") == "1"
        blockPopups = get("block_popups") != "0"
        if let list = get("address_bar_items") { addressBarItems = list.split(separator: ",").compactMap { AddressBarItem(rawValue: String($0)) } }
        if let list = get("sidebar_footer") { sidebarFooter = list.split(separator: ",").compactMap { SidebarFooterItem(rawValue: String($0)) } }
        WebLoginVault.synchronizable = get("passwords_icloud_keychain") == "1"
        passwordsInICloudKeychain = WebLoginVault.synchronizable
        // A new install is asked a few questions once. Not in a window made later, in a test run, or when the window is set up by hand for a screenshot.
        let scripted = UserDefaults.standard.string(forKey: "UIState") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // `-BrowserSetuShowSetup YES` on the command line shows the questions once more without touching anything saved.
        let forced = UserDefaults.standard.bool(forKey: "BrowserSetuShowSetup")
        showSetup = !isSecondary && !scripted && (forced || get("setup_done") != "1")
        popupAllowedHosts = Set((get("popup_allowed_hosts") ?? "").split(separator: ",").map(String.init))
        startThemeSchedule()
    }

    // MARK: Break mode

    /// One button: pauses media in every tab; pressed again, resumes only what it paused.
    func toggleBreakMode() {
        breakActive.toggle()
        let script = breakActive ? PowerScripts.pause : PowerScripts.resume
        for tab in tabs { tab.engine.runPageScript(script, arguments: [:]) }
        notice = breakActive ? "Break: everything is paused." : "Back from the break."
    }

    // MARK: Page actions

    func togglePageAction(_ action: PageAction, on tab: TabController? = nil) {
        guard let tab = tab ?? active else { return }
        if tab.pageActions.contains(action) { tab.pageActions.remove(action) } else { tab.pageActions.insert(action) }
        tab.applyPageActions()
    }

    func clearPageActions(on tab: TabController? = nil) {
        guard let tab = tab ?? active else { return }
        tab.pageActions = []
        tab.applyPageActions()
    }

    // MARK: Theme schedule

    func applyThemeSchedule() {
        guard themeSchedule.enabled else { return }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let wanted = themeSchedule.themeID(atMinute: (parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        guard !wanted.isEmpty, wanted != themeID, allThemes.contains(where: { $0.id == wanted }) else { return }
        animated(.easeInOut(duration: 0.5)) { themeID = wanted }
    }

    func startThemeSchedule() {
        themeTimer?.invalidate()
        themeTimer = nil
        guard themeSchedule.enabled else { return }
        applyThemeSchedule()
        themeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.applyThemeSchedule() }
        }
    }

    // MARK: Command chains

    /// The commands a chain may use: every fixed palette command, not other chains or the ones that depend on what is typed.
    var chainableCommands: [PaletteItem] {
        allPaletteItems().filter { item in
            let skip = ["chain-", "tab-", "bm-", "hist-", "read-", "search-selection-", "window-size-"]
            return !skip.contains { item.id.hasPrefix($0) }
        }
    }

    func run(chain: CommandChain) {
        let available = Dictionary(chainableCommands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        Task { @MainActor in
            for step in chain.steps.prefix(20) {
                available[step]?.run()
                // A moment between steps, so one finishes (a tab opening, a panel appearing) before the next starts.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Chains, break mode, page actions and web panels, as palette commands.
    var extraPaletteItems: [PaletteItem] {
        var items: [PaletteItem] = chains.filter { !$0.steps.isEmpty }.map { chain in
            PaletteItem(id: "chain-\(chain.id)", title: chain.name, subtitle: "Command chain · \(chain.steps.count) step\(chain.steps.count == 1 ? "" : "s")", symbol: "link", shortcut: "") { [self] in run(chain: chain) }
        }
        items.append(.init(id: "run-setup", title: "Run Setup Again", subtitle: "The first-run questions: look, layout, search, protection, passwords", symbol: "wand.and.stars", shortcut: "") { [self] in animated { showSetup = true } })
        items.append(.init(id: "break-mode", title: breakActive ? "End Break (Resume Media)" : "Break: Pause All Media", subtitle: "Pauses video and sound in every tab", symbol: "pause.circle", shortcut: "") { [self] in toggleBreakMode() })
        items.append(.init(id: "page-actions-clear", title: "Page Actions: Reset This Page", subtitle: "", symbol: "arrow.uturn.backward", shortcut: "") { [self] in clearPageActions() })
        for action in PageAction.allCases {
            items.append(.init(id: "page-action-\(action.rawValue)", title: "Page Action: \(action.title)", subtitle: "On this page", symbol: action.symbol, shortcut: "") { [self] in togglePageAction(action) })
        }
        if let tab = active, let host = tab.url?.host?.lowercased(), !tab.isBlank {
            let allowed = popupAllowedHosts.contains(host)
            items.append(.init(id: "popups-site", title: allowed ? "Stop Allowing Pop-ups for \(host)" : "Allow Pop-ups for \(host)", subtitle: "", symbol: "rectangle.on.rectangle", shortcut: "") { [self] in
                if allowed { popupAllowedHosts.remove(host) } else { popupAllowedHosts.insert(host) }
                notice = allowed ? "Pop-ups blocked again for \(host)." : "Pop-ups allowed for \(host)."
            })
        }
        for panel in webPanels {
            items.append(.init(id: "web-panel-\(panel.id)", title: "Web Panel: \(panel.name)", subtitle: panel.url, symbol: "sidebar.squares.left", shortcut: "") { [self] in toggleWebPanel(panel.id) })
        }
        return items
    }

    /// Opens a web panel beside the page, or closes it. A panel is a tab that is kept out of every tab list, so it has the browser's own protections.
    func toggleWebPanel(_ id: String) {
        let wasOpen = openPanelID == id
        if let old = panelTabID { closeTab(id: old, force: true); panelTabID = nil }
        if wasOpen { animated(.easeOut(duration: 0.22)) { openPanelID = nil }; return }
        guard let panel = webPanels.first(where: { $0.id == id }), let url = URL(string: panel.url), url.scheme == "https" else { return }
        let tab = openTab(url: url, isPrivate: false, select: false)
        panelTabID = tab.id
        animated(.easeOut(duration: 0.22)) { openPanelID = id }
    }

    /// The panel's page moves into the tab list as an ordinary tab.
    func moveWebPanelToTab() {
        guard let id = panelTabID else { return }
        panelTabID = nil
        animated(.easeOut(duration: 0.22)) { openPanelID = nil }
        select(id)
    }

    // MARK: Tab stacks

    func stackKey(_ tab: TabController) -> String? {
        guard tabStacks, !tab.pinned, !tab.isBlank, !tab.isSettingsPage, let host = tab.url?.host else { return nil }
        return TabOrganizing.siteName(forHost: host)
    }

    /// With stacks on, tabs of one website sit together; a folded stack shows only its first tab.
    func stackedVisible(_ list: [TabController]) -> [TabController] {
        guard tabStacks else { return list }
        var counts: [String: Int] = [:]
        for tab in list { if let key = stackKey(tab) { counts[key, default: 0] += 1 } }
        var placed = Set<String>(), out: [TabController] = []
        for tab in list {
            guard let key = stackKey(tab), (counts[key] ?? 0) >= 2 else { out.append(tab); continue }
            guard placed.insert(key).inserted else { continue }
            let members = list.filter { stackKey($0) == key }
            out.append(contentsOf: collapsedStacks.contains(key) ? [members[0]] : members)
        }
        return out
    }

    /// For the first tab of a stack of two or more: how many it holds and whether it is folded.
    func stackHead(_ tab: TabController) -> (key: String, count: Int, folded: Bool)? {
        guard let key = stackKey(tab) else { return nil }
        let members = visibleTabs.filter { stackKey($0) == key }
        guard members.count >= 2, members.first?.id == tab.id else { return nil }
        return (key, members.count, collapsedStacks.contains(key))
    }

    func toggleStack(_ key: String) {
        if collapsedStacks.contains(key) { collapsedStacks.remove(key) } else { collapsedStacks.insert(key) }
    }
}

// MARK: - Pop-ups

extension BrowserModel {
    func popupsAllowed(forHost host: String?) -> Bool {
        !blockPopups || (host.map { popupAllowedHosts.contains($0.lowercased()) } ?? false)
    }

    /// Lets this tab's site open windows without a click from now on, and opens the one that was just blocked.
    func allowPopups(in tab: TabController) {
        guard let host = tab.url?.host?.lowercased() else { return }
        popupAllowedHosts.insert(host)
        if let blocked = tab.blockedPopup, blocked.scheme == "http" || blocked.scheme == "https" { openTab(url: blocked, isPrivate: tab.isPrivate, opener: tab) }
        tab.blockedPopup = nil
        notice = "Pop-ups allowed for \(host)."
    }

    /// A window opened by a page's script (a sign-in, a payment, a share box): a tab joined to the page that opened it, so the two can talk.
    func openPopupTab(configuration: AnyObject, opener: TabController) -> TabController {
        let isPrivate = opener.isPrivate
        let info = core.createTab(url: "about:blank", private: isPrivate)
        var meta = TabMeta()
        if !isPrivate { meta.container = tabMeta[opener.id]?.container; meta.scratch = tabMeta[opener.id]?.scratch; meta.parent = opener.id }
        if !meta.isEmpty { tabMeta[info.id] = meta; saveTabMeta() }
        let tab = TabController(info: info, model: self, popupConfiguration: configuration)
        if !activeWorkspace.isEmpty { try? core.setTabWorkspace(tabId: tab.id, workspace: activeWorkspace); tab.workspace = activeWorkspace }
        if !activeGroup.isEmpty, !isPrivate { try? core.setTabGroup(tabId: tab.id, group: activeGroup); tab.group = activeGroup }
        tabs.append(tab)
        placeAfterOpener(tab)
        if !isPrivate { extensionCenter.tabOpened(tab) }
        select(tab.id)
        saveSoon()
        return tab
    }
}

/// Shown over the page when it tried to open a window without a click: open it once, allow the site for good, or let it go.
struct PopupBlockedPill: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            if let tab = model.active, let blocked = tab.blockedPopup {
                PopupBlockedCard(tab: tab, blocked: blocked)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: model.active?.blockedPopup)
    }
}

private struct PopupBlockedCard: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let blocked: URL
    private var host: String { tab.url?.host ?? "this page" }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.slash").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Pop-up blocked").font(.system(size: 13, weight: .semibold))
                Text(host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if blocked.scheme == "http" || blocked.scheme == "https" {
                Button("Open Once") { model.openTab(url: blocked, isPrivate: tab.isPrivate, opener: tab); tab.blockedPopup = nil }
            }
            Button("Always Allow") { model.allowPopups(in: tab) }.tint(Theme.accent)
            Button { tab.blockedPopup = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .themedFill(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .frame(maxWidth: 440)
        .padding(.horizontal, 12)
    }
}

/// Settings: whether pop-ups are blocked, and the sites that may open them anyway.
struct PopupSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Block pop-ups that open without a click", isOn: $model.blockPopups)
            if model.blockPopups {
                if model.popupAllowedHosts.isEmpty { Text("No sites are allowed to open pop-ups on their own.").foregroundStyle(.secondary) }
                ShowMoreRows(model.popupAllowedHosts.sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button("Remove", role: .destructive) { model.popupAllowedHosts.remove(host) }.buttonStyle(.borderless)
                    }
                }
            }
        } header: {
            Text("Pop-ups")
        } footer: {
            Text("Windows opened by a click or a key press are always allowed: sign-in and payment windows work as usual, and they stay connected to the page that opened them. A page that tries on its own is stopped, and you can allow it from the notice.")
        }
    }
}

// MARK: - Saving a typed password from the page

extension BrowserModel {
    /// Keeps what was typed, on the person's own click. Updates the password if that name is already kept for the site.
    func saveTypedLogin(in tab: TabController) {
        guard let pending = tab.typedLogin, !tab.isPrivate else { return }
        let kept = WebLoginVault.list(origin: pending.origin, profile: profileName)
        let updating = kept.contains { $0.user == pending.user }
        if WebLoginVault.save(WebLogin(origin: pending.origin, user: pending.user, password: pending.password), profile: profileName) {
            notice = updating ? "Password updated." : "Password saved."
        } else {
            notice = "The password could not be saved."
        }
        tab.typedLogin = nil
    }
}

/// "Save password?" over the page, as soon as a password has been typed: one click keeps it in the Keychain on this device.
struct PendingLoginPill: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            if let tab = model.active, !tab.isPrivate, let pending = tab.typedLogin {
                PendingLoginCard(tab: tab, pending: pending)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: model.active?.typedLogin)
    }
}

private struct PendingLoginCard: View {
    @EnvironmentObject var model: BrowserModel
    @ObservedObject var tab: TabController
    let pending: PendingLogin
    private var updating: Bool { WebLoginVault.list(origin: pending.origin, profile: model.profileName).contains { $0.user == pending.user } }
    private var host: String { URL(string: pending.origin)?.host ?? pending.origin }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(updating ? "Update password for \(pending.user)?" : "Save password for \(pending.user)?").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(host) · kept in your Keychain on this device").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(updating ? "Update" : "Save") { model.saveTypedLogin(in: tab) }.tint(Theme.accent)
            Button("Never") { model.neverSaveLogins(for: pending.origin); tab.typedLogin = nil }
            Button { tab.typedLogin = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
        }
        .buttonStyle(.bordered).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .themedFill(in: RoundedRectangle(cornerRadius: 14, style: .continuous), fallback: .regularMaterial)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .frame(maxWidth: 480)
        .padding(.horizontal, 12)
    }
}

// MARK: - Passwords in iCloud Keychain, and in a backup

extension BrowserModel {
    /// Moves the kept passwords into iCloud Keychain, or back onto this device only. If this copy of the app cannot use iCloud Keychain, nothing changes and it says so.
    func setPasswordsInICloudKeychain(_ on: Bool) async {
        guard on != passwordsInICloudKeychain, await requireAuthentication("Change where your saved passwords are kept") else { return }
        WebLoginVault.synchronizable = on
        let result = WebLoginVault.migrate(profile: profileName, toCloud: on)
        if on, result.total > 0, result.synced == 0 {
            // Put everything back as it was: nothing could be moved.
            WebLoginVault.synchronizable = false
            _ = WebLoginVault.migrate(profile: profileName, toCloud: false)
            notice = "iCloud Keychain is not available to this copy of Browser Setu, so your passwords stay on this device. Check that you are signed in to iCloud with Passwords & Keychain on."
            return
        }
        passwordsInICloudKeychain = on
        notice = on ? (result.total == 0 ? "New passwords will be kept in iCloud Keychain." : "\(result.synced) of \(result.total) passwords are now in iCloud Keychain.")
                    : "Your passwords now stay on this device."
    }

    /// Adds the passwords from a backup. A password already kept for the same site and name is left alone unless it differs.
    func restorePasswords(_ logins: [WebLogin]) -> Int {
        var count = 0
        let kept = WebLoginVault.list(profile: profileName)
        for login in logins.prefix(5_000) {
            guard WebLoginOrigin.normalized(login.origin) == login.origin, !login.user.isEmpty, !login.password.isEmpty,
                  login.user.count <= LoginRules.maxUser, login.password.count <= LoginRules.maxPassword else { continue }
            if kept.contains(where: { $0.id == login.id && $0.password == login.password }) { continue }
            if WebLoginVault.save(login, profile: profileName) { count += 1 }
        }
        return count
    }
}

// MARK: - Short messages

/// The browser's short messages ("Filled in.", "Password saved.") as a card that leaves by itself, instead of a box that has to be clicked away.
/// It stays longer when the message is long, and a tap puts it away at once.
struct NoticeToast: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            if let text = model.notice {
                HStack(spacing: 10) {
                    Image(systemName: icon(for: text)).foregroundStyle(Theme.accent)
                    Text(text).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .themedFill(in: RoundedRectangle(cornerRadius: 16, style: .continuous), fallback: .regularMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
                .onTapGesture { model.notice = nil }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
                .task(id: text) {
                    AccessibilityNotification.Announcement(text).post()
                    // Long messages stay longer; a failure stays longest.
                    let seconds = min(9.0, max(3.0, Double(text.count) / 14.0 + (isProblem(text) ? 2 : 0)))
                    try? await Task.sleep(for: .seconds(seconds))
                    if model.notice == text { model.notice = nil }
                }
            }
        }
        .motion(.spring(response: 0.34, dampingFraction: 0.86), value: model.notice)
    }

    private func isProblem(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["could not", "cannot", "not available", "failed", "refused", "blocked"].contains { lowered.contains($0) }
    }

    private func icon(for text: String) -> String { isProblem(text) ? "exclamationmark.circle" : "checkmark.circle" }
}

// MARK: - The buttons along the foot of the sidebar

enum SidebarFooterItem: String, CaseIterable, Identifiable {
    case history, downloads, bookmarks, bookmarkThis, readingList, extensions, newTab, privateTab, tabOverview, find, palette, breakMode, splitView, timeline, sessions, dashboard, settings, profile
    var id: String { rawValue }

    /// What a new install shows: the same five as before, with the star and the extensions button only when they mean something.
    static let defaults: [SidebarFooterItem] = [.history, .downloads, .bookmarks, .bookmarkThis, .extensions, .settings, .profile]

    var title: String {
        switch self {
        case .history: "History"
        case .downloads: "Downloads"
        case .bookmarks: "Bookmarks"
        case .bookmarkThis: "Save This Page"
        case .readingList: "Reading List"
        case .extensions: "Extensions"
        case .newTab: "New Tab"
        case .privateTab: "New Private Tab"
        case .tabOverview: "Tab Overview"
        case .find: "Find on Page"
        case .palette: "Command Palette"
        case .breakMode: "Break (Pause All Media)"
        case .splitView: "Split View"
        case .timeline: "Timeline"
        case .sessions: "Saved Sessions"
        case .dashboard: "Privacy Dashboard"
        case .settings: "Settings"
        case .profile: "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .bookmarks: "bookmark"
        case .bookmarkThis: "star"
        case .readingList: "books.vertical"
        case .extensions: "puzzlepiece.extension"
        case .newTab: "plus"
        case .privateTab: "eye.slash"
        case .tabOverview: "square.on.square"
        case .find: "magnifyingglass"
        case .palette: "command"
        case .breakMode: "pause.circle"
        case .splitView: "rectangle.split.2x1"
        case .timeline: "calendar.day.timeline.left"
        case .sessions: "rectangle.stack"
        case .dashboard: "checkmark.shield"
        case .settings: "gearshape"
        case .profile: "person.crop.circle"
        }
    }
}

// MARK: - The buttons inside the address bar (Mac)

enum AddressBarItem: String, CaseIterable, Identifiable {
    case siteInfo, certificateName, shield, bookmarkStar, share, copyLink, pageActions, reload
    var id: String { rawValue }

    /// What a new install shows: the lock, the site's checked name, the shield and reload, as before.
    static let defaults: [AddressBarItem] = [.siteInfo, .certificateName, .shield, .reload]

    var title: String {
        switch self {
        case .siteInfo: "Lock and site information"
        case .certificateName: "Checked name of the site"
        case .shield: "Protection shield"
        case .bookmarkStar: "Bookmark star"
        case .share: "Share"
        case .copyLink: "Copy link"
        case .pageActions: "Page actions"
        case .reload: "Reload and stop"
        }
    }

    var symbol: String {
        switch self {
        case .siteInfo: "lock"
        case .certificateName: "checkmark.seal"
        case .shield: "shield.lefthalf.filled"
        case .bookmarkStar: "star"
        case .share: "square.and.arrow.up"
        case .copyLink: "link"
        case .pageActions: "wand.and.stars"
        case .reload: "arrow.clockwise"
        }
    }
}
