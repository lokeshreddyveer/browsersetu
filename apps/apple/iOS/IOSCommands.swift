import SwiftUI

/// The same shortcuts as on the Mac, for a keyboard attached to an iPad or iPhone. They use the same choices as the Mac's Shortcuts
/// settings, and ⌘K opens the search field in command mode.
struct IOSBrowserCommands: Commands {
    @ObservedObject var model: BrowserModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { model.newTab() }.shortcut(.newTab, model.shortcuts)
            Button("New Private Tab") { model.openTab(url: nil, isPrivate: true) }.shortcut(.newPrivateTab, model.shortcuts)
            Button("Open Location") { if UIDevice.current.userInterfaceIdiom == .pad { model.focusAddressBar() } else { model.openSearchPanel() } }.shortcut(.openLocation, model.shortcuts)
            Button("Command Center") {
                if UIDevice.current.userInterfaceIdiom == .pad { model.pendingAddressPrefill = ">"; model.focusAddressBar() } else { model.openSearchPanel(prefill: ">") }
            }.shortcut(.commandPalette, model.shortcuts)
            Divider()
            Button("Close Tab") { if let id = model.activeID { model.closeTab(id: id) } }.shortcut(.closeTab, model.shortcuts)
            Button("Reopen Closed Tab") { model.reopenClosedTab() }.shortcut(.reopenClosedTab, model.shortcuts).disabled(model.closedTabs.isEmpty)
        }
        CommandGroup(after: .toolbar) {
            Button("Show Sidebar") { model.sidebarVisible.toggle() }.shortcut(.toggleSidebar, model.shortcuts)
        }
        CommandMenu("Tabs") {
            ForEach(1...9, id: \.self) { n in
                Button("Tab \(n)") { model.selectTab(number: n) }.keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }
        CommandMenu("Navigate") {
            Button("Back") { model.active?.goBack() }.shortcut(.back, model.shortcuts)
            Button("Forward") { model.active?.goForward() }.shortcut(.forward, model.shortcuts)
            Button("Reload") { model.active?.reload() }.shortcut(.reload, model.shortcuts)
            Button("Stop") { model.active?.stop() }.shortcut(.stop, model.shortcuts)
            Divider()
            Button("Next Tab") { model.selectAdjacent(1) }.shortcut(.nextTab, model.shortcuts)
            Button("Previous Tab") { model.selectAdjacent(-1) }.shortcut(.previousTab, model.shortcuts)
            Button("Show All Tabs") { model.showOverview() }.shortcut(.tabOverview, model.shortcuts)
        }
        CommandMenu("Page") {
            Button("Find in Page") { model.showFind() }.shortcut(.find, model.shortcuts)
            Button("Find in All Tabs") { model.sheet = .findAll }.shortcut(.findAllTabs, model.shortcuts)
            Button("Bookmark This Page") { model.toggleBookmark() }.shortcut(.bookmarkPage, model.shortcuts)
            Button("Reader") { Task { await model.active?.toggleReader() } }.shortcut(.readerMode, model.shortcuts)
            Button("Zoom In") { model.active?.zoom(by: 0.1) }.shortcut(.zoomIn, model.shortcuts)
            Button("Zoom Out") { model.active?.zoom(by: -0.1) }.shortcut(.zoomOut, model.shortcuts)
            Button("Actual Size") { model.active?.resetZoom() }.shortcut(.actualSize, model.shortcuts)
            Divider()
            Button("Bookmarks") { model.sheet = .bookmarks }.shortcut(.showBookmarks, model.shortcuts)
            Button("History") { model.sheet = .history }.shortcut(.showHistory, model.shortcuts)
            Button("Downloads") { model.sheet = .downloads }.shortcut(.showDownloads, model.shortcuts)
        }
    }
}
