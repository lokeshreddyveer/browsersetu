import Foundation

/// Evidence from the WebKit adapter that rules were actually compiled and attached. Configuration alone never produces one.
public struct InstallReport: Equatable, Sendable {
    public let installed: Bool
    public let identifier: String?
    public let compileMilliseconds: Double
    public let reusedCompiledList: Bool
    public let attachedWebViews: Int
    public let error: String?
    /// True when protection was switched off and the previous rules were removed on purpose.
    public let removed: Bool

    public init(installed: Bool, identifier: String?, compileMilliseconds: Double = 0, reusedCompiledList: Bool = false,
                attachedWebViews: Int = 0, error: String? = nil, removed: Bool = false) {
        self.installed = installed; self.identifier = identifier; self.compileMilliseconds = compileMilliseconds
        self.reusedCompiledList = reusedCompiledList; self.attachedWebViews = attachedWebViews; self.error = error; self.removed = removed
    }
}

public enum ProtectionState: Equatable, Sendable {
    case active
    case partial(String)
    case disabled
    case exception
    case updating
    case error(String)

    /// The only state in which "Protected by VayuSetu" may be shown.
    public var isProtected: Bool { self == .active }

    public var headline: String {
        switch self {
        case .active: "Protected by VayuSetu"
        case .partial: "VayuSetu protection needs attention"
        case .disabled: "VayuSetu protection is off"
        case .exception: "VayuSetu protection is off for this website"
        case .updating: "VayuSetu is updating protection"
        case .error: "VayuSetu protection is unavailable"
        }
    }

    public var statusWord: String {
        switch self {
        case .active: "Active"
        case .partial: "Partial"
        case .disabled: "Off"
        case .exception: "Off for this site"
        case .updating: "Updating"
        case .error: "Unavailable"
        }
    }

    public var detail: String? {
        switch self {
        case .partial(let reason), .error(let reason): reason
        case .updating: "The previous rules stay active until the new ones are ready."
        default: nil
        }
    }

    public var symbol: String {
        switch self {
        case .active: "checkmark.shield.fill"
        case .partial: "exclamationmark.shield.fill"
        case .disabled, .exception: "shield.slash"
        case .updating: "arrow.triangle.2.circlepath"
        case .error: "xmark.shield.fill"
        }
    }
}

/// Derives the state from evidence. A preference never manufactures "active": it takes a successful install.
public enum ProtectionEvaluator {
    public static func state(configuration: PrivacyConfiguration, snapshot: PolicySnapshot?, install: InstallReport?,
                             updating: Bool, host: String?) -> ProtectionState {
        guard configuration.isEnabled else { return .disabled }
        if updating { return .updating }
        if configuration.isException(host: host) { return .exception }
        guard let install, install.installed else {
            return .error(install?.error ?? "Protection rules have not been installed yet.")
        }
        if let error = install.error {
            return .partial("The last update failed (\(error)). Your previous protection is still active.")
        }
        guard let snapshot, snapshot.identifier == install.identifier else {
            return .partial("The installed rules are older than your settings. They will be replaced shortly.")
        }
        // Lists still on their way are not a fault: the built-in rules protect meanwhile, and the popover says so.
        let real = snapshot.failedLists.filter { $0.value != "Not downloaded yet." }
        if let (name, reason) = real.sorted(by: { $0.key < $1.key }).first {
            return .partial("\(name): \(reason)")
        }
        return .active
    }
}

public struct Capability: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let supported: Bool
    public let note: String
}

/// What this engine can and cannot do with public WebKit APIs. Shown in diagnostics; never implied elsewhere.
public enum PrivacyCapabilities {
    public static let all: [Capability] = [
        Capability(name: "Block requests to listed domains", supported: true, note: "Enforced by WebKit before the request is sent."),
        Capability(name: "URL-pattern blocking", supported: true, note: "From Adblock Plus style rules in downloaded lists."),
        Capability(name: "Hide page elements", supported: true, note: "Plain CSS selectors only; kept separate from request blocking."),
        Capability(name: "Block third-party cookies", supported: true, note: "Strict, and Custom when enabled. The rule installs, but WebKit already refuses third-party cookies by default, so its extra effect cannot be measured separately."),
        Capability(name: "Block third-party tracking-endpoint requests", supported: true, note: "Strict, and Custom when enabled. A heuristic on the request path (/beacon, /collect, /pixel, /telemetry, /analytics, /track); it can miss trackers and can occasionally catch legitimate requests."),
        Capability(name: "Allow rules and website exceptions", supported: true, note: "Order-based; user rules outrank exceptions."),
        Capability(name: "Regular-expression rules", supported: false, note: "Counted as unsupported; never approximated."),
        Capability(name: "Scriptlets and script injection", supported: false, note: "Not used. Filtering never runs downloaded text as code."),
        Capability(name: "Redirect and response-rewriting rules", supported: false, note: "Not available from WebKit's content blocker."),
        Capability(name: "Per-request blocked counts", supported: false, note: "WebKit does not report which requests its blocker stopped, so no counts are shown."),
        Capability(name: "Blocking inside other apps or system-wide", supported: false, note: "Out of scope: this protects BrowserSetu's own pages only."),
    ]
}
