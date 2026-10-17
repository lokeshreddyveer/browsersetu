import SwiftUI

/// Settings › Toolbar: drag to put the bottom toolbar's buttons in the order you want, and to choose what lives in the More menu.
struct PhoneToolbarEditor: View {
    @EnvironmentObject var model: BrowserModel

    private var layout: PhoneToolbarLayout { model.phoneLayout }

    var body: some View {
        List {
            Section {
                Text("The toolbar holds up to \(PhoneToolbarLayout.maxActions) buttons, the address bar and the ⋮ menu. Drag to reorder. Anything you take out goes to the More menu, or can be hidden.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Toolbar") {
                ForEach(layout.slots, id: \.self) { slot in
                    switch slot {
                    case .address:
                        Label("Address bar", systemImage: "link").foregroundStyle(.secondary)
                    case .action(let action):
                        row(action)
                    }
                }
                .onMove { model.phoneLayout = layout.movingSlots(from: $0, to: $1) }
            }
            Section("More menu") {
                ForEach(layout.more) { row($0) }
                    .onMove { model.phoneLayout = layout.movingMore(from: $0, to: $1) }
                if layout.more.isEmpty { Text("Nothing here").foregroundStyle(.secondary) }
            }
            if !layout.hidden.isEmpty {
                Section("Hidden") { ForEach(layout.hidden) { row($0) } }
            }
            Section {
                Button("Reset to Default", role: .destructive) { model.phoneLayout = .standard }
                    .disabled(layout == .standard)
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Toolbar")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("toolbar-editor")
    }

    private func row(_ action: PhoneAction) -> some View {
        HStack {
            Label(action.title, systemImage: action.symbol)
            Spacer()
            Menu {
                if layout.location(of: action) != .toolbar {
                    Button("Move to Toolbar", systemImage: "rectangle.bottomthird.inset.filled") { model.phoneLayout = layout.moving(action, to: .toolbar) }
                        .disabled(layout.toolbarIsFull)
                }
                if layout.location(of: action) != .more {
                    Button("Move to More Menu", systemImage: "ellipsis") { model.phoneLayout = layout.moving(action, to: .more) }
                }
                if layout.location(of: action) != .hidden && action.canBeHidden {
                    Button("Hide", systemImage: "eye.slash") { model.phoneLayout = layout.moving(action, to: .hidden) }
                }
            } label: { Image(systemName: "arrow.left.arrow.right.circle").foregroundStyle(Theme.accent) }
                .accessibilityLabel("Move \(action.title)")
        }
    }
}

/// The iPhone's own settings: the toolbar, the address pill, one-handed use, dark pages and Low Power Mode.
struct PhoneInterfaceSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Group {
            Section("Toolbar") {
                NavigationLink("Customize Toolbar and Menu") { PhoneToolbarEditor() }
                    .accessibilityIdentifier("customize-toolbar")
                Picker("Address bar shows", selection: $model.addressDisplay) {
                    ForEach(AddressDisplay.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show the site’s icon", isOn: $model.showAddressIcon)
                Toggle("Collapse the toolbar while reading", isOn: $model.collapseOnScroll)
            }
            Section {
                Toggle("Swipe the address bar to switch tabs", isOn: $model.swipeAddressPill)
                Toggle("Open search at the bottom", isOn: $model.searchPanelAtBottom)
            } header: {
                Text("One-Handed Use")
            } footer: {
                Text("Swipe the address bar sideways to move between tabs, or up to see all tabs. Press and hold it for quick actions. Search normally opens at the top.")
            }
            Section {
                Picker("Links to sites with an app", selection: $model.appLinkMode) {
                    ForEach(ExternalApps.Mode.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("app-links-mode")
                ForEach(model.appLinkSites.keys.sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Text(model.appLinkSites[host] == "app" ? "Opens the app" : "Stays here").foregroundStyle(.secondary)
                    }
                    .swipeActions { Button("Forget", role: .destructive) { model.setAppLinkSite(host, to: nil) } }
                }
            } header: {
                Text("Links and Apps")
            } footer: {
                Text("When you follow a link to a site such as YouTube or Maps, Browser Setu can open the app that belongs to it, or keep the page here. Sites you chose “Always” for are listed; swipe one to forget it.")
            }
            Section {
                Toggle("Hide private tabs in the app switcher", isOn: $model.blurPrivateSwitcher)
            } footer: {
                Text("A private tab is covered by a blur when you switch apps, so nobody glancing at the switcher sees it.")
            }
            DarkPagesSection()
            Section {
                Toggle("Release tabs sooner in Low Power Mode", isOn: $model.lowPowerSavesMemory)
            } footer: {
                Text("While Low Power Mode is on, tabs you are not using are released earlier to save battery. Turn Low Power Mode off and your Memory setting applies again.")
            }
        }
    }
}
