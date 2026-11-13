import CryptoKit
import Foundation
import WebKit

/// Attaches the app's own extra rule list (see `ExtraRules`) to every tab, beside the privacy kit's lists. One list at a time: a new one is compiled first,
/// then swapped in, so a rule that fails to compile leaves the old one in force. An unchanged list is taken from WebKit's store, not compiled again, which
/// is what keeps the start of a session quick. Public WebKit API only.
@MainActor
final class ExtraRuleInstaller {
    private let store: WKContentRuleListStore = TestIsolation.contentRuleStore() ?? .default()
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var active: WKContentRuleList?
    private var activeIdentifier: String?
    private var wanted: String?
    private var working: Task<Void, Never>?

    /// Call for every new tab before it loads anything.
    func register(_ controller: WKUserContentController) {
        controllers.add(controller)
        if let active { controller.add(active) }
    }

    /// `nil` removes the list. Calls that arrive while one is being installed are folded into the latest.
    func apply(_ json: String?) {
        wanted = json
        guard working == nil else { return }
        working = Task { @MainActor in
            while true {
                let target = wanted
                await install(target)
                if wanted == target { break }
            }
            working = nil
        }
    }

    /// Returns when nothing is left to install.
    func settled() async { await working?.value }

    private func install(_ json: String?) async {
        guard let json else {
            detach()
            return
        }
        let identifier = "bs-extra-" + SHA256.hash(data: Data(json.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        if identifier == activeIdentifier { return }
        var list = await lookUp(identifier)
        if list == nil { list = try? await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) }
        guard let compiled = list else { return }
        let previous = active
        for controller in controllers.allObjects {
            controller.add(compiled)
            if let previous { controller.remove(previous) }
        }
        active = compiled
        activeIdentifier = identifier
        await prune(keeping: identifier)
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
    }

    private func detach() {
        if let active { for controller in controllers.allObjects { controller.remove(active) } }
        active = nil
        activeIdentifier = nil
    }

    private func prune(keeping keep: String) async {
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers where identifier.hasPrefix("bs-extra-") && identifier != keep {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }
}
