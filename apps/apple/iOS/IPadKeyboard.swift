import SwiftUI
import UIKit

/// Keyboard shortcuts for an external keyboard, the way Apple's keyboard guidance describes: a view controller that can become first
/// responder and answers key commands, with the page inside its view. (Command-key shortcuts are unreliable on a plain UIView.)
/// Changed keys in Settings › Shortcuts apply here too.
final class KeyCommandController: UIViewController {
    var shortcuts = ShortcutMap()
    var perform: (ShortcutAction) -> Void = { _ in }
    var performTab: (Int) -> Void = { _ in }

    var page: UIView?
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    /// Takes the keyboard back, for example after a dialog closes. A page being typed in keeps it.
    func claimKeyboard() { if !(page?.isFirstResponder ?? false) { becomeFirstResponder() } }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        for action in ShortcutAction.allCases {
            guard let combo = shortcuts.combo(for: action), let input = Self.input(for: combo) else { continue }
            let command = UIKeyCommand(title: "", action: #selector(run(_:)), input: input, modifierFlags: Self.flags(for: combo), propertyList: action.rawValue)
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        for n in 1...9 {
            let command = UIKeyCommand(title: "", action: #selector(runTab(_:)), input: "\(n)", modifierFlags: .command, propertyList: n)
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    @objc private func run(_ sender: UIKeyCommand) {
        guard let raw = sender.propertyList as? String, let action = ShortcutAction(rawValue: raw) else { return }
        perform(action)
    }

    @objc private func runTab(_ sender: UIKeyCommand) {
        if let n = sender.propertyList as? Int { performTab(n) }
    }

    private static func input(for combo: KeyCombo) -> String? {
        switch combo.key {
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case "escape": return UIKeyCommand.inputEscape
        case "up": return UIKeyCommand.inputUpArrow
        case "down": return UIKeyCommand.inputDownArrow
        case "left": return UIKeyCommand.inputLeftArrow
        case "right": return UIKeyCommand.inputRightArrow
        default: return combo.key.count == 1 ? combo.key : nil
        }
    }

    private static func flags(for combo: KeyCombo) -> UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if combo.command { flags.insert(.command) }
        if combo.shift { flags.insert(.shift) }
        if combo.option { flags.insert(.alternate) }
        if combo.control { flags.insert(.control) }
        return flags
    }
}

/// The page, wrapped so the shortcuts above reach it.
struct IPadPageHost: UIViewControllerRepresentable {
    let view: UIView
    let shortcuts: ShortcutMap
    let perform: (ShortcutAction) -> Void
    let performTab: (Int) -> Void

    func makeUIViewController(context: Context) -> KeyCommandController {
        let controller = KeyCommandController()
        controller.page = view
        attach(to: controller)
        return controller
    }

    func updateUIViewController(_ controller: KeyCommandController, context: Context) {
        controller.shortcuts = shortcuts
        controller.perform = perform
        controller.performTab = performTab
        controller.page = view
        if view.superview !== controller.view { attach(to: controller) }
    }

    private func attach(to controller: KeyCommandController) {
        view.removeFromSuperview()
        view.frame = controller.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
    }
}
