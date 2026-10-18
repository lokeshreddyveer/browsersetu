import SwiftUI

// Settings for break mode, page actions, address bar sources, hover previews, tab stacks, the theme schedule, command chains, web panels and the right-click menus.

/// Which results the address bar shows, and in what order.
struct AddressSourcesSection: View {
    @EnvironmentObject var model: BrowserModel

    private var ordered: [AddressSource] { model.addressSources + AddressSource.allCases.filter { !model.addressSources.contains($0) } }

    var body: some View {
        Section {
            ForEach(ordered) { source in
                let on = model.addressSources.contains(source)
                HStack(spacing: 10) {
                    Image(systemName: source.symbol).frame(width: 18).foregroundStyle(on ? Theme.accent : Color.secondary)
                    Text(source.title).foregroundStyle(on ? Color.primary : Color.secondary)
                    Spacer()
                    if on {
                        Button { move(source, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(model.addressSources.first == source).accessibilityLabel("Move \(source.title) up")
                        Button { move(source, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(model.addressSources.last == source).accessibilityLabel("Move \(source.title) down")
                    }
                    Toggle("", isOn: Binding(get: { on }, set: { set(source, $0) })).labelsHidden().toggleStyle(.switch)
                }
            }
            Button("Reset to Default Order") { animated { model.addressSources = AddressSource.defaults } }
                .disabled(model.addressSources == AddressSource.defaults)
        } header: {
            Text("Address Bar Results")
        } footer: {
            Text("What shows under the address bar as you type, and which comes first. “Go to…” and “Search for…” always stay on top.")
        }
        .motion(.easeOut(duration: 0.2), value: model.addressSources)
    }

    private func set(_ source: AddressSource, _ on: Bool) {
        animated {
            if on, !model.addressSources.contains(source) { model.addressSources.append(source) }
            if !on { model.addressSources.removeAll { $0 == source } }
        }
    }

    private func move(_ source: AddressSource, by delta: Int) {
        guard let index = model.addressSources.firstIndex(of: source), model.addressSources.indices.contains(index + delta) else { return }
        animated { model.addressSources.swapAt(index, index + delta) }
    }
}

/// Switch theme by the time of day.
struct ThemeScheduleSection: View {
    @EnvironmentObject var model: BrowserModel

    private func time(_ minutes: WritableKeyPath<ThemeSchedule, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: model.themeSchedule[keyPath: minutes] / 60, minute: model.themeSchedule[keyPath: minutes] % 60, second: 0, of: Date()) ?? Date()
        }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            model.themeSchedule[keyPath: minutes] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    var body: some View {
        Section {
            Toggle("Change theme by time of day", isOn: Binding(get: { model.themeSchedule.enabled }, set: { on in
                if on, model.themeSchedule.dayTheme.isEmpty { model.themeSchedule.dayTheme = model.allThemes.first { $0.scheme == .light }?.id ?? model.themeID }
                model.themeSchedule.enabled = on
            }))
            if model.themeSchedule.enabled {
                Picker("Day theme", selection: $model.themeSchedule.dayTheme) { ForEach(model.allThemes) { Text($0.name).tag($0.id) } }
                DatePicker("Day starts", selection: time(\.dayStart), displayedComponents: .hourAndMinute)
                Picker("Night theme", selection: $model.themeSchedule.nightTheme) { ForEach(model.allThemes) { Text($0.name).tag($0.id) } }
                DatePicker("Night starts", selection: time(\.nightStart), displayedComponents: .hourAndMinute)
            }
        } header: {
            Text("Theme Schedule")
        } footer: {
            Text("The theme changes by itself at these times, smoothly, while the browser is open.")
        }
        .motion(.easeOut(duration: 0.2), value: model.themeSchedule.enabled)
    }
}

/// Hover previews and tab stacks.
struct TabHoverAndStacksSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Toggle("Show a preview when the pointer rests on a tab", isOn: $model.hoverPreviews)
            if model.hoverPreviews {
                LabeledContent("Delay") {
                    HStack {
                        Slider(value: $model.hoverDelay, in: 0.2...1.5, step: 0.1).frame(width: 160)
                        Text(String(format: "%.1f s", model.hoverDelay)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Tab Previews")
        } footer: {
            Text("A card with the page as you last saw it, its title and address. Pages you have not left yet show only the title.")
        }
        Section {
            Toggle("Stack tabs of a group together in the tab strip", isOn: $model.tabStacks)
        } header: {
            Text("Tab Stacks")
        } footer: {
            Text("With a tab group, its tabs share one place in the strip: the open one shows, with a count, and a click on the count opens the stack's other tabs.")
        }
    }
}

/// Small sites kept beside the page.
struct WebPanelsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var name = ""
    @State private var address = ""

    var body: some View {
        Section {
            if model.webPanels.isEmpty { Text("No web panels").foregroundStyle(.secondary) }
            ForEach(model.webPanels) { panel in
                HStack {
                    VStack(alignment: .leading) { Text(panel.name).fontWeight(.medium); Text(panel.url).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    Button("Open") { model.toggleWebPanel(panel.id) }.buttonStyle(.borderless)
                    Button(role: .destructive) { model.webPanels.removeAll { $0.id == panel.id }; if model.openPanelID == panel.id { model.openPanelID = nil } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).accessibilityLabel("Remove \(panel.name)")
                }
            }
            HStack {
                TextField("Name", text: $name).frame(maxWidth: 140)
                TextField("https://…", text: $address)
                Button("Add") { add() }.disabled(!valid)
            }
        } header: {
            Text("Web Panels")
        } footer: {
            Text("A small site (chat, music, notes) that opens beside the page from the sidebar's panel buttons or the command palette. Only secure (https) addresses are accepted.")
        }
        .motion(.easeOut(duration: 0.2), value: model.webPanels)
    }

    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && URL(string: address).map { $0.scheme == "https" && $0.host != nil } == true && model.webPanels.count < 12 }

    private func add() {
        animated { model.webPanels.append(WebPanel(name: name.trimmingCharacters(in: .whitespaces), url: address.trimmingCharacters(in: .whitespaces))) }
        name = ""; address = ""
    }
}

/// Switch items of the right-click menus on or off.
struct ContextMenusSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            ForEach(MenuItemID.allCases) { item in
                Toggle(item.title, isOn: Binding(get: { model.showsMenuItem(item) }, set: { on in
                    if on { model.hiddenMenuItems.remove(item.rawValue) } else { model.hiddenMenuItems.insert(item.rawValue) }
                }))
            }
            Button("Show All") { model.hiddenMenuItems = [] }.disabled(model.hiddenMenuItems.isEmpty)
        } header: {
            Text("Right-Click Menus")
        } footer: {
            Text("What appears when you right-click the sidebar, the toolbar and the tab strip.")
        }
    }
}

