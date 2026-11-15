import Foundation

// MARK: - What a favorite is, and where it lives
//
// A favorite is a bookmark in the folder "Favorites" (loose on the start page) or in "Favorites/<name>" (inside one of the person's folders on the start page).
// There is no second store: the bookmark list is the one source of truth for the address, the title and the folder, so the bookmark manager and the start page always agree.
// What is kept besides it (all per profile, in the profile's own settings): the order (`favorites_order`), the names of the folders (`favorites_folders`, so an empty folder
// survives), and the look (`fav_style`, `fav_labels`, `fav_folders_shown`). Frequently visited sites are never stored: they are computed from history each time the page opens.

/// How the favorites tiles look. Classic is the quiet default.
enum FavoriteStyle: String, CaseIterable, Identifiable {
    case classic, glass, compact
    var id: String { rawValue }
    var title: String { switch self { case .classic: "Classic"; case .glass: "Glass"; case .compact: "Compact" } }
    var summary: String {
        switch self {
        case .classic: "Plain icon tiles"
        case .glass: "Soft translucent tiles"
        case .compact: "Smaller tiles, tighter spacing"
        }
    }
    /// Compact tiles are drawn a little smaller than the size chosen in Customize.
    var scale: CGFloat { self == .compact ? 0.82 : 1 }
}

/// A folder of favorites, as the start page shows it.
struct FavoriteFolder: Identifiable, Equatable {
    let name: String
    let items: [BookmarkItem]
    var id: String { FavoriteToken.folder(name) }
}

/// One thing in the favorites row: a favorite, or a folder of them.
enum FavoriteEntry: Identifiable, Equatable {
    case item(BookmarkItem)
    case folder(FavoriteFolder)
    var id: String {
        switch self {
        case .item(let item): item.url
        case .folder(let folder): folder.id
        }
    }
}

/// The entries of the saved order. An address is a favorite; "folder:Name" is a folder. (Orders saved before folders existed hold only addresses, and still read the same way.)
enum FavoriteToken {
    static let folderPrefix = "folder:"
    static func folder(_ name: String) -> String { folderPrefix + name }
    static func folderName(_ token: String) -> String? { token.hasPrefix(folderPrefix) ? String(token.dropFirst(folderPrefix.count)) : nil }
}

/// One key for addresses that mean the same page, so a page is one favorite however it was typed: the scheme and host in lower case, no "www.", no default port, no
/// fragment, no trailing slash.
enum FavoriteURL {
    static func key(_ address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: text) else { return text.lowercased() }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if let host = parts.host, host.hasPrefix("www.") { parts.host = String(host.dropFirst(4)) }
        parts.fragment = nil
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        var path = parts.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path == "/" { path = "" }
        parts.path = path
        return parts.string ?? text.lowercased()
    }

    /// A folder name the person typed, made safe to keep: trimmed, no slash (the bookmark folder path uses it), at most 40 characters. Nil when nothing is left.
    static func folderName(_ raw: String) -> String? {
        let cleaned = raw.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(40))
    }
}

/// Everything the favorites row needs from the bookmark list, read once: the start page works from one of these per render, so the list is scanned once, not once for
/// every tile and menu.
struct FavoriteSnapshot {
    let entries: [FavoriteEntry]
    let favorites: [BookmarkItem]
    let folderNames: [String]
    let picks: [BookmarkItem]
    let folderOf: [String: String]
    private let keys: Set<String>

    init(entries: [FavoriteEntry], favorites: [BookmarkItem], folderNames: [String], picks: [BookmarkItem], folderOf: [String: String]) {
        self.entries = entries; self.favorites = favorites; self.folderNames = folderNames; self.picks = picks; self.folderOf = folderOf
        self.keys = Set(favorites.map { FavoriteURL.key($0.url) })
    }

    func isFavorite(_ url: String) -> Bool { keys.contains(FavoriteURL.key(url)) }
}

@MainActor
extension BrowserModel {
    static var favoritesFolderPrefix: String { favoritesFolder + "/" }
    static func isFavoritesFolder(_ folder: String) -> Bool { folder == favoritesFolder || folder.hasPrefix(favoritesFolderPrefix) }

