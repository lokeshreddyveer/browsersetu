import Foundation

/// Everything that can sit in the iPhone's bottom toolbar or in its More menu.
enum PhoneAction: String, CaseIterable, Identifiable {
    // Tabs
    case tabs, newTab, newPrivateTab, recentlyClosed, sessions, timeline, closeDuplicates
    // Navigation and page
    case back, forward, reload, share, bookmark, favorites, find, findAllTabs, reader, copyLink, print, savePDF, savePage, screenshot, fullScreenshot
    // Page tools
    case desktopSite, darkPages, javaScript, translate, translatePage, scrollBottom, scrollTop, zoomIn, zoomOut, zoomReset
    // Library and app
    case bookmarks, history, downloads, privacyDashboard, readingList, addReading, pageNote, qrCode, copyCleanLink, highlight, siteStyle, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabs: "Tabs"
        case .newTab: "New Tab"
        case .newPrivateTab: "New Private Tab"
        case .recentlyClosed: "Recently Closed"
        case .sessions: "Saved Sessions"
        case .timeline: "Tab Activity"
        case .closeDuplicates: "Close Duplicate Tabs"
        case .back: "Back"
        case .forward: "Forward"
        case .reload: "Reload"
        case .share: "Share"
        case .bookmark: "Bookmark"
        case .favorites: "Add to Favorites"
        case .find: "Find in Page"
        case .findAllTabs: "Find in All Tabs"
        case .reader: "Reader"
        case .copyLink: "Copy Link"
        case .print: "Print"
        case .savePDF: "Save as PDF"
        case .savePage: "Save Page for Later"
        case .screenshot: "Screenshot"
        case .fullScreenshot: "Full-Page Screenshot"
        case .desktopSite: "Desktop Site"
        case .darkPages: "Dark Page"
        case .javaScript: "JavaScript"
        case .translate: "Translate with Google"
        case .translatePage: "Translate Page"
        case .scrollBottom: "Scroll to Bottom"
        case .scrollTop: "Scroll to Top"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomReset: "Actual Size"
        case .bookmarks: "Bookmarks"
        case .history: "History"
        case .downloads: "Downloads"
        case .privacyDashboard: "Privacy Dashboard"
        case .readingList: "Reading List"
        case .addReading: "Add to Reading List"
        case .pageNote: "Note for This Page"
        case .qrCode: "QR Code for This Page"
        case .copyCleanLink: "Copy Clean Link"
        case .highlight: "Highlight Selection"
        case .siteStyle: "Style for This Site"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .tabs: "square.on.square"
        case .newTab: "plus"
        case .newPrivateTab: "eye.slash"
        case .recentlyClosed: "arrow.uturn.backward"
        case .sessions: "tray.full"
        case .timeline: "clock.arrow.circlepath"
        case .closeDuplicates: "square.on.square.dashed"
        case .back: "chevron.left"
        case .forward: "chevron.right"
        case .reload: "arrow.clockwise"
        case .share: "square.and.arrow.up"
        case .bookmark: "star"
        case .favorites: "heart"
        case .find: "text.magnifyingglass"
        case .findAllTabs: "magnifyingglass"
        case .reader: "doc.plaintext"
        case .copyLink: "link"
        case .print: "printer"
        case .savePDF: "doc.richtext"
        case .savePage: "archivebox"
        case .screenshot: "camera.viewfinder"
        case .fullScreenshot: "rectangle.expand.vertical"
        case .desktopSite: "desktopcomputer"
        case .darkPages: "moon"
        case .javaScript: "curlybraces"
        case .translate: "globe"
        case .translatePage: "character.bubble"
        case .scrollBottom: "arrow.down.to.line"
        case .scrollTop: "arrow.up.to.line"
        case .zoomIn: "plus.magnifyingglass"
        case .zoomOut: "minus.magnifyingglass"
        case .zoomReset: "1.magnifyingglass"
        case .bookmarks: "book"
        case .history: "clock"
        case .downloads: "arrow.down.circle"
        case .privacyDashboard: "hand.raised"
        case .readingList: "books.vertical"
        case .addReading: "text.badge.plus"
        case .pageNote: "note.text"
        case .qrCode: "qrcode"
        case .copyCleanLink: "link.badge.plus"
        case .highlight: "highlighter"
        case .siteStyle: "paintbrush"
        case .settings: "gearshape"
        }
    }

    /// How the More menu groups it.
    var section: PhoneMenuSection {
        switch self {
        case .tabs, .newTab, .newPrivateTab, .recentlyClosed, .sessions, .timeline, .closeDuplicates: .tabs
        case .back, .forward, .reload, .share, .bookmark, .favorites, .find, .findAllTabs, .reader, .copyLink, .copyCleanLink, .addReading, .pageNote, .qrCode, .highlight, .print, .savePDF, .savePage, .screenshot, .fullScreenshot: .page
        case .desktopSite, .darkPages, .javaScript, .translate, .translatePage, .siteStyle, .scrollBottom, .scrollTop, .zoomIn, .zoomOut, .zoomReset: .tools
        case .bookmarks, .history, .downloads, .privacyDashboard, .readingList: .library
        case .settings: .app
        }
    }

    /// An action that is switched on or off rather than run once.
    var isToggle: Bool { [.desktopSite, .darkPages, .javaScript, .bookmark].contains(self) }

    /// Settings can never be removed from both places: without it the layout could not be changed back.
    var canBeHidden: Bool { self != .settings }
}

