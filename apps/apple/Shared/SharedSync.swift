import Foundation
#if os(iOS)
import WidgetKit
#endif

@MainActor
extension BrowserModel {
    /// Leaves what the widgets show in the shared folder: favorites, the reading list and today's blocked count. Written only when it changed.
    func publishSharedSnapshot() {
        guard !isSecondary, SharedStore.folder != nil else { return }
        let snapshot = SharedStore.Snapshot(favorites: orderedFavorites.prefix(8).map { .init(title: $0.title.isEmpty ? displayHost(URL(string: $0.url)) : $0.title, url: $0.url) },
                                            reading: readingList.filter { !$0.read }.prefix(5).map { .init(title: $0.title, url: $0.url) },
                                            blockedToday: blockedStats.total(.today), updated: Date())
        var comparable = snapshot; comparable.updated = lastPublished?.updated ?? snapshot.updated
        guard comparable != lastPublished else { return }
        if SharedStore.write(snapshot) {
            lastPublished = snapshot
            #if os(iOS)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    /// Acts on what the share sheet left: open it, save it to the reading list, or send it to another device.
    func consumeSharedInbox() {
        guard !isSecondary, hasStarted, SharedStore.folder != nil else { return }
        let items = SharedStore.takeInbox()
        guard !items.isEmpty else { return }
        for item in items {
            guard let url = URL(string: item.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            switch item.kind {
            case .open: _ = openTab(url: url, isPrivate: false)
            case .readLater:
                if !readingList.contains(where: { $0.url == item.url }) { setReadingList([ReadingItem(url: item.url, title: item.title.isEmpty ? (url.host ?? item.url) : item.title, site: displayHost(url))] + readingList) }
            case .send:
                let tab = openTab(url: url, isPrivate: false, select: false)
                sendToDevice(tab)
            }
        }
        let n = items.count
        notice = n == 1 ? "Took in 1 item from the share sheet." : "Took in \(n) items from the share sheet."
    }

    private func sendToDevice(_ tab: TabController) {
        let devices = syncDevices.filter { $0.status == .approved }
        guard !devices.isEmpty else { notice = "No other device is set up yet. Add one under Sync, then share again."; return }
        if devices.count == 1 { _ = sendTab(tab, to: devices[0]); return }
        Task { @MainActor in
            let names = devices.prefix(3).map(\.name)
            let pick = await Dialogs.choose(title: "Send to which device?", message: tab.url?.host ?? "", buttons: names + ["Cancel"])
            if pick < names.count { _ = sendTab(tab, to: devices[pick]) }
        }
    }
}
