import SwiftUI

#if os(macOS)
/// Page Tools › Page: the menu bar's page commands, grouped by what they are for. Every row is a command from `AppCommands` (the same ones the menu bar and the command palette run), so a row can
/// never be a control that does nothing; a command that is not available right now (no page open, nothing to find) is dimmed instead of hidden, and a title that no longer exists is simply absent.
struct PageActionsView: View {
    @EnvironmentObject var model: BrowserModel

    struct ActionGroup: Identifiable {
        let name: String
        let titles: [String]
        var id: String { name }
    }

    static let groups: [ActionGroup] = [
        ActionGroup(name: "View", titles: ["Reader", "Zoom In", "Zoom Out", "Actual Size", "Request Mobile Website"]),
        ActionGroup(name: "Find", titles: ["Find in Page…", "Find in All Tabs…", "Search This Site…"]),
        ActionGroup(name: "Capture and Print", titles: ["Take Screenshot", "Take Full-Page Screenshot", "Screenshot and Edit…", "Save Page as PDF", "Page as PDF and Mark Up", "Print…"]),
        ActionGroup(name: "Share and Save", titles: ["Share Page…", "Copy Clean Link", "QR Code for This Page…", "Bookmark This Page", "Add to Reading List", "Save Page for Later"]),
        ActionGroup(name: "This Website", titles: ["Style for This Website…", "Privacy Grade for This Site", "Translate Page", "Detect Page Language", "Summarize This Page…", "Repair This Page…"]),
    ]

    /// The commands of a group, in its order; titles with no command are dropped.
    static func commands(for group: ActionGroup) -> [AppCommand] {
        group.titles.compactMap { title in AppCommands.all.first { $0.title == title } }
    }

    private var noPage: Bool { model.active?.isBlank ?? true }

    var body: some View {
        Form {
            ForEach(Self.groups) { group in
                let rows = Self.commands(for: group)
                if !rows.isEmpty {
                    Section {
                        ForEach(rows) { command in row(command) }
                    } header: { Text(group.name) } footer: {
                        if group.id == Self.groups.last?.id && noPage { Text("Open a page to use these.") }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("page-tools-page")
    }

    private func row(_ command: AppCommand) -> some View {
        let enabled = command.isEnabled(model)
        return Button { run(command) } label: {
            HStack {
                Text(command.title)
                Spacer()
                if let action = command.shortcut, let combo = model.shortcuts.combo(for: action) {
                    Text(combo.display).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(command.title)
    }

    /// Runs it. Zoom keeps the sheet open (it is pressed more than once); anything else that did not open another sheet closes this one, so the result is not hidden behind it.
    private func run(_ command: AppCommand) {
        let before = model.sheet
        guard AppCommands.perform(command, model) else { return }
        let keepsOpen = command.title.hasPrefix("Zoom") || command.title == "Actual Size" || command.title == "Request Mobile Website"
        if !keepsOpen, model.sheet == before { model.sheet = nil }
    }
}
#endif