/// Command chains: several commands run as one.
struct CommandChainsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var editing: String?

    var body: some View {
        Section {
            if model.chains.isEmpty { Text("No command chains").foregroundStyle(.secondary) }
            ForEach($model.chains) { $chain in
                DisclosureGroup(isExpanded: Binding(get: { editing == chain.id }, set: { editing = $0 ? chain.id : nil })) {
                    ChainEditor(chain: $chain)
                } label: {
                    HStack {
                        Label(chain.name, systemImage: "link")
                        Spacer()
                        Text("\(chain.steps.count) step\(chain.steps.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("New Chain") {
                let chain = CommandChain(name: "New Chain", steps: [])
                animated { model.chains.append(chain); editing = chain.id }
            }
        } header: {
            Text("Command Chains")
        } footer: {
            Text("Link commands into one. A chain appears in the command palette (⌘⇧P) and in the address bar after “>”. It runs its steps in order, a moment apart.")
        }
        .motion(.easeOut(duration: 0.2), value: editing)
    }
}

private struct ChainEditor: View {
    @EnvironmentObject var model: BrowserModel
    @Binding var chain: CommandChain

    var body: some View {
        let commands = model.chainableCommands
        TextField("Name", text: $chain.name)
        ForEach(chain.steps.indices, id: \.self) { index in
            HStack {
                Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 18)
                Picker("", selection: $chain.steps[index]) {
                    ForEach(commands) { Text($0.title).tag($0.id) }
                    if !commands.contains(where: { $0.id == chain.steps[index] }) { Text("Unavailable command").tag(chain.steps[index]) }
                }
                .labelsHidden()
                Button { chain.steps.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).accessibilityLabel("Remove step")
            }
        }
        HStack {
            Button("Add Step") { if let first = commands.first { chain.steps.append(first.id) } }
            Spacer()
            Button("Run Now") { model.run(chain: chain) }.disabled(chain.steps.isEmpty)
            Button("Delete Chain", role: .destructive) { model.chains.removeAll { $0.id == chain.id } }
        }
    }
}

/// Break mode and page actions: what they are and a way to try them from here.
struct BreakAndPageActionsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Button(model.breakActive ? "End Break (Resume Media)" : "Break: Pause All Media Now") { model.toggleBreakMode() }
            Text("Pauses video and sound in every tab, and plays again only what it paused. It is also in the toolbar's right-click menu and the command palette.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Break Mode")
        }
        Section {
            ForEach(PageAction.allCases) { action in
                Button { model.togglePageAction(action) } label: {
                    HStack {
                        Label(action.title, systemImage: action.symbol)
                        Spacer()
                        if model.active?.pageActions.contains(action) == true { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.active == nil || model.active?.isBlank == true)
            }
            Button("Reset This Page") { model.clearPageActions() }.disabled(model.active?.pageActions.isEmpty ?? true)
        } header: {
            Text("Page Actions")
        } footer: {
            Text("Filters for the page in front: they last for this tab, through reloads. Right-click the toolbar or use the command palette to change them any time.")
        }
    }
}

