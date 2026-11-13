import Foundation

extension BrowserModel {
    /// A bookmark dragged onto a folder in the Library ("bookmark:<address>" is what the row carries). Only the bookmark's folder changes: its address and its own title stay, no second copy is made, and a
    /// payload that is not a saved bookmark, an address that is not saved, or a drop on the folder it is already in changes nothing. Returns whether something moved.
    @discardableResult func dropBookmark(_ items: [String], into folder: String) -> Bool {
        guard let raw = items.first, raw.hasPrefix("bookmark:") else { return false }
        let url = String(raw.dropFirst("bookmark:".count))
        guard let bookmark = ((try? core.listBookmarks(query: "")) ?? []).first(where: { $0.url == url }), bookmark.folder != folder else { return false }
        do { try core.addBookmark(url: bookmark.url, title: bookmark.title, folder: folder) } catch { return false }
        return true
    }
}