enum PhoneMenuSection: Int, CaseIterable, Identifiable {
    case tabs, page, tools, library, app
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .tabs: "Tabs"
        case .page: "This Page"
        case .tools: "Page Tools"
        case .library: "Library"
        case .app: "Browser"
        }
    }
}

/// Which actions are in the bottom toolbar (and in what order, with the address pill somewhere among them), which are in the More
/// menu, and which are hidden. Always consistent: every action is in exactly one place, the address pill is there once, the toolbar
/// holds at most `maxActions` actions, and Settings can always be reached.
struct PhoneToolbarLayout: Equatable {
    enum Slot: Hashable { case address, action(PhoneAction) }

    static let maxActions = 4
    private(set) var slots: [Slot]
    private(set) var more: [PhoneAction]
    private(set) var hidden: [PhoneAction]

    static let standard = PhoneToolbarLayout(slots: [.action(.back), .action(.forward), .address, .action(.tabs)], more: [.scrollTop, .scrollBottom], hidden: [])

    /// Repairs whatever it is given: the saved text may be old, edited or damaged.
    init(slots: [Slot], more: [PhoneAction], hidden: [PhoneAction]) {
        var seen = Set<PhoneAction>()
        var cleanSlots: [Slot] = []
        var sawAddress = false
        var actionCount = 0
        var overflow: [PhoneAction] = []
        for slot in slots {
            switch slot {
            case .address:
                if !sawAddress { cleanSlots.append(.address); sawAddress = true }
            case .action(let action):
                guard seen.insert(action).inserted else { continue }
                if actionCount < Self.maxActions { cleanSlots.append(.action(action)); actionCount += 1 } else { overflow.append(action) }
            }
        }
        if !sawAddress {
            let after = cleanSlots.firstIndex(of: .action(.forward)).map { $0 + 1 } ?? min(1, cleanSlots.count)
            cleanSlots.insert(.address, at: after)
        }
        // Buttons that did not fit in the toolbar go to the top of the More menu (they were already counted as seen above).
        var cleanMore: [PhoneAction] = overflow
        for action in more where seen.insert(action).inserted { cleanMore.append(action) }
        var cleanHidden: [PhoneAction] = []
        for action in hidden where action.canBeHidden && seen.insert(action).inserted { cleanHidden.append(action) }
        for action in PhoneAction.allCases where seen.insert(action).inserted { cleanMore.append(action) }
        self.slots = cleanSlots; self.more = cleanMore; self.hidden = cleanHidden
    }

