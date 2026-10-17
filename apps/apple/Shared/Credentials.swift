import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How the engine should answer a site's sign-in challenge.
enum ChallengeAction: Equatable {
    /// A site asking for a name and password (basic, digest, NTLM): ask the user.
    case askUser
    /// Everything else (certificate checks and the like) stays with the system, which refuses bad certificates.
    case systemDefault

    static func action(forAuthenticationMethod method: String) -> ChallengeAction {
        switch method {
        case "NSURLAuthenticationMethodHTTPBasic", "NSURLAuthenticationMethodHTTPDigest", "NSURLAuthenticationMethodNTLM": .askUser
        default: .systemDefault
        }
    }
}

extension Dialogs {
    /// Asks for a name and password for a site. They are used for this visit; with `canRemember` the user can also keep them in the
    /// Keychain (for this profile only), and then `remember` comes back true.
    @MainActor
    static func credentials(host: String, realm: String?, isProxy: Bool, canRemember: Bool = false) async -> (user: String, password: String, remember: Bool)? {
        let title = isProxy ? "Sign in to the proxy" : "Sign in to \(host)"
        let tail = canRemember ? "They are used for this visit unless you choose to remember them." : "They are used for this visit and not saved."
        let detail = (realm?.isEmpty == false) ? "“\(realm!)” asks for a name and password. \(tail)" : "This site asks for a name and password. \(tail)"
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24)); user.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); pass.placeholderString = "Password"
        let remember = NSButton(checkboxWithTitle: "Remember in my Keychain", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: canRemember ? 86 : 58))
        user.frame.origin.y = canRemember ? 58 : 30
        pass.frame.origin.y = canRemember ? 28 : 0
        stack.addSubview(user); stack.addSubview(pass)
        if canRemember { stack.addSubview(remember) }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sign In"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return (user.stringValue, pass.stringValue, canRemember && remember.state == .on)
        #else
        guard let top = topViewController() else { return nil }
        return await withCheckedContinuation { cont in
            let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
            alert.addTextField { $0.placeholder = "Name"; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
            alert.addTextField { $0.placeholder = "Password"; $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cont.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "Sign In", style: .default) { _ in
                cont.resume(returning: (alert.textFields?[0].text ?? "", alert.textFields?[1].text ?? "", false))
            })
            if canRemember {
                alert.addAction(UIAlertAction(title: "Sign In and Remember", style: .default) { _ in
                    cont.resume(returning: (alert.textFields?[0].text ?? "", alert.textFields?[1].text ?? "", true))
                })
            }
            top.present(alert, animated: true)
        }
        #endif
    }
}
