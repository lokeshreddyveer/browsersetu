import Foundation
import SetuPrivacyCore
import WebKit

/// Compiles a `PolicySnapshot` into a `WKContentRuleList`, caches it by content hash, and attaches it to every
/// registered `WKUserContentController` (normal and private tabs alike). Public WebKit API only.
///
/// Safety properties:
/// - A new list is compiled *before* anything is detached, so a failed compile leaves the previous rules in force.
/// - An identical snapshot reuses the compiled list from WebKit's store; nothing is recompiled per tab or per page.
/// - Web views are never recreated; the list is added to and removed from their existing content controllers.
@MainActor
public final class ContentRuleInstaller {
    public static let identifierPrefix = "setu-"
    /// Compiled lists kept in WebKit's store besides the active one, so switching back and forth is instant.
    public static let cachedListsKept = 3

    private let store: WKContentRuleListStore
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    public private(set) var activeLists: [WKContentRuleList] = []
    public var activeList: WKContentRuleList? { activeLists.first }
    public private(set) var activeIdentifier: String?
    public private(set) var lastReport: InstallReport?
    private var recentIdentifiers: [String] = []

    public init(store: WKContentRuleListStore? = nil) {
        self.store = store ?? .default()
    }

    /// Call for every new tab *before* it loads anything, so the first request is already filtered.
    public func register(_ controller: WKUserContentController) {
        controllers.add(controller)
        for list in activeLists { controller.add(list) }
    }

    public var attachedCount: Int { controllers.allObjects.count }

    /// `nil` removes protection. On compile failure the previous list stays installed and the report says so.
    @discardableResult
    public func apply(_ snapshot: PolicySnapshot?) async -> InstallReport {
        guard let snapshot else {
            detachActive()
            activeLists = []
            activeIdentifier = nil
            let report = InstallReport(installed: false, identifier: nil, removed: true)
            lastReport = report
            return report
        }
        if snapshot.identifier == activeIdentifier, !activeLists.isEmpty {
            let report = InstallReport(installed: true, identifier: snapshot.identifier, reusedCompiledList: true, attachedWebViews: attachedCount)
            lastReport = report
            return report
        }

        let started = Date()
        var reused = false
        var lists: [WKContentRuleList] = []
        var allReused = true
        do {
            for (index, data) in snapshot.allRulesJSON.enumerated() {
                let identifier = Self.identifier(snapshot.identifier, index: index)
                if let existing = try await lookUp(identifier) {
                    lists.append(existing)
                } else {
                    allReused = false
                    guard let json = String(data: data, encoding: .utf8) else {
                        return fail("The rules were not valid text.", keeping: snapshot)
                    }
                    guard let compiled = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) else {
                        return fail("WebKit returned no rule list.", keeping: snapshot)
                    }
                    lists.append(compiled)
                }
            }
            reused = allReused
        } catch {
            return fail(Self.describe(error), keeping: snapshot)
        }

        // Swap: attach the new lists to every tab, then detach the old ones.
        let previous = activeLists
        for controller in controllers.allObjects {
            for list in lists { controller.add(list) }
            for old in previous { controller.remove(old) }
        }
        activeLists = lists
        activeIdentifier = snapshot.identifier
        recentIdentifiers.removeAll { $0 == snapshot.identifier }
        recentIdentifiers.insert(snapshot.identifier, at: 0)
        await pruneCache()

        let report = InstallReport(installed: true, identifier: snapshot.identifier,
                                   compileMilliseconds: Date().timeIntervalSince(started) * 1000, reusedCompiledList: reused,
                                   attachedWebViews: attachedCount)
        lastReport = report
        return report
    }

    // MARK: Internals

    private func fail(_ message: String, keeping snapshot: PolicySnapshot) -> InstallReport {
        // Report the failure, but keep describing the rules that are still installed.
        let report = InstallReport(installed: !activeLists.isEmpty, identifier: activeIdentifier, attachedWebViews: attachedCount, error: message)
        lastReport = report
        return report
    }

    private func detachActive() {
        for controller in controllers.allObjects { for list in activeLists { controller.remove(list) } }
    }

    private func lookUp(_ identifier: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, error in
                // WebKit reports "not found" as an error; treat only that as a miss.
                if let list { continuation.resume(returning: list) }
                else if let error = error as NSError?, error.domain == WKErrorDomain, error.code == WKError.contentRuleListStoreLookUpFailed.rawValue {
                    continuation.resume(returning: nil)
                } else if error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Removes compiled lists this package created that are no longer recent, keeping the cache small.
    public func pruneCache() async {
        let keep = Set(recentIdentifiers.prefix(Self.cachedListsKept + 1).flatMap { base in (0..<PolicyBuilder.maxLists).map { Self.identifier(base, index: $0) } })
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers where identifier.hasPrefix(Self.identifierPrefix) && !keep.contains(identifier) {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    /// The store name of the `index`th list of a snapshot: the snapshot's own identifier for the first, then "-2", "-3".
    static func identifier(_ base: String, index: Int) -> String { index == 0 ? base : "\(base)-\(index + 1)" }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if let text = ns.userInfo[NSLocalizedFailureReasonErrorKey] as? String { return text }
        return ns.localizedDescription
    }
}
