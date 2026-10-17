import Foundation
import SwiftUI

/// What the user sees about one installed web extension.
struct ExtensionInfo: Identifiable, Equatable {
    var id: String
    var name: String
    var version: String
    var enabled: Bool
    /// Browser features the extension asked for, in plain words.
    var permissions: [String]
    /// Websites it can read and change.
    var sites: [String]
    /// Things WebKit says will not work in this extension.
    var problems: [String]
    /// It has its own settings page.
    var hasOptions = false
    /// Things it asks for that Apple's extension support does not offer, so parts of it may not work.
    var compatibility: [String] = []
    /// 2 or 3, read from the manifest; 0 when it could not be read.
    var manifestVersion = 0
    /// Ties an approval sheet to the inspection it was made from: installing needs the same token, so a second inspection cannot be installed under the first one's approval.
    var approvalToken = ""
    /// For an update: what this version asks for that the installed one did not, in words.
    var addedPermissions: [String] = []
}

/// One extension button in the toolbar.
/// How much of the web an extension may reach. "On click" gives it nothing until the user presses its button (and then only that page, if it
/// asked for that); "specific" keeps the named sites; "all" lets it reach every site.
enum ExtensionSiteAccess: String, CaseIterable, Identifiable {
    case onClick, specific, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .onClick: "On click"
        case .specific: "Specific websites"
        case .all: "All websites"
        }
    }
}

/// One permission an extension holds, as the revoke screen shows it.
struct ExtensionPermissionRow: Identifiable, Equatable {
    var key: String
    var title: String
    /// A website pattern (true) or a browser feature (false).
    var isSite: Bool
    var granted: Bool
    /// A website rule the person added themselves (it can be removed); the others come from the extension's own request.
    var custom = false
    var id: String { (isSite ? "site:" : "api:") + key }
}

struct ExtensionActionItem: Identifiable, Equatable {
    var id: String
    var label: String
    var badge: String
    var enabled: Bool
    var icon: Data?
}

enum ExtensionError: LocalizedError {
    case unsupported, notAnExtension(String), tooLarge, nothingToInstall, copyFailed, installNotAvailable, changedSinceReview, approvalExpired

    var errorDescription: String? {
        switch self {
        case .unsupported: "This version of macOS cannot run web extensions. It needs macOS 15.4 or later."
        case .changedSinceReview: "The extension changed after you reviewed it, so it was not installed. Add it again to review what it asks for now."
        case .approvalExpired: "That approval is no longer current: another extension was inspected since. Add it again."
        case .installNotAvailable: "Extensions can be added on a Mac. Adding them on iPhone is not available yet."
        case .notAnExtension(let why): "That folder is not a web extension. \(why)"
        case .tooLarge: "That extension is larger than \(ExtensionPackage.maxUnpacked / 1_048_576) MB."
        case .nothingToInstall: "There is no extension waiting to be installed."
        case .copyFailed: "The extension could not be copied into Browser Setu."
        }
    }
}

/// What an engine must provide for web extensions. Kept engine-neutral so the interface does not know about WebKit.
@MainActor
protocol ExtensionBackend: AnyObject {
    func permissionRows(id: String) -> [ExtensionPermissionRow]
    func addSiteRule(id: String, host: String, allow: Bool) -> Bool
    func removeSiteRule(id: String, key: String)
    func manifestSummaries() -> [ExtensionManifestSummary]
    func diagnostics(openTabs: Int) -> [ExtensionDiagnostic]
    func previousVersionChanges(id: String) -> ExtensionFileDiff.Result?
    func rollback(id: String) async -> Bool
    func backupArchive() -> Data?
    func sandboxTest(folder: URL) async -> [ExtensionCheck]
    func permissionHistory(id: String) -> [String]
    func siteAccess(id: String) -> ExtensionSiteAccess
    func setSiteAccess(id: String, mode: ExtensionSiteAccess)
    func setPermission(id: String, key: String, isSite: Bool, granted: Bool)
    func inspect(folder: URL, chromeID: String?, replacing: String?) async throws -> ExtensionInfo
    func installPending() async throws
    /// Installs the inspected folder over an existing extension (an update), keeping its enabled state and its saved data.
    func installPending(replacing id: String?, token: String?) async throws
    func openOptions(id: String)
    func remove(id: String) async
    func setEnabled(id: String, enabled: Bool) async
    func perform(actionFor id: String)
    func owns(url: URL) -> Bool
    func tabOpened(_ tab: TabController)
    func tabClosed(_ tab: TabController)
    func tabActivated(_ tab: TabController, previous: TabController?)
    func tabChanged(_ tab: TabController)
}

/// What the browser gives an extension runtime: its tabs, and the ability to open, select and close them.
@MainActor
protocol ExtensionHost: AnyObject {
    var extensionTabs: [TabController] { get }
    var extensionActiveTab: TabController? { get }
    func extensionOpenTab(url: URL?) -> TabController
    func extensionClose(_ tab: TabController)
    func extensionSelect(_ tab: TabController)
    func extensionAsk(title: String, message: String, allow: String) async -> Bool
}

/// The interface's view of extensions. It holds the list and forwards actions; the engine does the work.
@MainActor
final class ExtensionCenter: ObservableObject {
    @Published private(set) var extensions: [ExtensionInfo] = []
    @Published private(set) var actions: [ExtensionActionItem] = []
    @Published private(set) var isSupported = false
    private var backend: ExtensionBackend?
    /// Extensions the user pinned to the toolbar. Until they choose, every extension with a button is pinned.
    @Published private(set) var pinnedIDs: [String]? = UserDefaults.standard.stringArray(forKey: "extension_pins")

