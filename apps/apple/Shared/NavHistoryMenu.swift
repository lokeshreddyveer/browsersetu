import SwiftUI

/// The pages behind (or ahead of) the one in front, as menu items: press and hold, or right-click, the Back or Forward button.
struct NavHistoryItems: View {
    @ObservedObject var tab: TabController
    let back: Bool

    var body: some View {
        let entries = tab.engine.navigationEntries()
        let list = back ? entries.back : entries.forward
        if list.isEmpty {
            Text(back ? "Nothing behind this page" : "Nothing ahead of this page")
        } else {
            ForEach(list) { entry in
                Button(entry.label) { tab.engine.navigate(toOffset: entry.offset) }
            }
        }
    }
}
