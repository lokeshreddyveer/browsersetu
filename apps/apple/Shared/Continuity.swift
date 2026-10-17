import CoreSpotlight
import SwiftUI
import UniformTypeIdentifiers

/// Handoff and Spotlight. Handoff passes the page in front to the person's own other devices, and Spotlight lets system search find bookmarks; neither ever includes a
/// private tab, history, passwords or page text.
enum Continuity {
    static let pageActivity = "com.browsersetu.page"

    /// The address to hand over for a tab, or nil when it must not leave this window (private, blank, not a web page).
    static func handoffURL(isPrivate: Bool, isBlank: Bool, url: URL?) -> URL? {
        guard !isPrivate, !isBlank, let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return TrackingParameters.clean(url) ?? url
    }

    /// Spotlight's entry for one bookmark: web addresses only, with the title and the site's name.
    static func searchableItem(url: String, title: String) -> CSSearchableItem? {
        guard let address = URL(string: url), ["http", "https"].contains(address.scheme?.lowercased() ?? ""), let host = address.host else { return nil }
        let attributes = CSSearchableItemAttributeSet(contentType: .url)
        attributes.title = title.isEmpty ? host : title
        attributes.contentDescription = host
        attributes.url = address
        let item = CSSearchableItem(uniqueIdentifier: url, domainIdentifier: "bookmarks", attributeSet: attributes)
        item.expirationDate = .distantFuture
        return item
    }
}

extension BrowserModel {
    /// Puts the current bookmarks in Spotlight, or takes them all out when it has been turned off.
    func syncSpotlight() {
        let index = CSSearchableIndex.default()
        guard spotlightBookmarks else { index.deleteSearchableItems(withDomainIdentifiers: ["bookmarks"]) { _ in }; return }
        let items = ((try? core.listBookmarks(query: "")) ?? []).prefix(5_000).compactMap { Continuity.searchableItem(url: $0.url, title: $0.title) }
        index.deleteSearchableItems(withDomainIdentifiers: ["bookmarks"]) { _ in index.indexSearchableItems(Array(items)) { _ in } }
    }

    func openFromSpotlight(_ activity: NSUserActivity) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String, let url = URL(string: id), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        _ = openTab(url: url, isPrivate: false)
    }

    func continuePage(_ activity: NSUserActivity) {
        guard let url = activity.webpageURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return }
        _ = openTab(url: url, isPrivate: false)
    }
}

/// Hands the page in front to the person's other devices while it is on screen.
struct HandoffModifier: ViewModifier {
    @ObservedObject var model: BrowserModel
    func body(content: Content) -> some View {
        let tab = model.active
        let address = Continuity.handoffURL(isPrivate: tab?.isPrivate ?? true, isBlank: tab?.isBlank ?? true, url: tab?.url)
        return content
            .userActivity(Continuity.pageActivity, isActive: address != nil) { activity in
                activity.webpageURL = address
                activity.title = tab?.displayTitle
                activity.isEligibleForHandoff = true
                activity.isEligibleForSearch = false
                activity.isEligibleForPublicIndexing = false
            }
            .onContinueUserActivity(Continuity.pageActivity) { model.continuePage($0) }
            .onContinueUserActivity(CSSearchableItemActionType) { model.openFromSpotlight($0) }
    }
}
extension View { func handoff(_ model: BrowserModel) -> some View { modifier(HandoffModifier(model: model)) } }
