import Foundation
import WebKit

/// Extension tools that read what is installed: manifests, differences between versions, backups and a throwaway load test.
@available(macOS 15.4, iOS 18.4, *)
extension WebKitExtensionManager {
    private func manifest(at folder: URL) -> [String: Any]? {
        (try? Data(contentsOf: folder.appendingPathComponent("manifest.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func name(of record: Record) -> String {
        contexts[record.id]?.webExtension.displayName ?? record.id
    }

    func manifestSummaries() -> [ExtensionManifestSummary] {
        records.filter(\.enabled).compactMap { record in
            guard let m = manifest(at: directory.appendingPathComponent(record.id, isDirectory: true)) else { return nil }
            return ExtensionManifestSummary(id: record.id, name: name(of: record), version: m["version"] as? String ?? "", manifest: m)
        }
    }

    func diagnostics(openTabs: Int) -> [ExtensionDiagnostic] {
        records.map { record in
            let folder = directory.appendingPathComponent(record.id, isDirectory: true)
            let m = manifest(at: folder)
            let summary = m.map { ExtensionManifestSummary(id: record.id, name: "", version: "", manifest: $0) }
            let bytes = ExtensionFileDiff.digests(of: folder).count == 0 ? 0 : Self.bytes(in: folder)
            let reach = (record.enabled && !(summary?.hosts.isEmpty ?? true)) ? openTabs : 0
            return ExtensionDiagnostic(id: record.id, name: name(of: record), isLoaded: record.enabled && (contexts[record.id]?.isLoaded ?? false),
                                       hasBackground: summary?.hasBackground ?? false, contentScripts: summary?.contentScriptCount ?? 0,
                                       tabsItCanReach: reach, bytesOnDisk: bytes, permissionCount: record.permissions.count + record.hosts.count)
        }
    }

    private static func bytes(in folder: URL) -> Int {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return walker.reduce(0) { $0 + ((($1 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }) ?? 0) }
    }

    /// What differs between the installed version and the one it replaced, if one is kept.
    func previousVersionChanges(id: String) -> ExtensionFileDiff.Result? {
        let previous = directory.appendingPathComponent(id + ".prev", isDirectory: true)
        guard FileManager.default.fileExists(atPath: previous.path) else { return nil }
        return ExtensionFileDiff.compare(old: ExtensionFileDiff.digests(of: previous), new: ExtensionFileDiff.digests(of: directory.appendingPathComponent(id, isDirectory: true)))
    }

    /// Goes back to the version kept from before the last update; the current one becomes the kept one, so it can be undone.
    func rollback(id: String) async -> Bool {
        let current = directory.appendingPathComponent(id, isDirectory: true)
        let previous = directory.appendingPathComponent(id + ".prev", isDirectory: true)
        let swap = directory.appendingPathComponent(id + ".swap", isDirectory: true)
        guard FileManager.default.fileExists(atPath: previous.path), let context = contexts[id], let index = records.firstIndex(where: { $0.id == id }) else { return false }
        let wasEnabled = records[index].enabled
        try? controller.unload(context)
        try? FileManager.default.removeItem(at: swap)
        do {
            try FileManager.default.moveItem(at: current, to: swap)
            try FileManager.default.moveItem(at: previous, to: current)
            try FileManager.default.moveItem(at: swap, to: previous)
        } catch {
            if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: swap.path) { try? FileManager.default.moveItem(at: swap, to: current) }
            if wasEnabled { try? controller.load(context) }
            return false
        }
        // The old files may ask for different things than the ones now installed: the record is rebuilt from the folder, and what was turned off stays off.
        guard let loaded = try? await WKWebExtension(resourceBaseURL: current) else {
            try? FileManager.default.moveItem(at: current, to: swap); try? FileManager.default.moveItem(at: previous, to: current); try? FileManager.default.moveItem(at: swap, to: previous)
            if wasEnabled { try? controller.load(context) }
            return false
        }
        var record = records[index]
        record.permissions = loaded.requestedPermissions.map(\.rawValue).sorted()
        record.hosts = loaded.requestedPermissionMatchPatterns.map(\.string).sorted()
        var history = record.history ?? []
        history.append(RelativeDateTimeFormatter.shortStamp() + " Went back to " + (loaded.displayVersion ?? loaded.version ?? "the earlier version"))
        record.history = Array(history.suffix(20))
        let fresh = makeContext(loaded, record: record)
        contexts[id] = fresh
        records[index] = record
        if wasEnabled { try? controller.load(fresh) }
        saveRecords()
        publish()
        return true
    }

    /// Every installed extension's files, as one zip. Settings and permission choices are not in it: restoring goes through the normal review, which asks again.
    func backupArchive() -> Data? {
        var entries: [(path: String, data: Data)] = []
        for record in records {
            entries += ZipWriter.entries(of: directory.appendingPathComponent(record.id, isDirectory: true), prefix: "\(record.id)/")
        }
        guard !entries.isEmpty else { return nil }
        let names = Dictionary(uniqueKeysWithValues: records.map { ($0.id, name(of: $0)) })
        if let index = try? JSONSerialization.data(withJSONObject: ["extensions": names, "format": 1], options: [.sortedKeys]) { entries.append(("backup.json", index)) }
        return ZipWriter.zip(entries)
    }

    /// Loads an unpacked extension in a controller of its own, with no stored data and no tabs, and reports what it finds. This shows whether it loads and
    /// what it declares; it does not run the extension's own features against a website.
    func sandboxTest(folder: URL) async -> [ExtensionCheck] {
        var checks: [ExtensionCheck] = []
        func add(_ name: String, _ ok: Bool?, _ detail: String) { checks.append(ExtensionCheck(name: name, status: ok == nil ? .skipped : (ok! ? .passed : .failed), detail: detail)) }
        guard let m = manifest(at: folder) else { add("Reads its manifest", false, "No readable manifest.json."); return checks }
        add("Reads its manifest", true, "Manifest version \(m["manifest_version"] as? Int ?? 0).")
        guard let loaded = try? await WKWebExtension(resourceBaseURL: folder) else { add("WebKit accepts it", false, "WebKit could not load it."); return checks }
        add("WebKit accepts it", true, loaded.displayName ?? "Loaded")
        add("No errors reported by WebKit", loaded.errors.isEmpty, loaded.errors.isEmpty ? "None." : loaded.errors.map(\.localizedDescription).prefix(2).joined(separator: " "))
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let throwaway = WKWebExtensionController(configuration: configuration)
        let context = WKWebExtensionContext(for: loaded)
        var loadedOK = true
        do { try throwaway.load(context) } catch { loadedOK = false }
        add("Starts in a throwaway profile", loadedOK, loadedOK ? "Started with no stored data." : "It would not start.")
        if loadedOK {
            add("Background part starts", loaded.hasBackgroundContent ? context.isLoaded : nil, loaded.hasBackgroundContent ? "" : "It has none.")
            add("Toolbar button", loaded.displayActionLabel != nil || m["action"] != nil || m["browser_action"] != nil ? true : nil, "")
            add("Settings page", loaded.hasOptionsPage ? context.optionsPageURL != nil : nil, loaded.hasOptionsPage ? "" : "It has none.")
            add("Page scripts", loaded.hasInjectedContent ? true : nil, loaded.hasInjectedContent ? "It declares scripts that run on pages." : "It has none.")
            try? throwaway.unload(context)
        }
        let waiting = loaded.requestedPermissions.filter { !Self.knownSupported.contains($0.rawValue) }
        add("Uses only features WebKit offers", waiting.isEmpty, waiting.isEmpty ? "" : "Not offered: " + waiting.map(\.rawValue).sorted().joined(separator: ", "))
        return checks
    }

    private static let knownSupported: Set<String> = ["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest", "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess",
                                                      "menus", "nativeMessaging", "notifications", "scripting", "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest", "sidePanel"]
}
