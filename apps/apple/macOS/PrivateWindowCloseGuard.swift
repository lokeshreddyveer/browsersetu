import AppKit

/// What closing a private window means for its downloads, decided apart from the alert so it can be tested.
enum PrivateWindowClosing {
    enum Decision: Equatable { case closeNow, askFirst(running: Int) }

    /// A private window with downloads still running asks first; with none (or finished ones only) it closes at once. The app quitting is not asked about here.
    static func decision(activeDownloads: Int, appIsQuitting: Bool) -> Decision {
        (activeDownloads > 0 && !appIsQuitting) ? .askFirst(running: activeDownloads) : .closeNow
    }

    static func message(running: Int) -> String {
        "\(running) private download\(running == 1 ? " is" : "s are") still running. Closing this window cancels \(running == 1 ? "it" : "them"). Files that finished downloading are not touched."
    }
}

extension BrowserModel {
    /// Downloads of this private window that have not finished.
    var activePrivateDownloadCount: Int {
        guard isPrivateWindow else { return 0 }
        return downloads.ledger.records.values.filter { $0.privateSession == privateSessionID && !$0.state.isFinal }.count
    }
}

/// Sits in front of a private window's own delegate: it answers "may this window close?" and passes everything else on to the delegate SwiftUI gave the window, so nothing else about the
/// window changes.
final class PrivateWindowCloseGuard: NSObject, NSWindowDelegate {
    weak var original: NSWindowDelegate?
    weak var model: BrowserModel?

    override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
    override func forwardingTarget(for selector: Selector!) -> Any? { original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = MainActor.assumeIsolated { model?.activePrivateDownloadCount ?? 0 }
        let quitting = MainActor.assumeIsolated { model?.windows.terminating ?? false }
        guard case .askFirst(let count) = PrivateWindowClosing.decision(activeDownloads: running, appIsQuitting: quitting) else {
            return original?.windowShouldClose?(sender) ?? true
        }
        let alert = NSAlert()
        alert.messageText = "Close this private window?"
        alert.informativeText = PrivateWindowClosing.message(running: count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Keep Window Open")
        let close = alert.addButton(withTitle: "Close & Cancel Downloads")
        close.hasDestructiveAction = true
        alert.beginSheetModal(for: sender) { response in
            // Close() does not ask again; the window's own close handling then cancels what it was downloading.
            if response == .alertSecondButtonReturn { sender.close() }
        }
        return false
    }
}