/// Which buttons sit along the foot of the sidebar, and in what order.
struct SidebarFooterSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var showAll = false

    private var ordered: [SidebarFooterItem] { model.sidebarFooter + SidebarFooterItem.allCases.filter { !model.sidebarFooter.contains($0) } }

    var body: some View {
        Section {
            ShowMoreRows(ordered, id: \.self, limit: 8) { item in
                let on = model.sidebarFooter.contains(item)
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).frame(width: 18).foregroundStyle(on ? Theme.accent : Color.secondary)
                    Text(item.title).foregroundStyle(on ? Color.primary : Color.secondary)
                    Spacer()
                    if on {
                        Button { move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(model.sidebarFooter.first == item).accessibilityLabel("Move \(item.title) earlier")
                        Button { move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(model.sidebarFooter.last == item).accessibilityLabel("Move \(item.title) later")
                    }
                    Toggle("", isOn: Binding(get: { on }, set: { set(item, $0) })).labelsHidden().toggleStyle(.switch)
                }
            }
            Button("Reset to Default") { animated { model.sidebarFooter = SidebarFooterItem.defaults } }.disabled(model.sidebarFooter == SidebarFooterItem.defaults)
        } header: {
            Text("Sidebar Buttons")
        } footer: {
            Text("The buttons along the foot of the sidebar. Seven fit in the row; more go under a “…” button. You can also right-click the row to tick them.")
        }
        .motion(.easeOut(duration: 0.2), value: model.sidebarFooter)
    }

    private func set(_ item: SidebarFooterItem, _ on: Bool) {
        animated {
            if on, !model.sidebarFooter.contains(item) { model.sidebarFooter.append(item) }
            if !on { model.sidebarFooter.removeAll { $0 == item } }
        }
    }

    private func move(_ item: SidebarFooterItem, by delta: Int) {
        guard let index = model.sidebarFooter.firstIndex(of: item), model.sidebarFooter.indices.contains(index + delta) else { return }
        animated { model.sidebarFooter.swapAt(index, index + delta) }
    }
}

/// Which buttons sit inside the address bar, and in what order.
struct AddressBarButtonsSection: View {
    @EnvironmentObject var model: BrowserModel

    private var ordered: [AddressBarItem] { model.addressBarItems + AddressBarItem.allCases.filter { !model.addressBarItems.contains($0) } }

    var body: some View {
        Section {
            ForEach(ordered) { item in
                let on = model.addressBarItems.contains(item)
                HStack(spacing: 10) {
                    Image(systemName: item.symbol).frame(width: 18).foregroundStyle(on ? Theme.accent : Color.secondary)
                    Text(item.title).foregroundStyle(on ? Color.primary : Color.secondary)
                    Spacer()
                    if on && item != .siteInfo {
                        Button { move(item, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(isFirst(item)).accessibilityLabel("Move \(item.title) earlier")
                        Button { move(item, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(model.addressBarItems.last == item).accessibilityLabel("Move \(item.title) later")
                    }
                    Toggle("", isOn: Binding(get: { on }, set: { set(item, $0) })).labelsHidden().toggleStyle(.switch)
                }
            }
            Button("Reset to Default") { animated { model.addressBarItems = AddressBarItem.defaults } }.disabled(model.addressBarItems == AddressBarItem.defaults)
        } header: {
            Text("Address Bar Buttons")
        } footer: {
            Text("What sits inside the address bar. The lock is always at the start; the others follow the field in the order shown. The shield and reload only appear in layouts whose address bar has room for them. You can also right-click the bar.")
        }
        .motion(.easeOut(duration: 0.2), value: model.addressBarItems)
    }

    private func isFirst(_ item: AddressBarItem) -> Bool { model.addressBarItems.filter { $0 != .siteInfo }.first == item }

    private func set(_ item: AddressBarItem, _ on: Bool) {
        animated {
            if on, !model.addressBarItems.contains(item) { model.addressBarItems.append(item) }
            if !on { model.addressBarItems.removeAll { $0 == item } }
        }
    }

    private func move(_ item: AddressBarItem, by delta: Int) {
        var rest = model.addressBarItems.filter { $0 != .siteInfo }
        guard let index = rest.firstIndex(of: item), rest.indices.contains(index + delta) else { return }
        rest.swapAt(index, index + delta)
        animated { model.addressBarItems = (model.addressBarItems.contains(.siteInfo) ? [.siteInfo] : []) + rest }
    }
}


/// Where Bookmarks, History and Downloads open: beside the page, or as a floating sheet over it.
struct DockedPanelsSection: View {
    @EnvironmentObject var model: BrowserModel

    var body: some View {
        Section {
            Picker("Open Bookmarks, History and Downloads", selection: Binding(get: { model.panelMode }, set: { value in
                animated(.easeOut(duration: 0.2)) {
                    model.panelMode = value
                    if value != .dock { model.dockedPanel = nil }
                    if value != .float { model.floatingPanel = nil }
                }
            })) {
                ForEach(PanelMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.panelMode == .dock ? "The page shrinks to make room, so you can read both. Drag the edge between them to resize."
                 : model.panelMode == .tab ? "Each panel is a tab in your tab list, best for long lists." : "A card over the page that closes when you click away.")
                .font(.footnote).foregroundStyle(.secondary)
        } header: { Text("Library panels") }
    }
}
