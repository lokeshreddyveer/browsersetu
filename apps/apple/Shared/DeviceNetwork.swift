import Foundation

/// Whether this device has a network at all, for the error pages: it is how a page can tell "you are offline" from "this site isn't answering", and how a page that failed
/// for lack of a network is tried once more when one returns. It adds nothing of its own to watch the network: it reads the app's one connection-state source
/// (`NetworkConditions`), which only reads the system's state and sends nothing.
@MainActor
final class DeviceNetwork {
    static let shared = DeviceNetwork()

    private var waiting: [AnyHashable: @MainActor () -> Void] = [:]

    private init() {
        NetworkConditions.shared.observe(self) { [weak self] old, new in
            guard !old.online, new.online else { return }
            self?.networkReturned()
        }
    }

    /// Whether the device has a network. (Reads true until the system has reported once, a moment after launch; a failure code that says "not connected" is itself
    /// evidence, so an early failure is still classified correctly.)
    var isOnline: Bool? { NetworkConditions.shared.info.online }

    private func networkReturned() {
        // Each waiting page is tried once, then forgotten.
        let actions = waiting
        waiting = [:]
        actions.values.forEach { $0() }
    }

    /// Runs `action` once, the next time the network returns. It is never run twice, and never at once: a page that failed while the state still looked fine would
    /// otherwise be tried again straight away, and again, in a loop.
    func onceOnline(id: AnyHashable, _ action: @escaping @MainActor () -> Void) { waiting[id] = action }

    /// Forgets the page waiting under `id` (the person acted, or the tab closed).
    func cancel(id: AnyHashable) { waiting[id] = nil }
}
