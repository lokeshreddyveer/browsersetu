import SwiftUI

/// Classic's tab strip shows one group's tabs at a time (the ungrouped tabs, or one chosen group and what is inside it). This chip, at the start of the strip, says which, and its menu is where to
/// switch and to manage the groups: the same commands the Sidebar's group headers and Tab Overview use (`selectGroup`, `createGroup`, `createSubgroup`, `renameGroup`, `setGroupColor`, `deleteGroup`),
/// not a new group view. It is not there until a group exists. "Ungrouped" is the strip's existing meaning of no group; it is not an "All Tabs" mode.
struct ClassicGroupChip: View {
    @EnvironmentObject var model: BrowserModel
    @State private var hovering = false
    @State private var dropTargeted = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var current: String { model.activeGroup }
    /// How many tabs the strip is showing in this group (or with no group).
    private var count: Int { model.visibleTabs.filter { !$0.pinned }.count }
    /// With no group chosen, a strip that shows groups inline shows every tab ("All Tabs"); one that does not shows the ungrouped tabs.
    private var title: String { current.isEmpty ? (inlineCapable ? "All Tabs" : "Ungrouped") : GroupPath.leaf(current) }
    private var inlineCapable: Bool { [LayoutPreset.classic, .classicReversed, .minimal, .minimalReversed, .inline].contains(model.layoutPreset) || (model.layoutPreset == .custom && model.effectiveTabLayout != .sidebar) }

    var body: some View {
        if !model.groupNames.isEmpty || !current.isEmpty {
            Menu { menu } label: { label }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .onHover { hovering = $0 }
                .help(current.isEmpty ? "Showing the tabs that are in no group. Choose a group to show its tabs. Drop a tab here to take it out of its group." : "Showing the group \(current). Choose another, or the ungrouped tabs. Drop a tab here to add it to this group.")
                // A tab dropped on the chip joins the group shown (or leaves its group, when the strip shows the ungrouped tabs): the menu's Move to Group, by drag.
                .dropDestination(for: String.self) { items, _ in
                    guard let raw = items.first, let id = UInt64(raw) else { return false }
                    return model.acceptDroppedTab(id, intoGroup: current)
                } isTargeted: { dropTargeted = $0 }
                .accessibilityIdentifier("classic-group-chip")
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: current.isEmpty ? "square.on.square" : "folder.fill").font(.system(size: 11, weight: .medium))
                .foregroundStyle(current.isEmpty ? Color.secondary : (model.groupColor(current)?.color ?? Theme.accent))
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        // The spoken name sits on the menu's label: a menu button takes its name from its label content, and a label set on the Menu itself came out empty.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tab group: \(title), \(count) tab\(count == 1 ? "" : "s")")
        .accessibilityHint("Opens the list of groups")
        .foregroundStyle(Color.primary.opacity(0.8))
        .padding(.horizontal, 9).frame(height: model.density.stripPillHeight)
        .background(Capsule(style: .continuous).fill(dropTargeted ? Theme.accent.opacity(0.25) : Color.primary.opacity(contrast == .increased ? (hovering ? 0.22 : 0.14) : (hovering ? 0.11 : 0.06))))
        .overlay { if contrast == .increased { Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.4), lineWidth: 1).allowsHitTesting(false) } }
        .contentShape(Capsule(style: .continuous))
    }

    @ViewBuilder private func choice(_ text: String, _ checked: Bool) -> some View {
        if checked { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    @ViewBuilder private var menu: some View {
        Button { model.selectGroup("") } label: {
            choice(inlineCapable ? "All Tabs, Groups Inline (\(model.listedTabs(inWorkspace: model.activeWorkspace).filter { !$0.pinned }.count))" : "Ungrouped Tabs (\(model.tabCount(inGroup: "")))", current.isEmpty)
        }
        if !model.groupNames.isEmpty {
            Divider()
            ForEach(model.groupNames, id: \.self) { name in
                Button { model.selectGroup(name) } label: { choice("\(name) (\(model.tabCount(inGroup: name)))", current == name) }
            }
        }
        Divider()
        Button("New Group…") { promptNewGroup(model: model) }
        if !current.isEmpty {
            Button("New Subgroup…") { newSubgroup() }
            Button("Rename Group…") { rename() }
            Menu("Group Colour") {
                ForEach(GroupColor.allCases) { color in
                    Button { model.setGroupColor(current, color) } label: { choice(color.title, model.groupColor(current) == color) }
                }
                Divider()
                Button("No Colour") { model.setGroupColor(current, nil) }
            }
            Divider()
            Button("Delete Group", role: .destructive) { model.deleteGroup(current) }
        }
    }

    private func newSubgroup() {
        let model = model, group = current
        Task { @MainActor in
            if let name = await Dialogs.promptText(title: "New Subgroup", message: "Name a group inside “\(GroupPath.leaf(group))”.", placeholder: ""), !name.isEmpty {
                model.createSubgroup(under: group, named: name)
            }
        }
    }

    private func rename() {
        let model = model, group = current
        Task { @MainActor in
            if let new = await Dialogs.promptText(title: "Rename Group", message: "New name for “\(group)”.", placeholder: group), !new.isEmpty { model.renameGroup(group, to: new) }
        }
    }
}