    /// Where the button that was just clicked is, in the window's own coordinates (top left origin). The popup opens attached to it.
    var anchor: CGRect?
    /// Where the click that opened a popup landed, in the window's own coordinates (AppKit's, origin at the bottom left). More exact than a measured frame.
    var clickPoint: CGPoint?
    /// When the button was clicked; an older anchor is ignored, so a popup an extension opens later is not pinned to a stale spot.
    var anchorDate = Date.distantPast

    func isPinned(_ id: String) -> Bool { pinnedIDs?.contains(id) ?? true }

    func setPinned(_ id: String, _ pinned: Bool) {
        var ids = pinnedIDs ?? actions.map(\.id)
        ids.removeAll { $0 == id }
        if pinned { ids.append(id) }
        pinnedIDs = ids
        UserDefaults.standard.set(ids, forKey: "extension_pins")
    }

    /// Buttons for the pinned extensions, in the order they were installed.
    var pinnedActions: [ExtensionActionItem] { actions.filter { isPinned($0.id) } }
    var hasExtensions: Bool { isSupported && !extensions.isEmpty }

    /// Adding extensions works wherever WebKit's extension support does (macOS 15.4, iOS 18.4). On the iPhone the same review screen, hash-bound approval and
    /// permission controls apply. Installing code from a store inside an App Store app still needs an App Review decision before any App Store release.
    var canInstall: Bool { isSupported }

    func permissionHistory(_ id: String) -> [String] { backend?.permissionHistory(id: id) ?? [] }
    @discardableResult func addSiteRule(_ id: String, host: String, allow: Bool) -> Bool { backend?.addSiteRule(id: id, host: host, allow: allow) ?? false }
    func removeSiteRule(_ id: String, key: String) { backend?.removeSiteRule(id: id, key: key) }
    func manifestSummaries() -> [ExtensionManifestSummary] { backend?.manifestSummaries() ?? [] }
    func diagnostics(openTabs: Int) -> [ExtensionDiagnostic] { backend?.diagnostics(openTabs: openTabs) ?? [] }
    func previousVersionChanges(_ id: String) -> ExtensionFileDiff.Result? { backend?.previousVersionChanges(id: id) }
    func rollback(_ id: String) async -> Bool { await backend?.rollback(id: id) ?? false }
    func backupArchive() -> Data? { backend?.backupArchive() }
    func sandboxTest(folder: URL) async -> [ExtensionCheck] { await backend?.sandboxTest(folder: folder) ?? [] }
    func siteAccess(_ id: String) -> ExtensionSiteAccess { backend?.siteAccess(id: id) ?? .specific }
    func setSiteAccess(_ id: String, _ mode: ExtensionSiteAccess) { backend?.setSiteAccess(id: id, mode: mode) }

    func permissionRows(_ id: String) -> [ExtensionPermissionRow] { backend?.permissionRows(id: id) ?? [] }
    func setPermission(_ id: String, key: String, isSite: Bool, granted: Bool) { backend?.setPermission(id: id, key: key, isSite: isSite, granted: granted) }

    func attach(_ backend: ExtensionBackend?, supported: Bool) {
        self.backend = backend
        isSupported = supported
        if backend == nil { extensions = []; actions = [] }
    }

    func publish(extensions: [ExtensionInfo], actions: [ExtensionActionItem]) {
        if self.extensions != extensions { self.extensions = extensions }
        if self.actions != actions { self.actions = actions }
    }

    func inspect(_ folder: URL, chromeID: String? = nil, replacing: String? = nil) async throws -> ExtensionInfo {
        guard let backend else { throw ExtensionError.unsupported }
        guard canInstall else { ExtensionPackage.discardUnpacked(folder); throw ExtensionError.installNotAvailable }
        return try await backend.inspect(folder: folder, chromeID: chromeID, replacing: replacing)
    }

    /// Installs what was inspected. `token` is the approval token from that inspection (always given by the screens; only code that inspected the very same
    /// extension itself may leave it out).
    func installPending(replacing id: String? = nil, token: String? = nil) async throws {
        guard let backend else { throw ExtensionError.unsupported }
        guard canInstall else { throw ExtensionError.installNotAvailable }
        try await backend.installPending(replacing: id, token: token)
    }

    func openOptions(_ id: String) { backend?.openOptions(id: id) }

    func remove(_ id: String) async { await backend?.remove(id: id) }
    func setEnabled(_ id: String, _ enabled: Bool) async { await backend?.setEnabled(id: id, enabled: enabled) }
    func perform(actionFor id: String) { backend?.perform(actionFor: id) }
    func owns(url: URL) -> Bool { backend?.owns(url: url) ?? false }

    // Tab events, forwarded so extensions see the same tabs the user does. No-ops when nothing is installed.
    func tabOpened(_ tab: TabController) { backend?.tabOpened(tab) }
    func tabClosed(_ tab: TabController) { backend?.tabClosed(tab) }
    func tabActivated(_ tab: TabController, previous: TabController?) { backend?.tabActivated(tab, previous: previous) }
    func tabChanged(_ tab: TabController) { backend?.tabChanged(tab) }
}