    var toolbarActions: [PhoneAction] { slots.compactMap { if case .action(let a) = $0 { a } else { nil } } }
    private var addressIndex: Int { slots.firstIndex(of: .address) ?? 0 }
    var beforeAddress: [PhoneAction] { slots[..<addressIndex].compactMap { if case .action(let a) = $0 { a } else { nil } } }
    var afterAddress: [PhoneAction] { slots[(addressIndex + 1)...].compactMap { if case .action(let a) = $0 { a } else { nil } } }
    var toolbarIsFull: Bool { toolbarActions.count >= Self.maxActions }

    func location(of action: PhoneAction) -> Place {
        if toolbarActions.contains(action) { return .toolbar }
        if hidden.contains(action) { return .hidden }
        return .more
    }
    enum Place { case toolbar, more, hidden }

    // MARK: Changes. Each returns a repaired layout.

    func moving(_ action: PhoneAction, to place: Place) -> PhoneToolbarLayout {
        var s = slots.filter { $0 != .action(action) }
        var m = more.filter { $0 != action }
        var h = hidden.filter { $0 != action }
        switch place {
        case .toolbar:
            guard s.compactMap({ $0 }).count - 1 < Self.maxActions else { return self }
            s.append(.action(action))
        case .more: m.append(action)
        case .hidden: if action.canBeHidden { h.append(action) } else { m.append(action) }
        }
        return PhoneToolbarLayout(slots: s, more: m, hidden: h)
    }

    func movingSlots(from: IndexSet, to: Int) -> PhoneToolbarLayout {
        var s = slots
        s.move(fromOffsets: from, toOffset: to)
        return PhoneToolbarLayout(slots: s, more: more, hidden: hidden)
    }

    func movingMore(from: IndexSet, to: Int) -> PhoneToolbarLayout {
        var m = more
        m.move(fromOffsets: from, toOffset: to)
        return PhoneToolbarLayout(slots: slots, more: m, hidden: hidden)
    }

    // MARK: Saving

    var stored: String {
        let object: [String: [String]] = [
            "toolbar": slots.map { if case .action(let a) = $0 { a.rawValue } else { "address" } },
            "more": more.map(\.rawValue), "hidden": hidden.map(\.rawValue),
        ]
        return (try? String(data: JSONEncoder().encode(object), encoding: .utf8)) ?? ""
    }

    init(stored: String?) {
        guard let data = stored?.data(using: .utf8), let object = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            self = .standard; return
        }
        func actions(_ key: String) -> [PhoneAction] { (object[key] ?? []).compactMap(PhoneAction.init(rawValue:)) }
        let slots: [Slot] = (object["toolbar"] ?? []).compactMap { $0 == "address" ? Slot.address : PhoneAction(rawValue: $0).map(Slot.action) }
        self.init(slots: slots.isEmpty ? Self.standard.slots : slots, more: actions("more"), hidden: actions("hidden"))
    }

    /// The More menu's contents, grouped as the menu shows them, in the user's order inside each group.
    var moreSections: [(section: PhoneMenuSection, actions: [PhoneAction])] {
        PhoneMenuSection.allCases.compactMap { section in
            let items = more.filter { $0.section == section }
            return items.isEmpty ? nil : (section, items)
        }
    }
}

/// What the address pill shows.
enum AddressDisplay: String, CaseIterable, Identifiable {
    case domain, title, titleAndDomain
    var id: String { rawValue }
    var title: String {
        switch self {
        case .domain: "Website name"
        case .title: "Page title"
        case .titleAndDomain: "Title and website"
        }
    }
}

enum OverviewStyle: String, CaseIterable, Identifiable {
    case grid, list
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

enum OverviewSort: String, CaseIterable, Identifiable {
    case manual, recent, title, website
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "Manual order"
        case .recent: "Most recently used"
        case .title: "Title"
        case .website: "Website"
        }
    }
}

/// When pages are shown dark.
enum DarkPages: String, CaseIterable, Identifiable {
    case off, chosen, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "Off"
        case .chosen: "Only sites I choose"
        case .always: "Every light page"
        }
    }
}