    // MARK: Folders

    /// The folders, in the order they were made (a folder that only exists as a bookmark folder, from an import or another device, is included).
    var favoriteFolderNames: [String] { favoriteFolderNames(in: favorites) }

    func favoriteFolderNames(in favorites: [BookmarkItem]) -> [String] {
        var names: [String] = Self.decodeList(((try? core.getSetting(key: "favorites_folders")) ?? nil))
        for item in favorites where item.folder.hasPrefix(Self.favoritesFolderPrefix) {
            let name = String(item.folder.dropFirst(Self.favoritesFolderPrefix.count))
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func saveFavoriteFolderNames(_ names: [String]) {
        saveSetting("favorites_folders", (try? String(data: JSONEncoder().encode(names), encoding: .utf8)) ?? "[]")
    }

    func isFavoriteFolderName(_ name: String) -> Bool {
        favoriteFolderNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Makes a folder. Returns its name, or nil (with a notice) when the name is empty or already used.
    @discardableResult
    func createFavoriteFolder(_ raw: String) -> String? {
        guard let name = FavoriteURL.folderName(raw) else { notice = "A folder needs a name."; return nil }
        guard !isFavoriteFolderName(name) else { notice = "There is already a folder called “\(name)”."; return nil }
        saveFavoriteFolderNames(favoriteFolderNames + [name])
        objectWillChange.send()
        return name
    }

    func renameFavoriteFolder(_ old: String, to raw: String) {
        guard let name = FavoriteURL.folderName(raw), name != old else { return }
        guard !isFavoriteFolderName(name) else { notice = "There is already a folder called “\(name)”."; return }
        // Read before anything moves: the list also takes in folders that only exist as bookmark folders, and the new name would then be in it twice.
        let names = favoriteFolderNames
        let order = completedFavoriteOrder()
        for item in favorites where item.folder == Self.favoritesFolderPrefix + old {
            try? core.addBookmark(url: item.url, title: item.title, folder: Self.favoritesFolderPrefix + name)
        }
        var renamed: [String] = []
        for each in names.map({ $0 == old ? name : $0 }) where !renamed.contains(each) { renamed.append(each) }
        saveFavoriteFolderNames(renamed)
        saveFavoritesOrder(order.map { $0 == FavoriteToken.folder(old) ? FavoriteToken.folder(name) : $0 })
        refreshBookmarkState()
        objectWillChange.send()
    }

    /// Deletes the folder only. Its favorites go back to the top level and every bookmark is kept.
    func deleteFavoriteFolder(_ name: String) {
        let inside = favorites.filter { $0.folder == Self.favoritesFolderPrefix + name }
        for item in inside { try? core.addBookmark(url: item.url, title: item.title, folder: Self.favoritesFolder) }
        saveFavoriteFolderNames(favoriteFolderNames.filter { $0 != name })
        saveFavoritesOrder(completedFavoriteOrder().filter { $0 != FavoriteToken.folder(name) })
        refreshBookmarkState()
        objectWillChange.send()
        if !inside.isEmpty { notice = "Folder deleted. Its \(inside.count) favorite\(inside.count == 1 ? "" : "s") moved to the Favorites row." }
    }

    /// The folder a favorite is in (nil when it is on the top level).
    func favoriteFolder(of url: String) -> String? {
        guard let item = favorites.first(where: { $0.url == url }), item.folder.hasPrefix(Self.favoritesFolderPrefix) else { return nil }
        return String(item.folder.dropFirst(Self.favoritesFolderPrefix.count))
    }

    /// Moves a favorite into a folder (nil: back to the top level). It stays one bookmark; only its folder changes.
    func moveFavorite(_ url: String, toFolder name: String?) {
        guard let item = favorites.first(where: { $0.url == url }) else { return }
        if let name, !favoriteFolderNames.contains(name) { return }
        let destination = name.map { Self.favoritesFolderPrefix + $0 } ?? Self.favoritesFolder
        guard item.folder != destination else { return }
        try? core.addBookmark(url: item.url, title: item.title, folder: destination)
        refreshBookmarkState()
        objectWillChange.send()
    }

    // MARK: Order

    /// Every favorite's address and every folder's token, in the saved order, with anything the order does not know yet after it (so nothing saved is ever dropped, and
    /// nothing is lost when an order is damaged: it simply reads as empty and the favorites keep their listed order).
    func completedFavoriteOrder() -> [String] {
        let all = favorites
        return completedFavoriteOrder(favorites: all, folderNames: favoriteFolderNames(in: all))
    }

    func completedFavoriteOrder(favorites: [BookmarkItem], folderNames: [String]) -> [String] {
        let saved: [String] = Self.decodeList(((try? core.getSetting(key: "favorites_order")) ?? nil))
        let known = Set(favorites.map(\.url) + folderNames.map(FavoriteToken.folder))
        var seen = Set<String>(), result: [String] = []
        for token in saved where known.contains(token) && seen.insert(token).inserted { result.append(token) }
        for item in favorites where seen.insert(item.url).inserted { result.append(item.url) }
        for name in folderNames where seen.insert(FavoriteToken.folder(name)).inserted { result.append(FavoriteToken.folder(name)) }
        return result
    }

    /// What the favorites row shows, in order: loose favorites and folders. With `flattened`, a folder's favorites take the folder's place in the row instead.
    func favoriteEntries(flattened: Bool = false) -> [FavoriteEntry] {
        favoriteSnapshot(flattened: flattened).entries
    }

    /// Reads the bookmark list once and works out the row, the folders and the bookmarks to choose from.
    func favoriteSnapshot(flattened: Bool = false) -> FavoriteSnapshot {
        let everything = (try? core.listBookmarks(query: "")) ?? []
        let all = everything.filter { Self.isFavoritesFolder($0.folder) }
        let names = favoriteFolderNames(in: all)
        let order = completedFavoriteOrder(favorites: all, folderNames: names)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        func byOrder(_ items: [BookmarkItem]) -> [BookmarkItem] { items.sorted { (rank[$0.url] ?? Int.max) < (rank[$1.url] ?? Int.max) } }
        let loose = all.filter { $0.folder == Self.favoritesFolder }
        var entries: [(rank: Int, entry: FavoriteEntry)] = loose.map { (rank[$0.url] ?? Int.max, .item($0)) }
        var folderOf: [String: String] = [:]
        for name in names {
            let items = byOrder(all.filter { $0.folder == Self.favoritesFolderPrefix + name })
            for item in items { folderOf[item.url] = name }
            if flattened {
                let base = rank[FavoriteToken.folder(name)] ?? Int.max
                entries += items.map { (base, .item($0)) }
            } else {
                entries.append((rank[FavoriteToken.folder(name)] ?? Int.max, .folder(FavoriteFolder(name: name, items: items))))
            }
        }
        // A stable sort: entries with equal rank (new ones, or a folder's favorites when flattened) keep the order they were added in.
        let sorted = entries.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.entry)
        let saved = Set(all.map { FavoriteURL.key($0.url) })
        let picks = Array(everything.filter { !Self.isFavoritesFolder($0.folder) && !saved.contains(FavoriteURL.key($0.url)) }.sorted { $0.created > $1.created }.prefix(15))
        return FavoriteSnapshot(entries: sorted, favorites: all, folderNames: names, picks: picks, folderOf: folderOf)
    }

    /// Puts an entry (a favorite's address or a folder token) before another, or last when `target` is nil.
    func moveFavoriteEntry(_ id: String, before target: String?) {
        var order = completedFavoriteOrder()
        guard id != target, let from = order.firstIndex(of: id) else { return }
        order.remove(at: from)
        if let target, let to = order.firstIndex(of: target) { order.insert(id, at: to) } else { order.append(id) }
        saveFavoritesOrder(order)
    }

    /// Dropping a favorite on another: it goes before it, in the same place (a favorite dropped on one inside a folder joins that folder first).
    func moveFavorite(_ url: String, before target: String) {
        if favorites.contains(where: { $0.url == target }), favoriteFolder(of: url) != favoriteFolder(of: target) {
            moveFavorite(url, toFolder: favoriteFolder(of: target))
        }
        moveFavoriteEntry(url, before: target)
    }

    /// One step earlier or later among the entries beside it (the same row, or the same folder).
    func nudgeFavorite(_ id: String, by step: Int) {
        let siblings: [String]
        if let folder = favoriteFolder(of: id) {
            siblings = favoriteEntries().compactMap { entry in if case .folder(let f) = entry, f.name == folder { return f.items.map(\.url) } else { return nil } }.first ?? []
        } else {
            siblings = favoriteEntries().map(\.id)
        }
        guard let from = siblings.firstIndex(of: id) else { return }
        let to = max(0, min(siblings.count - 1, from + step))
        guard to != from else { return }
        var moved = siblings
        moved.insert(moved.remove(at: from), at: to)
        let next = to + 1 < moved.count ? moved[to + 1] : nil
        moveFavoriteEntry(id, before: next)
    }

    // MARK: Adding

    /// The address a page is already saved under, if any bookmark means the same page (so adding it again updates that one, never makes a second).
    func bookmarkedAddress(equivalentTo address: String) -> String? {
        let key = FavoriteURL.key(address)
        return ((try? core.listBookmarks(query: "")) ?? []).first { FavoriteURL.key($0.url) == key }?.url
    }

    /// Bookmarks that are not favorites yet, most recent first, to choose from.
    func bookmarksToPick(limit: Int = 15) -> [BookmarkItem] {
        let saved = Set(favorites.map { FavoriteURL.key($0.url) })
        let all = ((try? core.listBookmarks(query: "")) ?? []).filter { !Self.isFavoritesFolder($0.folder) && !saved.contains(FavoriteURL.key($0.url)) }
        return Array(all.sorted { $0.created > $1.created }.prefix(limit))
    }

    /// Makes a bookmark a favorite (in a folder, or on the top level). It keeps its title; nothing is copied.
    func makeFavorite(_ item: BookmarkItem, inFolder folder: String? = nil) {
        let destination = folder.map { Self.favoritesFolderPrefix + $0 } ?? Self.favoritesFolder
        try? core.addBookmark(url: item.url, title: item.title, folder: destination)
        refreshBookmarkState()
        objectWillChange.send()
    }

    /// Opens a favorite in a window of its own (Mac). Only web addresses.
    func openFavoriteInNewWindow(_ address: String) {
        guard !isGuest, let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        windows.reopening = [url]
        windows.reopeningContainer = nil
        windows.onNeedWindow?()
    }

    /// Opens a favorite in a tab behind the one in front, or in a private tab. Never private unless that is what was asked for.
    func openFavoriteInBackground(_ address: String) {
        guard let url = URL(string: address) else { return }
        _ = openTab(url: url, isPrivate: active?.isPrivate ?? false, select: false)
    }

    func openFavoritePrivately(_ address: String) {
        guard let url = URL(string: address) else { return }
        _ = openTab(url: url, isPrivate: true)
    }

    // MARK: Frequently visited

    private var dismissedOftenKeys: [String] { Self.decodeList(((try? core.getSetting(key: "often_dismissed")) ?? nil)) }

    func isDismissedOften(_ url: String) -> Bool { dismissedOftenKeys.contains(FavoriteURL.key(url)) }

    /// "Don't show this again": the site stays out of Often visited until the hidden sites are cleared.
    func dismissOften(_ url: String) {
        var keys = dismissedOftenKeys
        let key = FavoriteURL.key(url)
        guard !keys.contains(key) else { return }
        keys.append(key)
        saveSetting("often_dismissed", (try? String(data: JSONEncoder().encode(keys), encoding: .utf8)) ?? "[]")
        objectWillChange.send()
    }

    var dismissedOftenCount: Int { dismissedOftenKeys.count }

    func clearDismissedOften() {
        saveSetting("often_dismissed", "[]")
        objectWillChange.send()
    }

    /// Puts the look back to the defaults. Favorites, folders and bookmarks are not touched.
    func restoreFavoriteLayoutDefaults() {
        favoriteStyle = .classic
        favoriteLabels = true
        favoriteFoldersShown = true
        oftenCount = Self.defaultOftenCount
    }

    #if os(macOS)
    static let defaultOftenCount = 12
    #else
    static let defaultOftenCount = 8
    #endif
}
