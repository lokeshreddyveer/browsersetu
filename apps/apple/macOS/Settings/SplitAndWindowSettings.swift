import SwiftUI

/// Where split view and several windows are explained, with the one setting they have. Both are easy to miss, so the ways in are written out.
struct SplitAndWindowSettingsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Picker("Panels sit", selection: $model.splitOrientation) {
                Text("Side by side").tag(SplitOrientation.sideBySide)
                Text("Stacked").tag(SplitOrientation.stacked)
            }
            .pickerStyle(.segmented)
            Toggle("Show the Split View button in the toolbar", isOn: Binding(
                get: { model.shows(.splitView) },
                set: { on in
                    var chosen = Set(model.toolbarItems)
                    if on { chosen.insert(.splitView) } else { chosen.remove(.splitView) }
                    model.toolbarItems = ToolbarItemID.allCases.filter { chosen.contains($0) }
                }))
            howTo("rectangle.split.2x1", "Split a page", "Right-click a tab and choose Open in Split View, press the Split View button in the toolbar, or use the Split View menu. Choose Add a Third Panel for a third page.")
            howTo("hand.tap", "Change the active panel", "Click a panel to make it the active one. The one with the coloured edge receives typing and the address bar.")
        } header: {
            Text("Split View")
        } footer: {
            Text("Panels use more memory because each page stays loaded.")
        }
        Section {
            howTo("macwindow.badge.plus", "A tab in its own window", "Right-click a tab and choose Move to Window ▸ New Window, or use File ▸ Move Tab to New Window.")
            howTo("arrow.left.arrow.right", "Back to the first window", "Drag the tab from its tab bar or sidebar and drop it on the other window's tab bar or sidebar. A window with no tabs left closes by itself.")
            howTo("person.fill.questionmark", "A guest window", "File ▸ New Guest Window opens private tabs only and keeps nothing.")
        } header: {
            Text("Windows")
        }
    }

    private func howTo(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}
