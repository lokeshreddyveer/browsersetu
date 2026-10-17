import AppKit
import SwiftUI

/// Every menu shortcut that can be changed, in groups. Click a shortcut, press the new keys; Delete turns it off, Escape cancels.
struct ShortcutsSettingsSection: View {
    @EnvironmentObject var model: BrowserModel
    @State private var recording: ShortcutAction?
    @State private var message: String?
    @State private var monitor: Any?

    private let groups = ["Tabs", "Address and Search", "Navigation", "Library", "View"]

    var body: some View {
        ForEach(groups, id: \.self) { group in
            Section(group) {
                ForEach(ShortcutAction.allCases.filter { $0.group == group }) { action in row(action) }
            }
        }
        Section {
            LabeledContent("Select Tab 1–9", value: "⌘1–9")
            LabeledContent("Switch Workspace", value: "⌃1–9")
            if let message { Text(message).font(.caption).foregroundStyle(.orange).transition(.opacity) }
            Button("Reset All to Defaults") { model.shortcuts.resetAll(); message = nil }
                .disabled(model.shortcuts == ShortcutMap())
            Text("Click a shortcut, then press the keys you want. A shortcut needs ⌘, ⌃ or ⌥ so it never blocks typing. Delete turns one off; Escape cancels.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { stopRecording() }
        .motion(.easeOut(duration: 0.18), value: message)
    }

    private func row(_ action: ShortcutAction) -> some View {
        HStack {
            Text(action.title)
            Spacer()
            if model.shortcuts.isCustom(action) && recording != action {
                Button { model.shortcuts.reset(action); message = nil } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("Back to \(action.defaultCombo.display)")
            }
            Button { recording == action ? stopRecording() : startRecording(action) } label: {
                Text(label(for: action)).frame(minWidth: 84)
            }
            .buttonStyle(.bordered)
            .tint(recording == action ? Theme.accent : nil)
            .accessibilityIdentifier("shortcut-\(action.rawValue)")
        }
    }

    private func label(for action: ShortcutAction) -> String {
        if recording == action { return "Press keys…" }
        return model.shortcuts.combo(for: action)?.display ?? "None"
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        message = nil
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event, for: action) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func handle(_ event: NSEvent, for action: ShortcutAction) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 53: stopRecording(); return                                       // Escape
        case 51 where flags.intersection([.command, .control, .option]).isEmpty:  // bare Delete
            model.shortcuts.set(nil, for: action); stopRecording(); return
        default: break
        }
        guard let combo = Self.combo(from: event) else { return }
        guard combo.isUsable else { message = "Include ⌘, ⌃ or ⌥ so the shortcut does not block typing."; return }
        if ShortcutMap.isReserved(combo) { message = "\(combo.display) is used by the system or by tab and workspace switching."; return }
        if let other = model.shortcuts.conflict(for: combo, excluding: action) {
            message = "\(combo.display) is already used by “\(other.title)”. Change that one first."
            return
        }
        model.shortcuts.set(combo, for: action)
        stopRecording()
    }

    /// The key and modifiers of a key press, in the form the menus use.
    static func combo(from event: NSEvent) -> KeyCombo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let named: [UInt16: String] = [36: "return", 48: "tab", 49: "space", 51: "delete", 123: "left", 124: "right", 125: "down", 126: "up"]
        let key: String
        if let name = named[event.keyCode] { key = name }
        else if let ch = event.charactersIgnoringModifiers?.lowercased(), ch.count == 1 { key = ch }
        else { return nil }
        return KeyCombo(key: key, command: flags.contains(.command), shift: flags.contains(.shift),
                        option: flags.contains(.option), control: flags.contains(.control))
    }
}
